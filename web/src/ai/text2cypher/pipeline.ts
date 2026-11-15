// Question -> Cypher -> rows.
//
//   1. retrieve  the few-shot examples nearest to the question (embedding model)
//   2. link      names in the question to nodes (fulltext index over term names)
//   3. generate  one statement with the language model
//   4. check     relationship directions against the graph model (a backwards
//                arrow is flipped in place), the read-only guard, then EXPLAIN;
//                any other problem goes back to the model for a fix
//   5. run       with a time limit; an engine error also goes back for a fix
//
// Every step reports itself through `onEvent`, so the UI can show its work.

import { CypherError, type GraphDb, type QueryResult } from '../../engine/wire';
import * as searchQueries from '../../queries/search';
import { run } from '../../queries/statement';
import type { Embedder } from '../../search/embedder';
import { isStopword, KeywordQuery, tokens } from '../../search/keywordQuery';
import type { ChatMessage, Llm } from '../llm';
import { checkDirections } from './directions';
import { dropExtraBraces, ensureLimit, extractCypher, restoreNumbers } from './prepare';
import { retrieveExamples, type RetrievedExample } from './retrieve';
import { schemaText, systemPrompt, type ValueHints } from './schemaPrompt';
import { validateCypher } from './validate';

export interface LinkedName {
  label: string;
  name: string;
  score: number;
}

export interface Attempt {
  cypher: string;
  /** Why this attempt was not the final one. */
  problem: string | null;
  /** Corrections made without asking the model again (a reversed relationship). */
  fixes?: string[];
}

export type PipelineEvent =
  | { type: 'examples'; examples: RetrievedExample[] }
  | { type: 'names'; names: LinkedName[] }
  | { type: 'generating'; attempt: number }
  | { type: 'token'; delta: string }
  | { type: 'attempt'; attempt: Attempt }
  | { type: 'running'; cypher: string };

export interface TextToCypherResult {
  question: string;
  cypher: string | null;
  result: QueryResult | null;
  attempts: Attempt[];
  examples: RetrievedExample[];
  names: LinkedName[];
  /** Set when no runnable statement was produced. */
  error: string | null;
  ms: number;
}

export interface TextToCypherOptions {
  db: GraphDb;
  llm: Llm;
  embedder: Embedder | null;
  question: string;
  /** Statements may run this long (ms) before the engine is restarted. */
  queryTimeoutMs?: number;
  maxRepairs?: number;
  examples?: number;
  rowLimit?: number;
  onEvent?: (event: PipelineEvent) => void;
  signal?: AbortSignal;
  /** Labels and relationship types present in the graph; limits the schema text. */
  present?: { labels: Set<string>; types: Set<string> };
}

/** The distinct meaningful words of a name ("FICTION / Science Fiction" has two). */
const significant = (name: string) => [...new Set(tokens(name).filter((t) => [...t].length >= 2 && !isStopword(t)))];

/** The words of a name that the question must contain: all of them, bar single letters and a leading article. */
function requiredWords(name: string): string[] {
  const words = tokens(name).filter((t) => [...t].length >= 2);
  return ['the', 'a', 'an'].includes(words[0]) ? words.slice(1) : words;
}

/**
 * Names in the graph that the question spells out: every word of the name
 * appears in the question. Candidates come from the fulltext index over term
 * names and from book titles.
 *
 * Precision matters more than recall here, because a hint steers the model.
 * Each rule below removed a wrong answer in testing:
 * - every word counts, stopwords too ("About You Awards" is not meant by "awards");
 * - a name inside a longer linked name is dropped ("Mars" in "Red Mars",
 *   "Hail Mary" the place in "Project Hail Mary");
 * - a one-word Subject or Book title is never linked (there is a Subject for
 *   almost every common noun, and a book called "The Prize");
 * - a name that is only a number is never linked (there is an Era "2015").
 */
