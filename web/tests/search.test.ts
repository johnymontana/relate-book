import { beforeAll, describe, expect, it } from 'vitest';
import { EMBEDDING_DIMENSIONS } from '../src/engine/schema';
import * as searchQueries from '../src/queries/search';
import { run } from '../src/queries/statement';
import { cosine, validateVector } from '../src/search/embedder';
import { embeddingHash, embeddingText, normalizedSubjects } from '../src/search/embeddingText';
import { indexBooks } from '../src/search/indexer';
import { KeywordQuery, tokens } from '../src/search/keywordQuery';
import { fuse } from '../src/search/rankFusion';
import { keywordCandidates, searchBooks, similarBooks } from '../src/search/searchService';
import { StubEmbedder } from '../src/search/stubEmbedder';
import { sampleDb, type TestDb } from './helpers/engine';

describe('KeywordQuery', () => {
  it('tokenizes like the engine and drops stopwords, operators and duplicates', () => {
    expect(tokens("Le Guin's 1969 novel — Ægir")).toEqual(['le', 'guin', 's', '1969', 'novel', 'ægir']);
    expect(KeywordQuery.parse('The lonely astronaut AND the Earth, earth')!.terms).toEqual(['lonely', 'astronaut', 'earth']);
    expect(KeywordQuery.parse('a of the')).toBeNull();
    expect(KeywordQuery.parse('one two three four five six seven eight nine ten')!.terms).toHaveLength(8);
    expect(KeywordQuery.parse('mars NOT earth OR moon')!.text).toBe('mars earth moon');
  });

  it('checks coverage on tokens, not substrings', () => {
    const q = KeywordQuery.parse('earth')!;
    expect(q.isCoveredBy(['An earthquake'])).toBe(false);
    expect(q.isCoveredBy([null, 'Save the Earth'])).toBe(true);
  });
});

describe('rank fusion', () => {
  it('ranks a book in both lists above single-list hits and explains why', () => {
    const hits = fuse(
      [{ key: 'a', cosine: 0.6 }, { key: 'b', cosine: 0.5 }, { key: 'c', cosine: 0.4 }],
      [{ key: 'b', score: 3, titleMatch: true }, { key: 'd', score: 2, titleMatch: false }],
    );
    expect(hits.map((h) => h.key)).toEqual(['b', 'a', 'd', 'c']);
    expect(hits[0]).toMatchObject({ reason: 'both', semanticRank: 2, keywordRank: 1, titleMatch: true });
    expect(hits[0].fusedScore).toBeCloseTo(1 / 62 + 1 / 61, 10);
    expect(hits[1].reason).toBe('semantic');
    expect(hits[2].reason).toBe('keyword');
  });

  it('breaks an exact tie with the title match, then cosine, then key', () => {
    const hits = fuse([{ key: 's', cosine: 0.9 }], [{ key: 'k', score: 1, titleMatch: true }]);
    expect(hits.map((h) => h.key)).toEqual(['k', 's']);
    expect(fuse([], [{ key: 'z', score: 1, titleMatch: false }, { key: 'z', score: 9, titleMatch: false }])).toHaveLength(1);
  });

  it('gates keyword candidates on every term and puts title matches first', () => {
    const q = KeywordQuery.parse('red mars')!;
    const out = keywordCandidates(
      q,
      [
        { key: 'desc', score: 9, title: 'Colonists', description: 'A red planet called Mars', firstSentence: null },
        { key: 'title', score: 2, title: 'Red Mars', description: null, firstSentence: null },
        { key: 'partial', score: 5, title: 'Blue Mars', description: null, firstSentence: null },
      ],
      [{ key: 'item', score: 1, bookTitle: 'Other', itemTitle: 'Red Mars (Mars Trilogy)', byline: 'by KSR' }],
    );
    expect(out.map((c) => c.key)).toEqual(['title', 'item', 'desc']);
    expect(out[0].titleMatch).toBe(true);
    expect(out[2].titleMatch).toBe(false);
  });
});

describe('embedding text', () => {
  it('joins title, authors, subjects and description like the iOS app', () => {
    const text = embeddingText({
      key: 'k',
      title: ' Red Mars ',
      authors: ['Kim Stanley Robinson', 'kim stanley robinson', ''],
      subjects: ['Mars (Planet)', 'Fiction', 'nyt:hardcover', 'mars (planet)', 'Colonization', '1234', 'PZ7=x'],
      description: 'x'.repeat(900),
    });
    expect(text).toBe(`Red Mars · Kim Stanley Robinson · Colonization, Mars (Planet) · ${'x'.repeat(800)}`);
    expect(embeddingText({ key: 'k', title: null, authors: [], subjects: [], description: '  ' })).toBe('k');
    // An author node without a name comes back as a null entry.
    expect(embeddingText({ key: 'k', title: 'T', authors: [null, 'A'], subjects: [null], description: null })).toBe('T · A');
    expect(normalizedSubjects(Array.from({ length: 30 }, (_, i) => `S${String(i).padStart(2, '0')}`))).toHaveLength(15);
  });

  it('hashes the model id with the text', async () => {
    expect(await embeddingHash('hello', 'm')).toBe('9263cc67308d3aa518ffda1be8a73dfe0aac6e4a8f2e2d49569744ee8f08e5ce');
    expect(await embeddingHash('hello', 'm')).not.toBe(await embeddingHash('hello', 'n'));
  });
});

