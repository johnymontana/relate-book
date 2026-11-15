// The dataset format `scripts/export-store.mjs` writes, and the loader that
// turns it back into a graph inside Relate WASM.
//
// The loader is a pure function of (dataset, exec): the worker passes the
// WASM handle's `execute`, the tests pass an in-process engine.

import { ident, type Params, type WireEnvelope } from './wire';

export const DATASET_FORMAT = 'relate-books-dataset';
export const DATASET_VERSION = 1;

export type TypedSpec =
  | { kind: 'point' | 'datetime' | 'localdatetime' | 'date' | 'time' | 'localtime' | 'duration' }
  | { kind: 'vector'; coordinateType: string; dimensions: number };

/** One row is `[exportId, properties]` or `[exportId, properties, typedValues]`. */
export type NodeRow = [number, Record<string, unknown>, Record<string, unknown>?];
/** One row is `[startExportId, endExportId, properties?, typedValues?]`. */
export type RelationshipRow = [number, number, Record<string, unknown>?, Record<string, unknown>?];

export interface NodeGroup {
  labels: string[];
  typed: Record<string, TypedSpec>;
  rows: NodeRow[];
}

export interface RelationshipGroup {
  type: string;
  typed: Record<string, TypedSpec>;
  rows: RelationshipRow[];
}

export interface Dataset {
  format: typeof DATASET_FORMAT;
  version: number;
  name: string;
  exportedAt: string;
  exportedWith?: string;
  counts: { nodes: number; relationships: number };
  schema: { constraints: string[]; indexes: string[] };
  nodes: NodeGroup[];
  relationships: RelationshipGroup[];
}

export class DatasetError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DatasetError';
  }
}

/** Parse and shape-check a dataset file. Throws `DatasetError` with a message fit for the UI. */
export function parseDataset(text: string): Dataset {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    throw new DatasetError('This file is not JSON. Create one with `npm run export-store -- path/to/books.rl`.');
  }
  const d = data as Partial<Dataset>;
  if (!d || d.format !== DATASET_FORMAT) {
    throw new DatasetError('This file is not a Relate Books dataset. Create one with `npm run export-store -- path/to/books.rl`.');
  }
  if (d.version !== DATASET_VERSION) {
    throw new DatasetError(`Dataset version ${String(d.version)} is not supported (this app reads version ${DATASET_VERSION}). Re-export the store.`);
  }
  if (!Array.isArray(d.nodes) || !Array.isArray(d.relationships) || !d.schema || !Array.isArray(d.schema.constraints) || !Array.isArray(d.schema.indexes)) {
    throw new DatasetError('The dataset is missing its nodes, relationships or schema.');
  }
  for (const ddl of [...d.schema.constraints, ...d.schema.indexes]) {
    if (typeof ddl !== 'string' || !/^CREATE\s+(CONSTRAINT|INDEX|POINT INDEX|FULLTEXT INDEX)\s/i.test(ddl) || ddl.includes(';')) {
      throw new DatasetError('The dataset schema holds a statement that is not a CREATE CONSTRAINT or CREATE INDEX.');
    }
  }
  return d as Dataset;
}

/** A short stable id for a dataset (name, export time and size), used to tell loads apart. */
export function datasetId(dataset: Dataset): string {
  return `${dataset.name}|${dataset.exportedAt}|${dataset.counts.nodes}|${dataset.counts.relationships}`;
}

function typedExpression(spec: TypedSpec, value: string): string {
  switch (spec.kind) {
    case 'point':
      return `point(${value})`;
    case 'datetime':
      return `datetime(${value})`;
    case 'localdatetime':
      return `localdatetime(${value})`;
    case 'date':
      return `date(${value})`;
    case 'time':
      return `time(${value})`;
    case 'localtime':
      return `localtime(${value})`;
    case 'duration':
      return `duration(${value})`;
    case 'vector': {
      const type = /^(FLOAT32|FLOAT64|INTEGER8|INTEGER16|INTEGER32|INTEGER64|FLOAT|INTEGER)$/.test(spec.coordinateType) ? spec.coordinateType : 'FLOAT32';
      return `vector(${value}, ${Math.trunc(spec.dimensions)}, ${type})`;
    }
  }
}

