// Hybrid book search: the query embedded in the browser and matched on the
// vector index, the two fulltext indexes with an all-terms gate, fused with
// reciprocal rank fusion. A port of ios/RelateBooks/Search/SearchService.swift
// without notes.
//
// It works on whatever is embedded so far, and without an embedder it is a
// keyword search.

import type { GraphDb } from '../engine/wire';
import { booksByKeys, fetchBooks, type BookSummary } from '../queries/library';
import * as searchQueries from '../queries/search';
import { run } from '../queries/statement';
import type { Embedder } from './embedder';
import { KeywordQuery } from './keywordQuery';
import { fuse, type KeywordCandidate, type SearchHit, type SemanticCandidate } from './rankFusion';

export interface SearchResult {
  book: BookSummary;
  hit: SearchHit;
}

export interface SearchResponse {
  query: string;
  results: SearchResult[];
  semanticUsed: boolean;
  keywordTerms: string[];
  ms: number;
}

export interface SearchTuning {
  semanticLimit: number;
  keywordLimit: number;
  resultLimit: number;
  rrfK: number;
  /** Semantic hits below this cosine are dropped (noise on a short query). */
  minCosine: number;
}

export const DEFAULT_TUNING: SearchTuning = { semanticLimit: 50, keywordLimit: 50, resultLimit: 30, rrfK: 60, minCosine: 0.25 };

interface BookTextHit {
  key: string;
  score: number;
  title: string | null;
  description: string | null;
  firstSentence: string | null;
}

interface ItemTextHit {
  key: string;
  score: number;
  bookTitle: string | null;
  itemTitle: string | null;
  byline: string | null;
}

/**
 * Merges the two fulltext lists per book, keeps a book only when it contains
 * every term, and orders: title/byline match first, then book_text score,
 * then item score, then key. Without the gate the engine's OR ranking lists
 * every book that mentions one common term.
 */
export function keywordCandidates(query: KeywordQuery, books: BookTextHit[], items: ItemTextHit[]): KeywordCandidate[] {
  const merged = new Map<string, { bookScore: number | null; itemScore: number | null; coverage: Array<string | null>; titles: Array<string | null> }>();
  const entry = (key: string) => {
    let m = merged.get(key);
    if (!m) merged.set(key, (m = { bookScore: null, itemScore: null, coverage: [], titles: [] }));
    return m;
  };
  for (const hit of books) {
    const m = entry(hit.key);
    m.bookScore = Math.max(m.bookScore ?? hit.score, hit.score);
    m.coverage.push(hit.title, hit.description, hit.firstSentence);
    m.titles.push(hit.title);
  }
  for (const hit of items) {
    const m = entry(hit.key);
    m.itemScore = Math.max(m.itemScore ?? hit.score, hit.score);
    m.coverage.push(hit.itemTitle, hit.byline, hit.bookTitle);
    m.titles.push(hit.bookTitle, hit.itemTitle, hit.byline);
  }
  const ranked = [...merged.entries()]
    .filter(([, m]) => query.isCoveredBy(m.coverage))
    .map(([key, m]) => ({ key, titleMatch: query.isCoveredBy(m.titles), bookScore: m.bookScore ?? 0, itemScore: m.itemScore ?? 0, score: m.bookScore ?? m.itemScore ?? 0 }));
  ranked.sort((a, b) => {
    if (a.titleMatch !== b.titleMatch) return a.titleMatch ? -1 : 1;
    if (a.bookScore !== b.bookScore) return b.bookScore - a.bookScore;
    if (a.itemScore !== b.itemScore) return b.itemScore - a.itemScore;
    return a.key < b.key ? -1 : 1;
  });
  return ranked.map(({ key, score, titleMatch }) => ({ key, score, titleMatch }));
}

export async function searchBooks(db: GraphDb, embedder: Embedder | null, raw: string, tuning: Partial<SearchTuning> = {}): Promise<SearchResponse> {
  const started = performance.now();
  const t = { ...DEFAULT_TUNING, ...tuning };
  const text = raw.trim();
  if ([...text].length < 2) return { query: text, results: [], semanticUsed: false, keywordTerms: [], ms: 0 };

  let semantic: SemanticCandidate[] = [];
  let semanticUsed = false;
  if (embedder) {
    try {
      const [vector] = await embedder.embed([text]);
      const rows = await run<{ key: string; score: number }>(db, searchQueries.semantic(vector, t.semanticLimit, embedder.modelId));
      semantic = rows.rows.map((r) => ({ key: r.key, cosine: 2 * r.score - 1 })).filter((c) => c.cosine >= t.minCosine);
      semanticUsed = rows.rows.length > 0;
    } catch (err) {
      // Keyword search still answers when the model is unavailable.
      console.warn('semantic search failed; keyword only', err);
    }
  }

  const keywordQuery = KeywordQuery.parse(text);
  let keyword: KeywordCandidate[] = [];
  if (keywordQuery) {
    const [books, items] = await Promise.all([
      run<BookTextHit>(db, searchQueries.bookText(keywordQuery.text, t.keywordLimit)),
      run<ItemTextHit>(db, searchQueries.itemText(keywordQuery.text, t.keywordLimit)),
    ]);
    keyword = keywordCandidates(keywordQuery, books.rows, items.rows);
  }

  const hits = fuse(semantic, keyword, t.rrfK).slice(0, t.resultLimit);
  const results = await hydrate(db, hits);
  return { query: text, results, semanticUsed, keywordTerms: keywordQuery?.terms ?? [], ms: performance.now() - started };
}

async function hydrate(db: GraphDb, hits: SearchHit[]): Promise<SearchResult[]> {
  if (hits.length === 0) return [];
  const rows = await fetchBooks(db, booksByKeys(hits.map((h) => h.key)));
  const byKey = new Map(rows.map((b) => [b.key, b]));
  return hits.flatMap((hit) => {
    const book = byKey.get(hit.key);
    return book ? [{ book, hit }] : [];
  });
}

/** The books nearest to a book's stored vector, with the cosine of each. */
export async function similarBooks(db: GraphDb, key: string, limit = 8): Promise<Array<{ book: BookSummary; cosine: number }>> {
  const near = await run<{ key: string; score: number }>(db, searchQueries.moreLikeThis(key, limit));
  if (near.rows.length === 0) return [];
  const rows = await fetchBooks(db, booksByKeys(near.rows.map((r) => r.key)));
  const byKey = new Map(rows.map((b) => [b.key, b]));
  return near.rows.flatMap((r) => {
    const book = byKey.get(r.key);
    return book ? [{ book, cosine: 2 * r.score - 1 }] : [];
  });
}
