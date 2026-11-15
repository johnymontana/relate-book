// The page's handle on the embedding worker.

import { EMBEDDING_DIMENSIONS, EMBEDDING_MODEL_ID } from '../engine/schema';
import type { Embedder } from '../search/embedder';
import type { EmbedderRequest, EmbedderResponse } from './embedder.worker';

export interface EmbedderLoadProgress {
  file: string;
  loaded: number;
  total: number;
}

type Distributive<T> = T extends unknown ? Omit<T, 'id'> : never;

export class WorkerEmbedder implements Embedder {
  readonly dimensions = EMBEDDING_DIMENSIONS;
  /** Recorded on every vector; the precision is part of it because fp32 and q8 vectors differ slightly. */
  readonly modelId: string;
  readonly device: 'webgpu' | 'wasm';
  private worker: Worker;
  private nextId = 1;
  private pending = new Map<number, { resolve: (m: EmbedderResponse) => void; reject: (e: Error) => void; onProgress?: (p: EmbedderLoadProgress) => void }>();

  private constructor(worker: Worker, device: 'webgpu' | 'wasm', dtype: string) {
    this.worker = worker;
    this.device = device;
    this.modelId = `${EMBEDDING_MODEL_ID}@${dtype}`;
  }

  static async load(onProgress?: (p: EmbedderLoadProgress) => void): Promise<WorkerEmbedder> {
    const worker = new Worker(new URL('./embedder.worker.ts', import.meta.url), { type: 'module', name: 'relate-books-embedder' });
    const shell = new WorkerEmbedder(worker, 'wasm', 'q8');
    worker.onmessage = (event: MessageEvent<EmbedderResponse>) => shell.receive(event.data);
    try {
      const preferred = typeof navigator !== 'undefined' && 'gpu' in navigator ? 'webgpu' : 'wasm';
      const loaded = await shell.send({ type: 'load', model: EMBEDDING_MODEL_ID, device: preferred }, onProgress);
      if (loaded.type !== 'loaded') throw new Error('unexpected reply from the embedding worker');
      const ready = new WorkerEmbedder(worker, loaded.device, loaded.dtype);
      worker.onmessage = (event: MessageEvent<EmbedderResponse>) => ready.receive(event.data);
      return ready;
    } catch (err) {
      worker.terminate();
      throw err;
    }
  }

  private receive(msg: EmbedderResponse): void {
    const entry = this.pending.get(msg.id);
    if (!entry) return;
    if (msg.type === 'progress') {
      entry.onProgress?.({ file: msg.file, loaded: msg.loaded, total: msg.total });
      return;
    }
    this.pending.delete(msg.id);
    if (msg.type === 'error') entry.reject(new Error(msg.message));
    else entry.resolve(msg);
  }

  private send(request: Distributive<EmbedderRequest>, onProgress?: (p: EmbedderLoadProgress) => void): Promise<EmbedderResponse> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, onProgress });
      this.worker.postMessage({ ...request, id });
    });
  }

  async embed(texts: string[]): Promise<number[][]> {
    if (texts.length === 0) return [];
    const reply = await this.send({ type: 'embed', texts });
    if (reply.type !== 'embedded') throw new Error('unexpected reply from the embedding worker');
    return reply.vectors;
  }

  dispose(): void {
    this.worker.terminate();
  }
}
