// Generated Cypher is only ever run when it is a single read-only statement.
//
// Relate WASM has no per-statement read-only mode, so there are two checks:
// this lexical one (before anything reaches the engine) and a look at the
// EXPLAIN plan's operators (validate.ts). Either refusing is enough.

import type { PlanOperator, WirePlan } from '../../engine/wire';

export interface GuardVerdict {
  ok: boolean;
  reason?: string;
}

/** Replace string literals, quoted identifiers and comments with spaces, keeping offsets. */
export function stripLiterals(cypher: string): string {
  let out = '';
  let i = 0;
  const n = cypher.length;
  while (i < n) {
    const c = cypher[i];
    const next = cypher[i + 1];
    if (c === '/' && next === '/') {
      while (i < n && cypher[i] !== '\n') {
        out += ' ';
        i++;
      }
    } else if (c === '/' && next === '*') {
      const end = cypher.indexOf('*/', i + 2);
      const stop = end === -1 ? n : end + 2;
      out += ' '.repeat(stop - i);
      i = stop;
    } else if (c === "'" || c === '"' || c === '`') {
      const quote = c;
      let j = i + 1;
      while (j < n) {
        if (cypher[j] === '\\' && quote !== '`') j += 2;
        else if (cypher[j] === quote) {
          if (quote === '`' && cypher[j + 1] === '`') j += 2;
          else break;
        } else j++;
      }
      const stop = Math.min(n, j + 1);
      // Keep the delimiters so "x = ''" still reads as a comparison.
      out += quote + ' '.repeat(Math.max(0, stop - i - 2)) + (stop - i >= 2 ? quote : '');
      i = stop;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

const WRITE_KEYWORDS = [
  'CREATE', 'MERGE', 'SET', 'DELETE', 'DETACH', 'REMOVE', 'DROP', 'FOREACH', 'LOAD', 'ALTER', 'GRANT', 'REVOKE', 'DENY', 'RENAME', 'START', 'STOP', 'TERMINATE', 'USE', 'INSERT',
];

const READ_PROCEDURES = /^db\.(labels|relationshipTypes|propertyKeys|schema\.[A-Za-z]+|index\.fulltext\.queryNodes|index\.fulltext\.queryRelationships|index\.vector\.queryNodes|index\.vector\.queryRelationships)$/;

/** A lexical read-only check. False positives (a refused read) are acceptable; a write passing is not. */
export function checkReadOnly(cypher: string): GuardVerdict {
  const text = stripLiterals(cypher).trim().replace(/;\s*$/, '');
  if (!text) return { ok: false, reason: 'The query is empty.' };
  if (text.includes(';')) return { ok: false, reason: 'Only one statement can run at a time.' };

  const word = /[A-Za-z_][A-Za-z0-9_]*/g;
  let match: RegExpExecArray | null;
  while ((match = word.exec(text))) {
    const token = match[0].toUpperCase();
    const before = text.slice(0, match.index).trimEnd();
    const after = text.slice(match.index + match[0].length).trimStart();
    // `n.set`, `{set: 1}`, `:Set` and `$set` are a property, a map key, a label and a parameter.
    if (before.endsWith('.') || before.endsWith(':') || before.endsWith('$')) continue;
    if (after.startsWith(':') && (before.endsWith('{') || before.endsWith(','))) continue;
    if (WRITE_KEYWORDS.includes(token)) {
      return { ok: false, reason: `${token} is not allowed: only read-only queries run here.` };
    }
    if (token === 'CALL') {
      // CALL { … } and CALL (x) { … } are subqueries; a procedure must be a known read.
      if (after.startsWith('{') || after.startsWith('(')) continue;
      const name = /^[A-Za-z_][A-Za-z0-9_.]*/.exec(after)?.[0] ?? '';
      if (!READ_PROCEDURES.test(name)) return { ok: false, reason: `CALL ${name || '…'} is not allowed: only read-only procedures run here.` };
    }
    if (token === 'TRANSACTIONS') return { ok: false, reason: 'CALL … IN TRANSACTIONS is not allowed.' };
  }
  return { ok: true };
}

const WRITE_OPERATOR = /create|merge|set|delete|remove|drop|foreach|loadcsv|constraint|index(?!seek|scan|search)/i;

/** The operators of a plan that write, if any (the second, engine-side opinion). */
export function writeOperators(plan: WirePlan | null): string[] {
  if (!plan) return [];
  const found: string[] = [];
  const visit = (op: PlanOperator) => {
    if (WRITE_OPERATOR.test(op.operator)) found.push(op.operator);
    op.children?.forEach(visit);
  };
  visit(plan.root);
  return found;
}
