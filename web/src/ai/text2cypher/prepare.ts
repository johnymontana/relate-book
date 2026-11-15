// Turning a model's reply into one runnable statement.

import { stripThinking } from '../llm';
import { stripLiterals } from './guard';

/** The Cypher in a reply: the first fenced block if there is one, else the text from the first clause on. */
export function extractCypher(reply: string): string {
  let text = stripThinking(reply);
  const fenced = /```(?:cypher|sql|text)?\s*\n?([\s\S]*?)```/i.exec(text);
  if (fenced) text = fenced[1];
  else text = text.replace(/```(?:cypher)?/gi, '');
  // Drop a preamble such as "Here is the query:".
  const start = text.search(/\b(MATCH|OPTIONAL\s+MATCH|WITH|UNWIND|RETURN|CALL|SHOW)\b/i);
  if (start > 0) text = text.slice(start);
  // And an explanation after a blank line.
  const blank = text.search(/\n\s*\n(?!\s*(MATCH|OPTIONAL|WITH|UNWIND|RETURN|CALL|WHERE|ORDER|LIMIT|SKIP|UNION|SEARCH)\b)/i);
  if (blank > 0) text = text.slice(0, blank);
  return text.trim().replace(/;+\s*$/, '').trim();
}

/** Add `LIMIT n` when the statement has no LIMIT after its last RETURN, so a runaway result cannot fill the page. */
export function ensureLimit(cypher: string, limit = 50): string {
  const bare = stripLiterals(cypher);
  const lastReturn = bare.toUpperCase().lastIndexOf('RETURN');
  if (lastReturn === -1) return cypher;
  if (/\bLIMIT\b/i.test(bare.slice(lastReturn))) return cypher;
  return `${cypher.trimEnd()}\nLIMIT ${limit}`;
}

/**
 * Small quantized models sometimes drop the last digit of a number they are
 * copying from the question (digits are one token each): "before 2000" became
 * `< 200`, "more than 400 pages" became `> 40`. When the statement holds a
 * number that is a question number minus its final digit, and the question
 * itself never says that shorter number, the question's number is restored.
 */
export function restoreNumbers(question: string, cypher: string): { cypher: string; fixes: string[] } {
  const asked = new Set(question.match(/\d+/g) ?? []);
  const bare = stripLiterals(cypher);
  const fixes: string[] = [];
  const edits: Array<{ start: number; end: number; text: string }> = [];
  for (const match of bare.matchAll(/(?<![\w.$])\d+(?![\w.])/g)) {
    const written = match[0];
    if (asked.has(written)) continue;
    const meant = [...asked].filter((n) => n.length >= 3 && n.length === written.length + 1 && n.startsWith(written));
    if (meant.length !== 1) continue;
    // LIMIT and SKIP counts are the model's own, not copied from the question.
    if (/\b(LIMIT|SKIP)\s*$/i.test(bare.slice(0, match.index))) continue;
    edits.push({ start: match.index, end: match.index + written.length, text: meant[0] });
    fixes.push(`The question says ${meant[0]}; the statement had ${written}.`);
  }
  let fixed = cypher;
  for (const edit of edits.sort((a, b) => b.start - a.start)) fixed = fixed.slice(0, edit.start) + edit.text + fixed.slice(edit.end);
  return { cypher: fixed, fixes: [...new Set(fixes)] };
}

/**
 * Another copying slip, seen with the 7B model: a property map closed twice,
 * `(p:Place {name: 'Montana'}})`. When the statement has more closing braces
 * than opening ones and a doubled `}}` to blame, the extra brace is dropped.
 */
export function dropExtraBraces(cypher: string): { cypher: string; fixes: string[] } {
  let fixed = cypher;
  let dropped = 0;
  for (let round = 0; round < 3; round++) {
    const bare = stripLiterals(fixed);
    const surplus = (bare.match(/}/g) ?? []).length - (bare.match(/{/g) ?? []).length;
    const at = bare.indexOf('}}');
    if (surplus <= 0 || at === -1) break;
    fixed = fixed.slice(0, at) + fixed.slice(at + 1);
    dropped += 1;
  }
  return { cypher: fixed, fixes: dropped ? [`Removed ${dropped === 1 ? 'a doubled closing brace' : `${dropped} doubled closing braces`}.`] : [] };
}
