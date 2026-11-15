import type { GraphDb, Params, QueryResult, Row } from '../engine/wire';

/** One Cypher statement with its parameters. Views show `cypher` next to what it produced. */
export interface Statement {
  cypher: string;
  params?: Params;
}

export function run<T = Row>(db: GraphDb, statement: Statement): Promise<QueryResult<T>> {
  return db.query<T>(statement.cypher, statement.params);
}

/** Strip the common leading indentation of a template literal and trim it. */
export function cypher(strings: TemplateStringsArray, ...values: unknown[]): string {
  const text = strings.reduce((out, s, i) => out + s + (i < values.length ? String(values[i]) : ''), '');
  const lines = text.replace(/^\n/, '').replace(/\s+$/, '').split('\n');
  const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)![0].length));
  return lines.map((l) => l.slice(indent)).join('\n');
}
