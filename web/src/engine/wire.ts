// The Relate wire envelope (the JSON every Relate surface returns) and the
// small set of types the rest of the app builds on. No DOM, no React: this
// file is shared by the worker, the page and the Node tests.

export type Params = Record<string, unknown>;
export type Row = Record<string, unknown>;

export interface WireNode {
  kind: 'node';
  id: number;
  labels: string[];
  properties: Record<string, unknown>;
}

export interface WireRelationship {
  kind: 'relationship';
  id: number;
  type: string;
  start_node: number;
  end_node: number;
  properties: Record<string, unknown>;
}

export interface WireNotification {
  code: string;
  title: string;
  description: string;
  severity: string;
  category?: string;
  remedy?: string;
}

export interface PlanOperator {
  operator: string;
  details?: string;
  estimated_rows?: number | null;
  children: PlanOperator[];
}

export interface WirePlan {
  schema: string;
  statement: string;
  profiled: boolean;
  root: PlanOperator;
}

export interface WireEnvelope {
  columns: string[];
  columnTypes?: string[];
  rows: Row[];
  stats: Record<string, number>;
  plan?: WirePlan | null;
  notifications?: WireNotification[];
  elapsed_ms?: number;
  parse_ms?: number;
  plan_ms?: number;
  execute_ms?: number;
  plan_cache?: string;
  error: string | null;
}

export interface QueryResult<T = Row> {
  columns: string[];
  columnTypes: string[];
  rows: T[];
  /** Only the counters that changed. */
  stats: Record<string, number>;
  plan: WirePlan | null;
  notifications: WireNotification[];
  /** Engine-reported statement time. */
  elapsedMs: number;
  /** Round trip as the caller saw it (worker hop and JSON included). */
  wallMs: number;
}

/** A statement the engine rejected (parse, plan or execution error). */
export class CypherError extends Error {
  readonly cypher: string;
  constructor(message: string, cypher: string) {
    super(message);
    this.name = 'CypherError';
    this.cypher = cypher;
  }
}

export interface QueryOptions {
  /** Stop the query (by replacing the engine worker) after this long. */
  timeoutMs?: number;
}

/** Anything that can run one Cypher statement: the worker client, or the in-process test engine. */
export interface GraphDb {
  query<T = Row>(cypher: string, params?: Params, options?: QueryOptions): Promise<QueryResult<T>>;
}

export function toResult<T = Row>(envelope: WireEnvelope, cypher: string, wallMs: number): QueryResult<T> {
  if (envelope.error) throw new CypherError(envelope.error, cypher);
  const stats: Record<string, number> = {};
  for (const [k, v] of Object.entries(envelope.stats ?? {})) if (v) stats[k] = v;
  return {
    columns: envelope.columns,
    columnTypes: envelope.columnTypes ?? [],
    rows: envelope.rows as T[],
    stats,
    plan: envelope.plan ?? null,
    notifications: envelope.notifications ?? [],
    elapsedMs: envelope.elapsed_ms ?? 0,
    wallMs,
  };
}

export function isWireNode(v: unknown): v is WireNode {
  return typeof v === 'object' && v !== null && (v as WireNode).kind === 'node' && Array.isArray((v as WireNode).labels);
}

export function isWireRelationship(v: unknown): v is WireRelationship {
  return typeof v === 'object' && v !== null && (v as WireRelationship).kind === 'relationship' && typeof (v as WireRelationship).type === 'string';
}

export interface GraphData {
  nodes: WireNode[];
  relationships: WireRelationship[];
}

/**
 * Every node and relationship in a result, each once, in the order met.
 * Walks lists and maps, so paths (lists of alternating nodes and
 * relationships) and collected values are covered.
 */
export function extractGraph(rows: Row[]): GraphData {
  const nodes = new Map<number, WireNode>();
  const relationships = new Map<number, WireRelationship>();
  const visit = (value: unknown, depth: number): void => {
    if (value === null || typeof value !== 'object' || depth > 6) return;
    if (isWireNode(value)) {
      if (!nodes.has(value.id)) nodes.set(value.id, value);
      return;
    }
    if (isWireRelationship(value)) {
      if (!relationships.has(value.id)) relationships.set(value.id, value);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1);
      return;
    }
    for (const item of Object.values(value)) visit(item, depth + 1);
  };
  for (const row of rows) visit(row, 0);
  return { nodes: [...nodes.values()], relationships: [...relationships.values()] };
}

/** Backtick-quote an identifier unless it is a plain one. */
export function ident(name: string): string {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : '`' + name.replace(/`/g, '``') + '`';
}
