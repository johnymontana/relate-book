// Embeds every book that has no vector, a vector from another model, or a
// vector computed from text that has since changed, and writes the vectors
// into the graph (Book.embedding, VECTOR<FLOAT32>(384)). Resumable: a second
// run only touches what is stale, so with the OPFS store it happens once.

import type { GraphDb } from '../engine/wire';
import * as searchQueries from '../queries/search';
import { run } from '../queries/statement';
import { validateVector, type Embedder } from './embedder';
import { embeddingHash, embeddingText } from './embeddingText';

export interface IndexProgress {
  /** Books looked at so far. */
  scanned: number;
  total: number;
  /** Books (re-)embedded so far in this run. */
  embedded: number;
}

export interface IndexSummary {
  total: number;
  embedded: number;
  upToDate: number;
  ms: number;
}

interface ScanRow {
  key: string;
  title: string | null;
  description: string | null;
  model: string | null;
  hash: string | null;
  hasEmbedding: boolean;
  authors: string[];
  subjects: string[];
}

export interface IndexOptions {
  batchSize?: number;
  pageSize?: number;
  signal?: AbortSignal;
  onProgress?: (p: IndexProgress) => void;
}

export async function indexBooks(db: GraphDb, embedder: Embedder, options: IndexOptions = {}): Promise<IndexSummary> {
  const started = performance.now();
  const batchSize = options.batchSize ?? 16;
  const pageSize = options.pageSize ?? 200;
  const coverage = await run<{ books: number }>(db, searchQueries.embeddingCoverage(embedder.modelId));
  const total = coverage.rows[0]?.books ?? 0;
  let scanned = 0;
  let embedded = 0;
  let after = '';
  for (;;) {
    options.signal?.throwIfAborted();
    const page = await run<ScanRow>(db, searchQueries.scanBooks(after, pageSize));
    if (page.rows.length === 0) break;
    after = page.rows[page.rows.length - 1].key;

    const stale: Array<{ key: string; text: string; hash: string }> = [];
    for (const row of page.rows) {
      const text = embeddingText(row);
      const hash = await embeddingHash(text, embedder.modelId);
      if (!row.hasEmbedding || row.model !== embedder.modelId || row.hash !== hash) stale.push({ key: row.key, text, hash });
    }
    let handled = scanned + (page.rows.length - stale.length);
    for (let i = 0; i < stale.length; i += batchSize) {
      options.signal?.throwIfAborted();
      const batch = stale.slice(i, i + batchSize);
      const vectors = await embedder.embed(batch.map((b) => b.text));
      vectors.forEach((v) => validateVector(v, embedder.dimensions));
      await run(db, searchQueries.writeEmbeddings(batch.map((b, j) => ({ key: b.key, vector: vectors[j], hash: b.hash })), embedder.modelId));
      embedded += batch.length;
      handled += batch.length;
      options.onProgress?.({ scanned: handled, total, embedded });
    }
    scanned += page.rows.length;
    options.onProgress?.({ scanned, total, embedded });
    if (page.rows.length < pageSize) break;
  }
  return { total, embedded, upToDate: scanned - embedded, ms: performance.now() - started };
}
