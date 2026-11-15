// Messages between the page and the engine worker.

import type { LoadProgress, LoadSummary } from './dataset';

export type StorageKind = 'opfs' | 'memory';

export type DatasetSource = { kind: 'url'; url: string } | { kind: 'blob'; blob: Blob };

export type Request =
  | { type: 'open'; storage: StorageKind | 'auto' }
  | { type: 'query'; cypher: string; params: string | null }
  | { type: 'load'; source: DatasetSource }
  | { type: 'reset' }
  | { type: 'memory' };

export type Inbound = Request & { id: number };

export interface OpenInfo {
  storage: StorageKind;
  /** Why OPFS was not used, when `storage` fell back to memory. */
  fallbackReason: string | null;
  nodeCount: number;
  wasmBytes: number;
}

export interface LoadInfo {
  name: string;
  datasetId: string;
  exportedAt: string;
  summary: LoadSummary;
}

export type Ok =
  | { id: number; ok: true; type: 'open'; info: OpenInfo }
  | { id: number; ok: true; type: 'query'; raw: string }
  | { id: number; ok: true; type: 'load'; info: LoadInfo }
  | { id: number; ok: true; type: 'reset' }
  | { id: number; ok: true; type: 'memory'; bytes: number };

export interface Err {
  id: number;
  ok: false;
  /** The WASM instance trapped: this worker is dead and must be replaced. */
  trap: boolean;
  /** Another tab holds the OPFS store. */
  locked: boolean;
  message: string;
}

export interface Progress {
  id: number;
  progress: LoadProgress;
}

export type Outbound = Ok | Err | Progress;

export type OkFor<T extends Request['type']> = Extract<Ok, { type: T }>;
