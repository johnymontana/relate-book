// The schema and dialect notes a model needs to write Cypher for this graph.
// Compact on purpose: in-browser models run with a small context window.

import { LABELS, RELATIONSHIPS } from '../../engine/schema';

/** Only the labels and relationship types present in the loaded graph are described. */
export function schemaText(presentLabels?: Set<string>, presentTypes?: Set<string>): string {
  const labels = LABELS.filter((l) => !presentLabels || presentLabels.has(l.label));
  const nodes = labels.map((l) => {
    const props = l.properties.map((p) => (p.type === 'STRING' && !p.note ? p.name : `${p.name}: ${p.type}${p.note ? ` (${p.note})` : ''}`));
    return `(:${l.label} {${props.join(', ')}}) - ${l.description}`;
  });
  const known = new Set(labels.map((l) => l.label));
  const rels = RELATIONSHIPS.filter((r) => known.has(r.from) && known.has(r.to) && (!presentTypes || presentTypes.has(r.type))).map((r) => {
    const props = r.properties?.length ? ` {${r.properties.map((p) => p.name).join(', ')}}` : '';
    return `(:${r.from})-[:${r.type}${props}]->(:${r.to})${r.description ? ` - ${r.description}` : ''}`;
  });
  return `Nodes:\n${nodes.join('\n')}\n\nRelationships:\n${rels.join('\n')}`;
}

/** What differs from the Cypher a model has seen most (Neo4j with APOC). Each line earned its place by a failure. */
export const DIALECT_RULES = [
  'Write exactly one read-only Cypher statement: MATCH / OPTIONAL MATCH / WHERE / WITH / RETURN / ORDER BY / LIMIT. Never CREATE, MERGE, SET, DELETE or REMOVE.',
  'Use only the labels, relationship types and properties in the schema. Follow the relationship directions shown. One relationship per pattern step: -[:WON]->. Never write OR or AND inside [ ].',
  "String comparison is case-sensitive. Match names loosely: toLower(a.name) CONTAINS 'le guin'. Subject names are free-form and mixed case, so always use toLower(s.name) CONTAINS '...'.",
  'When a name is listed under "Names in the graph", it exists with exactly that spelling: use it with = (for a Subject, with toLower(s.name) CONTAINS).',
  'Return properties with readable aliases (b.title AS title), not whole nodes, unless the question asks to show or draw a graph; then return a path defined in that same MATCH: MATCH p = (...)-[...]->(...) RETURN p.',
  'Use RETURN DISTINCT when listing books, authors or other names, and count(DISTINCT b) when counting: a pattern can match a book more than once, and one author can have several Author nodes with the same name.',
  'A nationality (American, British) is a Country: (a:Author)-[:CITIZEN_OF]->(c:Country), with a Country.name from "Values in this graph".',
  'A missing value sorts first with ORDER BY ... DESC: add WHERE x IS NOT NULL before sorting on x. There is no NULLS LAST.',
  'No APOC and no GDS procedures. For a ratio use toFloat(). Years are integers (b.first_publish_year); Author.birth_date is free text, do not compare it.',
  'A rating of 0 means "no ratings": filter b.ol_rating > 0 when ranking by rating.',
  'Every Book in the graph is on the user\'s wishlist: "my books" and "on my list" need no filter of their own.',
  'End with LIMIT 25 unless the question asks for a count or a specific number.',
].map((rule, i) => `${i + 1}. ${rule}`).join('\n');

export interface ValueHints {
  /** `Label.property` -> its most common values in the loaded graph. */
  [property: string]: string[];
}

export function valuesText(values: ValueHints): string {
  const lines = Object.entries(values)
    .filter(([, names]) => names.length > 0)
    .map(([property, names]) => `${property}: ${names.map((n) => `'${n}'`).join(', ')}`);
  return lines.length ? `\n\nValues in this graph (most common first):\n${lines.join('\n')}` : '';
}

export function systemPrompt(schema: string, values: ValueHints = {}): string {
  return `You translate questions about a personal book wishlist into Cypher for the Relate graph database.

${schema}${valuesText(values)}

Rules:
${DIALECT_RULES}

Answer with the Cypher statement only. No explanation, no code fence.`;
}
