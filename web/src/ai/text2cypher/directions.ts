// Relationship directions are the most common mistake a small model makes:
// (a:Author)-[:WRITTEN_BY]->(b:Book) parses, plans, runs, and returns nothing.
// This pass reads the patterns in a statement, compares each labelled
// relationship with the graph model, flips the ones that are simply
// backwards, and reports the ones that connect labels the model does not
// connect at all (those go back to the language model).

import { RELATIONSHIPS } from '../../engine/schema';
import { stripLiterals } from './guard';

export interface DirectionReport {
  /** The statement with backwards relationships flipped. */
  cypher: string;
  /** One line per flip, for the trace. */
  fixes: string[];
  /** Patterns the graph model has no relationship for. */
  problems: string[];
}

/** An Edition is also an Item, so either label satisfies the other's place in the model. */
const ALIASES: Record<string, string[]> = { Edition: ['Edition', 'Item'], Item: ['Item', 'Edition'] };
const sameLabel = (model: string, written: string) => model === written || (ALIASES[model] ?? []).includes(written);

function known(from: string[] | null, type: string, to: string[] | null): boolean {
  return RELATIONSHIPS.some(
    (r) => r.type === type && (from === null || from.some((l) => sameLabel(r.from, l))) && (to === null || to.some((l) => sameLabel(r.to, l))),
  );
}

const describe = (type: string) =>
  RELATIONSHIPS.filter((r) => r.type === type)
    .map((r) => `(:${r.from})-[:${type}]->(:${r.to})`)
    .join(' or ');

interface NodeRef {
  variable: string | null;
  labels: string[] | null;
}

function parseNode(inner: string): NodeRef {
  const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)?\s*((?::\s*[A-Za-z_][A-Za-z0-9_]*\s*)*)/.exec(inner);
  const variable = match?.[1] ?? null;
  const labels = (match?.[2] ?? '').split(':').map((l) => l.trim()).filter(Boolean);
  return { variable, labels: labels.length ? labels : null };
}

export function checkDirections(cypher: string): DirectionReport {
  const bare = stripLiterals(cypher);
  // Labels a variable was declared with anywhere in the statement.
  const bound = new Map<string, string[]>();
  for (const match of bare.matchAll(/\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*((?::\s*[A-Za-z_][A-Za-z0-9_]*\s*)+)/g)) {
    const labels = match[2].split(':').map((l) => l.trim()).filter(Boolean);
    if (!bound.has(match[1])) bound.set(match[1], labels);
  }
  const labelsOf = (node: NodeRef) => node.labels ?? (node.variable ? (bound.get(node.variable) ?? null) : null);

  const fixes: string[] = [];
  const problems: string[] = [];
  const edits: Array<{ start: number; end: number; text: string }> = [];
  // (left) <?- [rel] ->? (right), with the right node only looked at, so chains are walked link by link.
  const link = /\(([^()]*)\)\s*(<?)-\s*\[([^\]]*)\]\s*-(>?)\s*(?=\(([^()]*)\))/g;
  for (const match of bare.matchAll(link)) {
    const [whole, leftInner, leftArrow, relInner, rightArrow, rightInner] = match;
    if ((leftArrow === '<') === (rightArrow === '>')) continue; // undirected, or malformed
    if (/\*/.test(relInner)) continue; // variable length: leave alone
    const types = (/:\s*([A-Za-z_][A-Za-z0-9_|:\s]*)/.exec(relInner)?.[1] ?? '').split(/[|:]/).map((t) => t.trim()).filter(Boolean);
    if (types.length === 0) continue;
    const left = labelsOf(parseNode(leftInner));
    const right = labelsOf(parseNode(rightInner));
    if (!left && !right) continue;
    const [from, to] = rightArrow === '>' ? [left, right] : [right, left];
    // Only types the model knows; an unknown type is the EXPLAIN step's to report.
    const modelled = types.filter((t) => RELATIONSHIPS.some((r) => r.type === t));
    if (modelled.length === 0 || modelled.some((t) => known(from, t, to))) continue;

    if (modelled.some((t) => known(to, t, from))) {
      // Backwards: swap the arrow, keeping the relationship's own text.
      const relStart = match.index + whole.indexOf(leftArrow + '-', leftInner.length + 2);
      const relText = bare.slice(relStart, match.index + whole.length);
      const original = cypher.slice(relStart, relStart + relText.length);
      const body = original.slice(original.indexOf('['), original.lastIndexOf(']') + 1);
      edits.push({ start: relStart, end: relStart + relText.length, text: rightArrow === '>' ? `<-${body}-` : `-${body}->` });
      fixes.push(`${modelled[0]} runs ${describe(modelled[0])}; the arrow was reversed.`);
    } else {
      problems.push(`[:${modelled.join('|')}] does not connect ${(from ?? ['?']).join(':')} to ${(to ?? ['?']).join(':')}. In this graph: ${modelled.map(describe).join('; ')}.`);
    }
  }

  let fixed = cypher;
  for (const edit of edits.sort((a, b) => b.start - a.start)) fixed = fixed.slice(0, edit.start) + edit.text + fixed.slice(edit.end);
  return { cypher: fixed, fixes: [...new Set(fixes)], problems: [...new Set(problems)] };
}
