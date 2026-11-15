// The tools the chat agent can call. Each takes one string (small models are
// far more reliable with a single argument) and returns text for the model
// plus structured data for the UI.

import type { GraphDb, QueryResult } from '../../engine/wire';
import { getBook, type BookSummary } from '../../queries/library';
import * as searchQueries from '../../queries/search';
import { run } from '../../queries/statement';
import type { Embedder } from '../../search/embedder';
import { KeywordQuery } from '../../search/keywordQuery';
import { searchBooks, similarBooks } from '../../search/searchService';
import type { Llm } from '../llm';
import { textToCypher, type TextToCypherResult } from '../text2cypher/pipeline';

export type ToolName = 'search_books' | 'query_graph' | 'book_details' | 'similar_books';

export interface ToolContext {
  db: GraphDb;
  llm: Llm;
  embedder: Embedder | null;
  signal?: AbortSignal;
  present?: { labels: Set<string>; types: Set<string> };
  /** What the user actually asked; a failed graph query is retried with it, since a model's paraphrase can be the problem. */
  userQuestion?: string;
}

export interface BookRef {
  key: string;
  title: string;
}

export interface ToolResult {
  /** What the model reads. */
  observation: string;
  /** Books this call surfaced; the UI links them. */
  books: BookRef[];
  /** The Cypher behind the result, when one statement produced it. */
  cypher?: string;
  /** Rows to show as a table. */
  table?: Pick<QueryResult, 'columns' | 'rows'>;
  /** The full text-to-Cypher trace, for `query_graph`. */
  trace?: TextToCypherResult;
  failed?: boolean;
}

export interface ToolSpec {
  name: ToolName;
  /** One line for the system prompt. */
  description: string;
  run(input: string, context: ToolContext): Promise<ToolResult>;
}

const clip = (text: string, n: number) => (text.length > n ? `${text.slice(0, n - 1).trimEnd()}…` : text);

function describeBook(book: BookSummary): string {
  const parts = [book.title];
  if (book.authors.length) parts.push(`by ${book.authors.slice(0, 3).join(', ')}`);
  if (book.year) parts.push(`(${book.year})`);
  if (book.rating && book.rating > 0) parts.push(`rated ${book.rating.toFixed(1)}`);
  // Facts the model would otherwise be tempted to invent.
  if (book.format) parts.push(`· ${book.format}${book.price != null ? ` ${book.currency ?? 'USD'} ${book.price.toFixed(2)}` : ''}`);
  if (book.pages) parts.push(`· ${book.pages} pages`);
  return parts.join(' ');
}

/** Compact rows for a prompt: no nodes with every property, no long strings, no vectors. */
export function formatRows(columns: string[], rows: Array<Record<string, unknown>>, maxRows = 15): string {
  const cell = (value: unknown): string => {
    if (value === null || value === undefined) return 'null';
    if (typeof value === 'string') return clip(value, 80);
    if (typeof value === 'number') return Number.isInteger(value) ? String(value) : String(Math.round(value * 100) / 100);
    if (Array.isArray(value)) {
      if (value.length && typeof value[0] === 'object' && value[0] !== null && 'kind' in (value[0] as object)) return `[path of ${value.length} elements]`;
      return clip(`[${value.slice(0, 8).map(cell).join(', ')}${value.length > 8 ? ', …' : ''}]`, 160);
    }
    if (typeof value === 'object') {
      const v = value as { kind?: string; labels?: string[]; type?: string; properties?: Record<string, unknown>; values?: unknown };
      if (v.kind === 'node') return `(:${v.labels?.join(':')} ${clip(String(v.properties?.title ?? v.properties?.name ?? ''), 60)})`;
      if (v.kind === 'relationship') return `[:${v.type}]`;
      if (Array.isArray(v.values)) return '[vector]';
      return clip(JSON.stringify(value), 120);
    }
    return String(value);
  };
  if (rows.length === 0) return '(no rows)';
  // A pattern that matches a book through several subjects repeats its row; the model only needs it once.
  const all = [...new Set(rows.map((row) => columns.map((c) => `${c}: ${cell(row[c])}`).join(' | ')))];
  const lines = all.slice(0, maxRows);
  if (all.length > maxRows) lines.push(`… and ${all.length - maxRows} more rows`);
  return lines.join('\n');
}

