// The page's handle on the engine worker: one request at a time over
// postMessage, a status the UI subscribes to, and recovery (a new worker)
// after a timeout or a WASM trap.

import type { LoadProgress } from './dataset';
import type { DatasetSource, Err, Inbound, LoadInfo, OkFor, OpenInfo, Outbound, Request, StorageKind } from './protocol';
import { toResult, type GraphDb, type Params, type QueryOptions, type QueryResult, type Row, type WireEnvelope } from './wire';

export interface DatasetMeta {
  id: string;
  name: string;
  /** Where it came from, as the dataset menu names it. */
  origin: 'sample' | 'local' | 'file';
  exportedAt: string;
  nodes: number;
  relationships: number;
  loadedAt: string;
  loadMs: number;
}

export interface EngineStatus {
  state: 'starting' | 'loading' | 'ready' | 'error';
  storage: StorageKind | null;
  /** Why the durable store is not in use, when it is not. */
  fallbackReason: string | null;
  dataset: DatasetMeta | null;
  progress: LoadProgress | null;
  error: string | null;
  wasmBytes: number;
  /** Bumped whenever the graph was replaced or the worker restarted; views refetch on it. */
  generation: number;
}

export class QueryTimeoutError extends Error {
  constructor(ms: number) {
    super(`The query ran longer than ${Math.round(ms / 1000)} s and was stopped. The engine was restarted.`);
    this.name = 'QueryTimeoutError';
  }
}

export class EngineRestartedError extends Error {
  constructor() {
    super('The engine restarted while this request was waiting.');
    this.name = 'EngineRestartedError';
  }
}

interface Pending {
  resolve: (value: Outbound) => void;
  reject: (reason: Error) => void;
  onProgress?: (p: LoadProgress) => void;
  timer?: ReturnType<typeof setTimeout>;
}

const META_KEY = 'relate-books:dataset';
const DEFAULT_TIMEOUT_MS = 30_000;

function readMeta(): DatasetMeta | null {
  try {
    const raw = localStorage.getItem(META_KEY);
    return raw ? (JSON.parse(raw) as DatasetMeta) : null;
  } catch {
    return null;
  }
}

