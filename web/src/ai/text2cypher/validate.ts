// Checks a generated statement without running it: the lexical read-only
// guard, then EXPLAIN (syntax, unknown labels and properties, and the plan's
// operators as the engine's own word on whether it writes).

import { CypherError, type GraphDb } from '../../engine/wire';
import { LABELS, RELATIONSHIPS } from '../../engine/schema';
import { checkReadOnly, stripLiterals, writeOperators } from './guard';

export interface Validation {
  ok: boolean;
  /** Refused outright: nothing a retry of the same question should paper over. */
  refused?: string;
  /** What to tell the model so it can fix the statement. */
  problems: string[];
  /** The engine could not parse or plan the statement. */
  syntaxError?: boolean;
}

/** `b.author` and friends: a node the model took for a property. Says how to reach it instead. */
function relationshipForProperty(key: string): string | null {
  const wanted = key.toLowerCase().replace(/_?names?$/, '').replace(/s$/, '');
  const label = LABELS.find((l) => l.label.toLowerCase() === wanted);
  if (!label) return null;
  const rel = RELATIONSHIPS.find((r) => r.to === label.label && r.from === 'Book') ?? RELATIONSHIPS.find((r) => r.to === label.label);
  if (!rel) return null;
  const v = label.label[0].toLowerCase();
  return `\`${key}\` is not a property. It is a node: MATCH (${rel.from[0].toLowerCase()}:${rel.from})-[:${rel.type}]->(${v}:${label.label}) and use ${v}.${label.key}.`;
}

/** The valid names for whatever kind of name was unknown, limited to the labels the statement uses. */
function nameHints(cypher: string, codes: string[], descriptions: string[]): string[] {
  const hints: string[] = [];
  for (const description of descriptions) {
    const key = /property key `([^`]+)`/.exec(description)?.[1];
    const hint = key ? relationshipForProperty(key) : null;
    if (hint) hints.push(hint);
  }
  if (codes.some((c) => c.includes('UnknownRelationshipType'))) {
    hints.push(`Relationship types in this graph: ${[...new Set(RELATIONSHIPS.map((r) => r.type))].join(', ')}.`);
  }
  if (codes.some((c) => c.includes('UnknownLabel'))) hints.push(`Labels in this graph: ${LABELS.map((l) => l.label).join(', ')}.`);
  if (codes.some((c) => c.includes('UnknownPropertyKey'))) {
    const used = LABELS.filter((l) => new RegExp(`:\\s*${l.label}\\b`).test(cypher));
    const shown = used.length ? used : LABELS.slice(0, 2);
    hints.push(`Properties: ${shown.map((l) => `${l.label}(${l.properties.map((p) => p.name).join(', ')})`).join('; ')}.`);
  }
  return hints;
}

type LabelProperties = Map<string, Set<string>>;
const propertyCache = new WeakMap<GraphDb, { at: number; value: Promise<LabelProperties> }>();

/** The property keys each label really carries in the loaded graph (cached for a minute per engine). */
export function labelProperties(db: GraphDb): Promise<LabelProperties> {
  const cached = propertyCache.get(db);
  if (cached && performance.now() - cached.at < 60_000) return cached.value;
  const value = db
    .query<{ label: string; keys: string[] }>('MATCH (n) UNWIND labels(n) AS label UNWIND keys(n) AS key RETURN label, collect(DISTINCT key) AS keys')
    .then((result) => new Map(result.rows.map((r) => [r.label, new Set(r.keys)])));
  value.catch(() => propertyCache.delete(db));
  propertyCache.set(db, { at: performance.now(), value });
  return value;
}

/**
 * `b.price` where b is a Book: the key exists in the database (on Edition), so
 * the engine has nothing to warn about, and the statement quietly returns
 * nulls. This reads `variable.property` against the labels the variable was
 * declared with and says where the property really lives.
 */
export function misplacedProperties(cypher: string, properties: LabelProperties): string[] {
  const bare = stripLiterals(cypher);
  const bound = new Map<string, string[]>();
  for (const match of bare.matchAll(/\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*((?::\s*[A-Za-z_][A-Za-z0-9_]*\s*)+)/g)) {
    if (!bound.has(match[1])) bound.set(match[1], match[2].split(':').map((l) => l.trim()).filter(Boolean));
  }
  const problems = new Set<string>();
  for (const match of bare.matchAll(/(?<![\w.$`])([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)(?!\s*\()/g)) {
    const [, variable, key] = match;
    const labels = bound.get(variable)?.filter((l) => properties.has(l));
    if (!labels?.length || labels.some((l) => properties.get(l)!.has(key))) continue;
    const owners = [...properties.entries()].filter(([, keys]) => keys.has(key)).map(([label]) => label);
    if (owners.length === 0) continue; // unknown everywhere: EXPLAIN reports it
    const related = relationshipForProperty(key);
    const path = owners
      .map((owner) => RELATIONSHIPS.find((r) => (r.from === owner && labels.includes(r.to)) || (r.to === owner && labels.includes(r.from))))
      .find(Boolean);
    problems.add(
      `${labels.join(':')} has no property \`${key}\` (${variable}.${key} is always null). \`${key}\` is a property of ${owners.join(', ')}` +
        (path ? `: (:${path.from})-[:${path.type}]->(:${path.to}).` : '.') +
        (related ? ` ${related}` : ''),
    );
  }
  return [...problems];
}

export async function validateCypher(db: GraphDb, cypher: string): Promise<Validation> {
  const guard = checkReadOnly(cypher);
  if (!guard.ok) return { ok: false, refused: guard.reason, problems: [guard.reason!] };

  let explained;
  try {
    explained = await db.query(`EXPLAIN ${cypher}`);
  } catch (err) {
    if (err instanceof CypherError) {
      const problems = [err.message.split('\n').slice(0, 3).join('\n').slice(0, 400)];
      if (/RelationshipPattern/.test(err.message)) problems.push('A relationship is written -[:TYPE]-> or -[r:TYPE]->. Alternatives use a bar and no variable: -[:WON|PART_OF]->.');
      return { ok: false, syntaxError: true, problems };
    }
    throw err;
  }
  const writes = writeOperators(explained.plan);
  if (writes.length) {
    const reason = `The plan writes to the graph (${writes.join(', ')}): only read-only queries run here.`;
    return { ok: false, refused: reason, problems: [reason] };
  }
  const unknown = explained.notifications.filter((n) => /Unknown(Label|PropertyKey|RelationshipType)Warning/.test(n.code));
  const misplaced = misplacedProperties(cypher, await labelProperties(db).catch(() => new Map() as LabelProperties));
  const problems = [...unknown.map((n) => n.description), ...nameHints(cypher, unknown.map((n) => n.code), unknown.map((n) => n.description)), ...misplaced];
  return { ok: problems.length === 0, problems };
}