/** A book by (part of) its title: exact, then case-insensitive, then fulltext. */
export async function resolveBook(db: GraphDb, title: string): Promise<BookRef | null> {
  const wanted = title.trim().replace(/^["'“]+|["'”.]+$/g, '');
  if (!wanted) return null;
  const exact = await db.query<BookRef>(
    'MATCH (b:Book) WHERE toLower(b.title) = toLower($t) RETURN b.key AS key, b.title AS title ORDER BY coalesce(b.ol_rating_count, 0) DESC LIMIT 1',
    { t: wanted },
  );
  if (exact.rows[0]) return exact.rows[0];
  const contains = await db.query<BookRef>(
    'MATCH (b:Book) WHERE toLower(b.title) CONTAINS toLower($t) RETURN b.key AS key, b.title AS title ORDER BY size(b.title) LIMIT 1',
    { t: wanted },
  );
  if (contains.rows[0]) return contains.rows[0];
  const query = KeywordQuery.parse(wanted);
  if (!query) return null;
  const hits = await run<{ key: string; title: string }>(db, searchQueries.bookText(query.text, 5));
  const covered = hits.rows.find((h) => query.isCoveredBy([h.title]));
  return covered ? { key: covered.key, title: covered.title } : null;
}

export const TOOLS: ToolSpec[] = [
  {
    name: 'search_books',
    description: 'Find books by meaning or keywords (topic, plot, mood, title or author words). Input: a short search phrase.',
    async run(input, { db, embedder }) {
      const response = await searchBooks(db, embedder, input, { resultLimit: 8 });
      if (response.results.length === 0) return { observation: `No books match "${input}".`, books: [] };
      const lines = response.results.map((r, i) => `${i + 1}. ${describeBook(r.book)}`);
      return {
        // The header says what a search is and is not: a small model otherwise reports the hits as facts.
        observation: `Books related to "${input}" (${response.semanticUsed ? 'semantic and keyword' : 'keyword'} search; relevance only, it does not confirm awards, authorship or other facts):\n${lines.join('\n')}`,
        books: response.results.map((r) => ({ key: r.book.key, title: r.book.title })),
        table: {
          columns: ['title', 'authors', 'year', 'rating', 'match'],
          rows: response.results.map((r) => ({ title: r.book.title, authors: r.book.authors.join(', '), year: r.book.year, rating: r.book.rating, match: r.hit.reason })),
        },
      };
    },
  },
  {
    name: 'query_graph',
    description:
      'Answer a factual question from the graph: counts, rankings, lists, who/which/how many, authors, subjects, places, awards, prices, years. Input: the question in plain English (it is translated to Cypher for you).',
    async run(input, { db, llm, embedder, signal, present, userQuestion }) {
      let trace = await textToCypher({ db, llm, embedder, question: input, signal, present, rowLimit: 25 });
      if ((!trace.result || !trace.cypher) && userQuestion && userQuestion.trim().toLowerCase() !== input.trim().toLowerCase()) {
        trace = await textToCypher({ db, llm, embedder, question: userQuestion, signal, present, rowLimit: 25 });
      }
      if (!trace.result || !trace.cypher) {
        const reason = (trace.error ?? 'no query was produced').split('\n')[0].slice(0, 240);
        return { observation: `LOOKUP FAILED, nothing was found out: ${reason} Rephrase the question more simply, or say that this could not be looked up.`, books: [], trace, failed: true };
      }
      const { columns, rows } = trace.result;
      const text = formatRows(columns, rows);
      const distinct = rows.length === 0 ? 0 : Math.min(rows.length, new Set(rows.map((r) => JSON.stringify(r))).size);
      return {
        observation: `Query result (${distinct} row${distinct === 1 ? '' : 's'}):\n${text}`,
        books: [],
        cypher: trace.cypher,
        table: { columns, rows },
        trace,
      };
    },
  },
  {
    name: 'book_details',
    description: 'Everything about one book: description, authors, subjects, places, awards, series, editions. Input: the book title.',
    async run(input, { db }) {
      const ref = await resolveBook(db, input);
      const book = ref ? await getBook(db, ref.key) : null;
      if (!ref || !book) return { observation: `No book titled "${input}" is on the list. Use search_books to find the right title.`, books: [], failed: true };
      const lines = [
        `${book.title}${book.subtitle ? `: ${book.subtitle}` : ''} by ${book.authors.map((a) => a.name).join(', ') || 'unknown'}${book.year ? `, first published ${book.year}` : ''}.`,
        book.rating && book.rating > 0 ? `Open Library rating ${book.rating.toFixed(2)} from ${book.ratingCount ?? '?'} ratings; ${book.wantToRead ?? 0} readers want to read it.` : '',
        book.pages ? `${book.pages} pages.` : '',
        book.series.length ? `Series: ${book.series.map((s) => `${s.name}${s.position ? ` #${s.position}` : ''}`).join(', ')}.` : '',
        book.genres.length ? `Genres: ${book.genres.join(', ')}.` : '',
        book.awards.length ? `Awards: ${book.awards.join(', ')}.` : '',
        book.places.length ? `Set in: ${book.places.slice(0, 8).join(', ')}.` : '',
        book.people.length ? `Features: ${book.people.slice(0, 8).join(', ')}.` : '',
        book.subjects.length ? `Subjects: ${book.subjects.filter((s) => !s.includes(':')).slice(0, 12).join(', ')}.` : '',
        book.editions.length ? `On the list as: ${book.editions.map((e) => `${e.format ?? 'edition'}${e.price ? ` ${e.currency ?? 'USD'} ${e.price}` : ''}`).join('; ')}.` : '',
        book.description ? `Description: ${clip(book.description.replace(/\s+/g, ' '), 600)}` : 'No description.',
      ].filter(Boolean);
      return { observation: lines.join('\n'), books: [ref] };
    },
  },
  {
    name: 'similar_books',
    description: 'Books on the list most similar to a given book (by embedding). Input: the book title.',
    async run(input, { db }) {
      const ref = await resolveBook(db, input);
      if (!ref) return { observation: `No book titled "${input}" is on the list. Use search_books to find the right title.`, books: [], failed: true };
      const similar = await similarBooks(db, ref.key, 6);
      if (similar.length === 0) {
        return { observation: `"${ref.title}" has no embedding yet, so similar books are not available. Use search_books with a description of it instead.`, books: [ref], failed: true };
      }
      return {
        observation: `Most similar to "${ref.title}":\n${similar.map((s, i) => `${i + 1}. ${describeBook(s.book)} (similarity ${s.cosine.toFixed(2)})`).join('\n')}`,
        books: [ref, ...similar.map((s) => ({ key: s.book.key, title: s.book.title }))],
        table: {
          columns: ['title', 'authors', 'year', 'similarity'],
          rows: similar.map((s) => ({ title: s.book.title, authors: s.book.authors.join(', '), year: s.book.year, similarity: Math.round(s.cosine * 100) / 100 })),
        },
      };
    },
  },
];