export async function linkNames(db: GraphDb, question: string, limit = 6): Promise<LinkedName[]> {
  const query = KeywordQuery.parse(question, 12);
  if (!query) return [];
  const asked = new Set(tokens(question));
  const lowered = question.toLowerCase();
  let rows: LinkedName[];
  try {
    const [terms, books] = await Promise.all([
      run<LinkedName>(db, searchQueries.terms(query.text, 60)),
      run<{ title: string | null; score: number }>(db, searchQueries.bookText(query.text, 20)),
    ]);
    rows = [...books.rows.map((b) => ({ label: 'Book', name: b.title ?? '', score: b.score })), ...terms.rows];
  } catch {
    return [];
  }
  const candidates = rows
    .filter((row) => typeof row.name === 'string' && row.name)
    .map((row) => ({ ...row, words: significant(row.name), required: requiredWords(row.name) }))
    .filter(
      (row) =>
        row.words.length > 0 &&
        row.required.every((w) => asked.has(w)) &&
        !row.words.every((w) => /^\d+$/.test(w)) &&
        !((row.label === 'Subject' || row.label === 'Book') && row.words.length < 2),
    )
    // Longest names first; among equals, one the question quotes exactly ("science fiction", not "FICTION / Science Fiction").
    .map((row) => ({ ...row, verbatim: lowered.includes(row.name.toLowerCase()) }))
    .sort((a, b) => b.words.length - a.words.length || Number(b.verbatim) - Number(a.verbatim) || b.score - a.score);

  const kept: Array<LinkedName & { words: string[] }> = [];
  const seen = new Set<string>();
  const perLabel = new Map<string, number>();
  for (const candidate of candidates) {
    const key = `${candidate.label}:${candidate.name.toLowerCase()}`;
    if (seen.has(key)) continue;
    const inside = kept.some((k) => k.words.length > candidate.words.length && candidate.words.every((w) => k.words.includes(w)));
    if (inside) continue;
    const count = perLabel.get(candidate.label) ?? 0;
    // One subject is enough: two hints came back as `a OR b AND c`, without parentheses.
    if (count >= (candidate.label === 'Subject' ? 1 : 2)) continue;
    seen.add(key);
    perLabel.set(candidate.label, count + 1);
    kept.push(candidate);
    if (kept.length >= limit) break;
  }
  return kept.map(({ label, name, score }) => ({ label, name, score }));
}

/** The commonest values of the few low-cardinality properties a question may name indirectly ("American", "paperbacks"). */
export async function valueHints(db: GraphDb): Promise<ValueHints> {
  const top = async (cypher: string, limit: number): Promise<string[]> => {
    try {
      const result = await db.query<{ name: string | null }>(cypher, { limit });
      return result.rows.map((r) => r.name).filter((n): n is string => typeof n === 'string' && n.length > 0 && n.length < 60 && !n.includes("'"));
    } catch {
      return [];
    }
  };
  const [countries, genres, formats] = await Promise.all([
    top('MATCH (c:Country)<-[:CITIZEN_OF]-(a:Author) RETURN c.name AS name, count(a) AS n ORDER BY n DESC, name LIMIT $limit', 12),
    top('MATCH (g:Genre)<-[:IN_GENRE]-(b:Book) RETURN g.name AS name, count(b) AS n ORDER BY n DESC, name LIMIT $limit', 12),
    top('MATCH (e:Edition) WHERE e.format IS NOT NULL RETURN e.format AS name, count(*) AS n ORDER BY n DESC, name LIMIT $limit', 6),
  ]);
  return { 'Country.name': countries, 'Genre.name': genres, 'Edition.format': formats };
}

/** How a linked name is best matched. Subjects come in many spellings of one phrase, so they are matched loosely. */
function nameHint(n: LinkedName): string {
  if (n.label === 'Book') return `- Book.title = "${n.name}"`;
  if (n.label === 'Subject') return `- Subject: toLower(s.name) CONTAINS '${n.name.toLowerCase().replace(/'/g, "\\'")}'`;
  return `- ${n.label}.name = "${n.name}"`;
}

export function buildMessages(question: string, examples: RetrievedExample[], names: LinkedName[], schema: string, values: ValueHints = {}): ChatMessage[] {
  const messages: ChatMessage[] = [{ role: 'system', content: systemPrompt(schema, values) }];
  // Nearest example last, next to the question.
  for (const example of [...examples].reverse()) {
    messages.push({ role: 'user', content: example.question });
    messages.push({ role: 'assistant', content: example.cypher });
  }
  const hints = names.length
    ? `\n\nNames in the graph:\n${names.map(nameHint).join('\n')}`
    : '';
  messages.push({ role: 'user', content: `${question}${hints}` });
  return messages;
}

