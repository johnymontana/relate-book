// An in-process Relate engine for the Node tests: the same WASM bundle the
// browser runs, initialised from the file on disk.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import init, { RelateDb } from '@relate/relate-wasm';
import { loadDataset, parseDataset, type Dataset, type LoadSummary } from '../../src/engine/dataset';
import { WEB_DDL } from '../../src/engine/schema';
import { toResult, type GraphDb, type Params, type QueryResult, type Row, type WireEnvelope } from '../../src/engine/wire';

const require = createRequire(import.meta.url);
let ready: Promise<unknown> | null = null;

async function ensureWasm(): Promise<void> {
  ready ??= init({ module_or_path: readFileSync(require.resolve('@relate/relate-wasm/relate_bg.wasm')) });
  await ready;
}

export const SAMPLE_PATH = new URL('../../public/data/sample.json', import.meta.url);

export function sampleDataset(): Dataset {
  return parseDataset(readFileSync(SAMPLE_PATH, 'utf8'));
}

export class TestDb implements GraphDb {
  readonly handle: RelateDb;
  summary: LoadSummary | null = null;

  constructor(handle: RelateDb) {
    this.handle = handle;
  }

  exec = (cypher: string, params?: Params): WireEnvelope =>
    JSON.parse(this.handle.execute(cypher, params ? JSON.stringify(params) : null)) as WireEnvelope;

  async query<T = Row>(cypher: string, params?: Params): Promise<QueryResult<T>> {
    const started = performance.now();
    return toResult<T>(this.exec(cypher, params), cypher, performance.now() - started);
  }
}

/** An empty in-memory database. */
export async function emptyDb(): Promise<TestDb> {
  await ensureWasm();
  return new TestDb(new RelateDb());
}

/** The six-book sample, loaded as the app loads it (dataset, then the web DDL). */
export async function sampleDb(): Promise<TestDb> {
  const db = await emptyDb();
  db.summary = loadDataset(sampleDataset(), db.exec);
  for (const ddl of WEB_DDL) {
    const envelope = db.exec(ddl);
    if (envelope.error) throw new Error(envelope.error);
  }
  return db;
}