function typedAssignments(target: string, typed: Record<string, TypedSpec>, source: string): string {
  return Object.entries(typed)
    .map(([key, spec]) => `, ${target}.${ident(key)} = ${typedExpression(spec, `${source}.${ident(key)}`)}`)
    .join('');
}

/** `CREATE` for one batch of a node group; returns the export id beside the new node id. */
export function nodeStatement(group: NodeGroup): string {
  const labels = group.labels.map((l) => ':' + ident(l)).join('');
  return `UNWIND $rows AS row CREATE (n${labels}) SET n = row[1]${typedAssignments('n', group.typed, 'row[2]')} RETURN row[0] AS exportId, id(n) AS id`;
}

/** `CREATE` for one batch of a relationship group; rows carry the new node ids. */
export function relationshipStatement(group: RelationshipGroup): string {
  return `UNWIND $rows AS row MATCH (a) WHERE id(a) = row[0] MATCH (b) WHERE id(b) = row[1] CREATE (a)-[r:${ident(group.type)}]->(b) SET r = row[2]${typedAssignments('r', group.typed, 'row[3]')}`;
}

export interface LoadProgress {
  phase: 'schema' | 'nodes' | 'relationships' | 'indexes';
  done: number;
  total: number;
}

export interface LoadSummary {
  nodes: number;
  relationships: number;
  statements: number;
  ms: number;
}

export type Exec = (cypher: string, params?: Params) => WireEnvelope;

const BATCH = 2000;

/**
 * Load a dataset into an empty database: constraints, nodes, relationships,
 * then the remaining indexes (building them after the bulk insert is faster).
 *
 * Nodes are created in batches that return `export id -> new node id`, and
 * relationships look their endpoints up by `id()`, so nothing temporary is
 * written to the graph. The full 17,431-node wishlist loads in about 2 s.
 */
export function loadDataset(dataset: Dataset, exec: Exec, onProgress?: (p: LoadProgress) => void): LoadSummary {
  const started = performance.now();
  let statements = 0;
  const run = (cypher: string, params?: Params): WireEnvelope => {
    statements += 1;
    const envelope = exec(cypher, params);
    if (envelope.error) throw new DatasetError(`Loading failed: ${envelope.error}`);
    return envelope;
  };

  onProgress?.({ phase: 'schema', done: 0, total: dataset.schema.constraints.length });
  for (const ddl of dataset.schema.constraints) run(ddl);

  const totalNodes = dataset.nodes.reduce((n, g) => n + g.rows.length, 0);
  const totalRels = dataset.relationships.reduce((n, g) => n + g.rows.length, 0);
  const ids = new Map<number, number>();

  let done = 0;
  onProgress?.({ phase: 'nodes', done, total: totalNodes });
  for (const group of dataset.nodes) {
    const statement = nodeStatement(group);
    for (let i = 0; i < group.rows.length; i += BATCH) {
      const rows = group.rows.slice(i, i + BATCH).map((r) => [r[0], r[1], r[2] ?? {}]);
      const envelope = run(statement, { rows });
      for (const row of envelope.rows) ids.set(row.exportId as number, row.id as number);
      done += rows.length;
      onProgress?.({ phase: 'nodes', done, total: totalNodes });
    }
  }

  done = 0;
  onProgress?.({ phase: 'relationships', done, total: totalRels });
  for (const group of dataset.relationships) {
    const statement = relationshipStatement(group);
    for (let i = 0; i < group.rows.length; i += BATCH) {
      const rows = group.rows.slice(i, i + BATCH).map((r) => {
        const start = ids.get(r[0]);
        const end = ids.get(r[1]);
        if (start === undefined || end === undefined) throw new DatasetError(`Relationship ${group.type} refers to a node that is not in the dataset.`);
        return [start, end, r[2] ?? {}, r[3] ?? {}];
      });
      run(statement, { rows });
      done += rows.length;
      onProgress?.({ phase: 'relationships', done, total: totalRels });
    }
  }

  onProgress?.({ phase: 'indexes', done: 0, total: dataset.schema.indexes.length });
  dataset.schema.indexes.forEach((ddl, i) => {
    run(ddl);
    onProgress?.({ phase: 'indexes', done: i + 1, total: dataset.schema.indexes.length });
  });

  return { nodes: totalNodes, relationships: totalRels, statements, ms: performance.now() - started };
}