describe('embedder helpers', () => {
  it('validates vectors and computes cosine', async () => {
    const stub = new StubEmbedder();
    const [a, b, c] = await stub.embed(['red mars colony', 'mars colony red', 'whales in the ocean']);
    expect(a).toHaveLength(EMBEDDING_DIMENSIONS);
    expect(cosine(a, b)).toBeCloseTo(1, 6);
    expect(cosine(a, c)).toBeLessThan(0.5);
    expect(() => validateVector([1, 2], 3)).toThrow(/dimensions/);
    expect(() => validateVector([1, NaN, 0], 3)).toThrow(/non-finite/);
  });
});

describe('indexing and search on the sample', () => {
  let db: TestDb;
  const embedder = new StubEmbedder();

  beforeAll(async () => {
    db = await sampleDb();
  });

  it('answers a keyword search before anything is embedded', async () => {
    const response = await searchBooks(db, null, 'murder mystery');
    expect(response.semanticUsed).toBe(false);
    expect(response.results.map((r) => r.book.title)).toEqual(['The Curious Incident of the Dog in the Night-Time']);
    expect(response.results[0].hit.reason).toBe('keyword');
    expect((await searchBooks(db, null, 'x')).results).toEqual([]);
    expect((await similarBooks(db, response.results[0].book.key)).length).toBe(0);
  });

  it('embeds every book once, then only what is stale', async () => {
    const progress: number[] = [];
    const first = await indexBooks(db, embedder, { batchSize: 4, onProgress: (p) => progress.push(p.scanned) });
    expect(first).toMatchObject({ total: 6, embedded: 6, upToDate: 0 });
    expect(progress[progress.length - 1]).toBe(6);
    const stored = await db.query("MATCH (b:Book) RETURN count(b.embedding) AS n, collect(DISTINCT valueType(b.embedding)) AS types, collect(DISTINCT b.embedding_model) AS models");
    expect(stored.rows[0]).toEqual({ n: 6, types: ['VECTOR<FLOAT32 NOT NULL>(384) NOT NULL'], models: [embedder.modelId] });
    expect((await run<{ embedded: number }>(db, searchQueries.embeddingCoverage(embedder.modelId))).rows[0].embedded).toBe(6);

    const second = await indexBooks(db, embedder);
    expect(second).toMatchObject({ total: 6, embedded: 0, upToDate: 6 });

    const original = (await db.query<{ d: string }>("MATCH (b:Book {title: 'Red Mars'}) RETURN b.description AS d")).rows[0].d;
    await db.query("MATCH (b:Book {title: 'Red Mars'}) SET b.description = 'A new description about terraforming.'");
    const third = await indexBooks(db, embedder);
    expect(third).toMatchObject({ embedded: 1, upToDate: 5 });
    await db.query("MATCH (b:Book {title: 'Red Mars'}) SET b.description = $d", { d: original });

    const other = await indexBooks(db, new StubEmbedder('stub/other-model'));
    expect(other.embedded).toBe(6);
    await indexBooks(db, embedder);
  });

  it('stops when aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(indexBooks(db, embedder, { signal: controller.signal })).rejects.toThrow();
  });

  it('fuses semantic and keyword hits', async () => {
    const response = await searchBooks(db, embedder, 'the colonization of Mars');
    expect(response.semanticUsed).toBe(true);
    expect(response.keywordTerms).toEqual(['colonization', 'mars']);
    expect(response.results[0].book.title).toBe('Red Mars');
    expect(response.results[0].book.authors).toEqual(['Kim Stanley Robinson']);
    expect(response.results[0].hit.reason).toBe('both');

    const author = await searchBooks(db, embedder, 'le guin');
    expect(author.results[0].book.title).toBe('The Left Hand of Darkness');
    expect(author.results[0].hit.titleMatch).toBe(true);
  });

  it('ignores vectors written by another model', async () => {
    const [vector] = await embedder.embed(['mars']);
    const rows = await run(db, searchQueries.semantic(vector, 10, 'some/other-model'));
    expect(rows.rows).toEqual([]);
  });

  it('finds similar books and never the book itself', async () => {
    const key = (await db.query<{ key: string }>("MATCH (b:Book {title: 'Red Mars'}) RETURN b.key AS key")).rows[0].key;
    const similar = await similarBooks(db, key, 3);
    expect(similar).toHaveLength(3);
    expect(similar.map((s) => s.book.key)).not.toContain(key);
    expect(similar[0].cosine).toBeGreaterThanOrEqual(similar[1].cosine);
  });

  it('links names in a question to nodes', async () => {
    const rows = (await run<{ label: string; name: string }>(db, searchQueries.terms('books by ursula le guin set in san francisco', 8))).rows;
    expect(rows).toContainEqual(expect.objectContaining({ label: 'Author', name: 'Ursula K. Le Guin' }));
    expect(rows).toContainEqual(expect.objectContaining({ label: 'Place', name: 'San Francisco' }));
  });
});
