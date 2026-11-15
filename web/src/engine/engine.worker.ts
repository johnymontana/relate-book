/// <reference lib="webworker" />
// The Relate engine. Runs in a dedicated worker for two reasons: the durable
// `opfs://` store only exists there (it needs FileSystemSyncAccessHandle), and
// a runaway query can be stopped by terminating the worker.

import init, { RelateDb } from '@relate/relate-wasm';
import wasmUrl from '@relate/relate-wasm/relate_bg.wasm?url';
import { isWasmTrap } from '@relate/relate-wasm/trap.js';
import { datasetId, loadDataset, parseDataset } from './dataset';
import type { Err, Inbound, Outbound, StorageKind } from './protocol';
import { WEB_DDL } from './schema';
import type { Params, WireEnvelope } from './wire';

declare const self: DedicatedWorkerGlobalScope;

/** One durable store per origin; switching datasets wipes and reloads it. */
const OPFS_URI = 'opfs://relate-books';

let db: RelateDb | null = null;
let memory: WebAssembly.Memory | null = null;
let storage: StorageKind = 'memory';

const post = (message: Outbound) => self.postMessage(message);

function exec(cypher: string, params?: Params): WireEnvelope {
  if (!db) throw new Error('the database is not open');
  return JSON.parse(db.execute(cypher, params ? JSON.stringify(params) : null)) as WireEnvelope;
}

function applyWebSchema(): void {
  for (const ddl of WEB_DDL) {
    const envelope = exec(ddl);
    if (envelope.error) throw new Error(`schema: ${envelope.error}`);
  }
}

function nodeCount(): number {
  const envelope = exec('MATCH (n) RETURN count(n) AS n');
  if (envelope.error) throw new Error(envelope.error);
  return (envelope.rows[0]?.n as number) ?? 0;
}

async function open(requested: StorageKind | 'auto') {
  if (!memory) memory = (await init({ module_or_path: wasmUrl })).memory;
  db?.free();
  db = null;
  let fallbackReason: string | null = null;
  if (requested !== 'memory') {
    try {
      db = await RelateDb.open(OPFS_URI);
      storage = 'opfs';
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      // A store another tab holds is not a reason to fall back silently when
      // the caller insisted on OPFS; with 'auto' the tab still works, in memory.
      if (requested === 'opfs') throw err;
      fallbackReason = message;
    }
  }
  if (!db) {
    db = new RelateDb();
    storage = 'memory';
  }
  const count = nodeCount();
  if (count > 0) applyWebSchema();
  return { storage, fallbackReason, nodeCount: count, wasmBytes: memory.buffer.byteLength };
}

async function load(id: number, source: Extract<Inbound, { type: 'load' }>['source']) {
  if (!db) throw new Error('the database is not open');
  let text: string;
  if (source.kind === 'url') {
    const response = await fetch(source.url);
    if (!response.ok) throw new Error(`Could not fetch the dataset (${response.status} ${response.statusText}).`);
    text = await response.text();
  } else {
    text = await source.blob.text();
  }
  const dataset = parseDataset(text);
  db.reset();
  let last = 0;
  const summary = loadDataset(dataset, exec, (progress) => {
    // Batches finish in a few milliseconds; a message per batch is plenty, but
    // never more than one every 30 ms.
    const now = performance.now();
    if (progress.done !== progress.total && now - last < 30) return;
    last = now;
    post({ id, progress });
  });
  applyWebSchema();
  return { name: dataset.name, datasetId: datasetId(dataset), exportedAt: dataset.exportedAt, summary };
}

function fail(id: number, err: unknown): void {
  const error = err instanceof Error ? err : new Error(String(err));
  const message: Err = {
    id,
    ok: false,
    trap: isWasmTrap(err),
    locked: error.name === 'RelateLocked' || /storage locked/i.test(error.message),
    message: error.message,
  };
  post(message);
}

// Requests run one at a time, in arrival order (open and load are async).
let queue: Promise<void> = Promise.resolve();

self.onmessage = (event: MessageEvent<Inbound>) => {
  const msg = event.data;
  queue = queue.then(async () => {
    try {
      switch (msg.type) {
        case 'open':
          post({ id: msg.id, ok: true, type: 'open', info: await open(msg.storage) });
          break;
        case 'query':
          if (!db) throw new Error('the database is not open');
          post({ id: msg.id, ok: true, type: 'query', raw: db.execute(msg.cypher, msg.params) });
          break;
        case 'load':
          post({ id: msg.id, ok: true, type: 'load', info: await load(msg.id, msg.source) });
          break;
        case 'reset':
          if (!db) throw new Error('the database is not open');
          db.reset();
          post({ id: msg.id, ok: true, type: 'reset' });
          break;
        case 'memory':
          post({ id: msg.id, ok: true, type: 'memory', bytes: memory?.buffer.byteLength ?? 0 });
          break;
        default: {
          const unexpected: never = msg;
          throw new Error(`unknown engine request: ${JSON.stringify(unexpected)}`);
        }
      }
    } catch (err) {
      fail(msg.id, err);
    }
  });
};