function writeMeta(meta: DatasetMeta | null): void {
  try {
    if (meta) localStorage.setItem(META_KEY, JSON.stringify(meta));
    else localStorage.removeItem(META_KEY);
  } catch {
    // Private mode: the store is simply reloaded on the next visit.
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export class EngineClient implements GraphDb {
  private worker: Worker | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private listeners = new Set<() => void>();
  private lastSource: { source: DatasetSource; origin: DatasetMeta['origin'] } | null = null;
  private recovering: Promise<void> | null = null;
  private preferMemory: boolean;

  status: EngineStatus = {
    state: 'starting',
    storage: null,
    fallbackReason: null,
    dataset: null,
    progress: null,
    error: null,
    wasmBytes: 0,
    generation: 0,
  };

  constructor(options: { memoryOnly?: boolean } = {}) {
    this.preferMemory = options.memoryOnly ?? false;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getStatus = (): EngineStatus => this.status;

  private setStatus(patch: Partial<EngineStatus>): void {
    this.status = { ...this.status, ...patch };
    for (const listener of this.listeners) listener();
  }

  private spawn(): void {
    const worker = new Worker(new URL('./engine.worker.ts', import.meta.url), { type: 'module', name: 'relate-engine' });
    worker.onmessage = (event: MessageEvent<Outbound>) => {
      const msg = event.data;
      const entry = this.pending.get(msg.id);
      if (!entry) return;
      if ('progress' in msg) {
        entry.onProgress?.(msg.progress);
        return;
      }
      this.pending.delete(msg.id);
      if (entry.timer) clearTimeout(entry.timer);
      entry.resolve(msg);
    };
    worker.onerror = (event) => {
      this.setStatus({ state: 'error', error: event.message || 'The engine worker failed to start.' });
    };
    this.worker = worker;
  }

  private send<T extends Request['type']>(
    request: Extract<Request, { type: T }>,
    options: { timeoutMs?: number; onProgress?: (p: LoadProgress) => void } = {},
  ): Promise<OkFor<T>> {
    if (!this.worker) this.spawn();
    const id = this.nextId++;
    return new Promise<OkFor<T>>((resolve, reject) => {
      const entry: Pending = {
        onProgress: options.onProgress,
        reject,
        resolve: (msg) => {
          if ('ok' in msg && msg.ok) {
            resolve(msg as OkFor<T>);
            return;
          }
          const err = msg as Err;
          const error = new Error(err.message);
          if (err.locked) error.name = 'RelateLocked';
          if (err.trap) {
            error.name = 'WasmTrap';
            void this.recover();
          }
          reject(error);
        },
      };
      if (options.timeoutMs) {
        entry.timer = setTimeout(() => {
          if (!this.pending.delete(id)) return;
          reject(new QueryTimeoutError(options.timeoutMs!));
          void this.recover();
        }, options.timeoutMs);
      }
      this.pending.set(id, entry);
      this.worker!.postMessage({ ...request, id } as Inbound);
    });
  }

  /** Open the store; reuse what OPFS holds, or load `fallback`. */
  async start(fallback: { source: DatasetSource; origin: DatasetMeta['origin'] }): Promise<void> {
    this.setStatus({ state: 'starting', error: null });
    try {
      const info = await this.open();
      const meta = readMeta();
      if (info.storage === 'opfs' && info.nodeCount > 0 && meta) {
        this.setStatus({ state: 'ready', dataset: meta, generation: this.status.generation + 1 });
        return;
      }
      await this.load(fallback.source, fallback.origin);
    } catch (err) {
      this.setStatus({ state: 'error', error: err instanceof Error ? err.message : String(err) });
    }
  }

  private async open(): Promise<OpenInfo> {
    let info: OpenInfo | null = null;
    if (!this.preferMemory) {
      // A worker that was just terminated releases its OPFS handles a moment
      // later, so a locked store is retried before settling for memory.
      for (let attempt = 0; attempt < 5 && !info; attempt++) {
        try {
          info = (await this.send({ type: 'open', storage: 'opfs' })).info;
        } catch (err) {
          if ((err as Error).name !== 'RelateLocked' || attempt === 4) break;
          await sleep(150 * (attempt + 1));
        }
      }
    }
    if (!info) info = (await this.send({ type: 'open', storage: this.preferMemory ? 'memory' : 'auto' })).info;
    this.setStatus({ storage: info.storage, fallbackReason: info.fallbackReason, wasmBytes: info.wasmBytes });
    return info;
  }

  /** Replace the graph with a dataset. */
  async load(given: DatasetSource, origin: DatasetMeta['origin']): Promise<LoadInfo> {
    // The worker fetches the dataset, and a relative URL there would resolve
    // against the worker's own script (assets/engine.worker-….js in a build),
    // so it is made absolute against the page first.
    const source: DatasetSource = given.kind === 'url' ? { kind: 'url', url: new URL(given.url, document.baseURI).href } : given;
    this.setStatus({ state: 'loading', progress: null, error: null });
    writeMeta(null);
    try {
      const { info } = await this.send({ type: 'load', source }, { onProgress: (progress) => this.setStatus({ progress }) });
      this.lastSource = { source, origin };
      const meta: DatasetMeta = {
        id: info.datasetId,
        name: info.name,
        origin,
        exportedAt: info.exportedAt,
        nodes: info.summary.nodes,
        relationships: info.summary.relationships,
        loadedAt: new Date().toISOString(),
        loadMs: Math.round(info.summary.ms),
      };
      writeMeta(meta);
      const { bytes } = await this.send({ type: 'memory' });
      this.setStatus({ state: 'ready', dataset: meta, progress: null, wasmBytes: bytes, generation: this.status.generation + 1 });
      return info;
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      // A failed load leaves a wiped or partial store. Go back to the dataset
      // that was loaded before, if this tab still has it.
      const previous = this.lastSource;
      if (previous && previous.source !== source && !(previous.source.kind === 'url' && source.kind === 'url' && previous.source.url === source.url)) {
        await this.load(previous.source, previous.origin).catch(() => undefined);
        this.setStatus({ error: message });
      } else {
        this.setStatus({ state: 'error', error: message, progress: null });
      }
      throw err;
    }
  }

  async query<T = Row>(cypher: string, params?: Params, options: QueryOptions = {}): Promise<QueryResult<T>> {
    if (this.recovering) await this.recovering;
    const started = performance.now();
    const { raw } = await this.send(
      { type: 'query', cypher, params: params ? JSON.stringify(params) : null },
      { timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS },
    );
    return toResult<T>(JSON.parse(raw) as WireEnvelope, cypher, performance.now() - started);
  }

  /** Replace a dead or stuck worker. OPFS data survives; an in-memory graph is loaded again. */
  private recover(): Promise<void> {
    if (this.recovering) return this.recovering;
    this.recovering = (async () => {
      this.worker?.terminate();
      this.worker = null;
      for (const entry of this.pending.values()) {
        if (entry.timer) clearTimeout(entry.timer);
        entry.reject(new EngineRestartedError());
      }
      this.pending.clear();
      this.setStatus({ state: 'starting' });
      try {
        const info = await this.open();
        const meta = readMeta();
        if (info.storage === 'opfs' && info.nodeCount > 0 && meta) {
          this.setStatus({ state: 'ready', dataset: meta, generation: this.status.generation + 1 });
        } else if (this.lastSource) {
          await this.load(this.lastSource.source, this.lastSource.origin);
        } else {
          this.setStatus({ state: 'error', error: 'The engine restarted and has no dataset to load. Reload the page.' });
        }
      } catch (err) {
        this.setStatus({ state: 'error', error: err instanceof Error ? err.message : String(err) });
      }
    })().finally(() => {
      this.recovering = null;
    });
    return this.recovering;
  }

  /** A statement changed the graph (a write from the Query tab): views refetch. */
  notifyChanged(): void {
    this.setStatus({ generation: this.status.generation + 1 });
  }

  /** Remember a source for memory-mode recovery when the graph came from OPFS (nothing was loaded in this tab). */
  rememberSource(source: DatasetSource, origin: DatasetMeta['origin']): void {
    if (!this.lastSource) this.lastSource = { source, origin };
  }

  dispose(): void {
    this.worker?.terminate();
    this.worker = null;
  }
}