export async function textToCypher(options: TextToCypherOptions): Promise<TextToCypherResult> {
  const started = performance.now();
  const { db, llm, embedder, question, onEvent, signal } = options;
  const maxRepairs = options.maxRepairs ?? 2;
  const attempts: Attempt[] = [];

  const [examples, names, values] = await Promise.all([retrieveExamples(question, embedder, options.examples ?? 5), linkNames(db, question), valueHints(db)]);
  onEvent?.({ type: 'examples', examples });
  onEvent?.({ type: 'names', names });

  const messages = buildMessages(question, examples, names, schemaText(options.present?.labels, options.present?.types), values);
  const finish = (cypher: string | null, result: QueryResult | null, error: string | null): TextToCypherResult => ({
    question,
    cypher,
    result,
    attempts,
    examples,
    names,
    error,
    ms: performance.now() - started,
  });

  for (let attempt = 0; attempt <= maxRepairs; attempt++) {
    signal?.throwIfAborted();
    onEvent?.({ type: 'generating', attempt });
    const reply = await llm.complete(messages, { temperature: 0, maxTokens: 400, signal, onToken: (delta) => onEvent?.({ type: 'token', delta }) });
    const extracted = extractCypher(reply);
    if (!extracted) {
      const problem = 'The model did not return a Cypher statement.';
      attempts.push({ cypher: reply.trim(), problem });
      onEvent?.({ type: 'attempt', attempt: attempts[attempts.length - 1] });
      messages.push({ role: 'assistant', content: reply }, { role: 'user', content: 'Reply with one Cypher statement only.' });
      continue;
    }
    // Three slips are corrected here rather than sent back: a doubled closing
    // brace, a number that lost its last digit, and a relationship written
    // backwards.
    const braces = dropExtraBraces(ensureLimit(extracted, options.rowLimit ?? 50));
    const numbers = restoreNumbers(question, braces.cypher);
    const directions = checkDirections(numbers.cypher);
    const cypher = directions.cypher;
    const corrections = [...braces.fixes, ...numbers.fixes, ...directions.fixes];
    const fixes = corrections.length ? corrections : undefined;

    const validation = await validateCypher(db, cypher);
    // A statement that does not parse gets the parser's message alone; the
    // direction check reads patterns and is only meaningful on valid syntax.
    const found = validation.syntaxError ? validation.problems : [...directions.problems, ...validation.problems];
    let problem: string | null = found.length ? found.join('\n') : null;
    if (validation.refused) {
      attempts.push({ cypher, problem, fixes });
      onEvent?.({ type: 'attempt', attempt: attempts[attempts.length - 1] });
      return finish(null, null, validation.refused);
    }

    if (!problem) {
      onEvent?.({ type: 'running', cypher });
      try {
        const result = await db.query(cypher, undefined, { timeoutMs: options.queryTimeoutMs ?? 15_000 });
        attempts.push({ cypher, problem: null, fixes });
        onEvent?.({ type: 'attempt', attempt: attempts[attempts.length - 1] });
        return finish(cypher, result, null);
      } catch (err) {
        if (!(err instanceof CypherError)) {
          attempts.push({ cypher, problem: (err as Error).message, fixes });
          onEvent?.({ type: 'attempt', attempt: attempts[attempts.length - 1] });
          return finish(null, null, (err as Error).message);
        }
        problem = err.message.split('\n').slice(0, 3).join('\n');
      }
    }

    attempts.push({ cypher, problem, fixes });
    onEvent?.({ type: 'attempt', attempt: attempts[attempts.length - 1] });
    messages.push(
      { role: 'assistant', content: cypher },
      { role: 'user', content: `That statement cannot run:\n${problem}\n\nWrite the corrected Cypher statement for the same question. Statement only.` },
    );
  }
  return finish(null, null, `No runnable query after ${maxRepairs + 1} attempts. Last problem: ${attempts[attempts.length - 1]?.problem ?? 'unknown'}`);
}
