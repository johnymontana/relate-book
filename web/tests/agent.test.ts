import { beforeAll, describe, expect, it } from 'vitest';
import { answerPrompt, parseStep, plannerPrompt, runAgent, STEP_SCHEMA, type AgentEvent } from '../src/ai/agent/loop';
import { formatRows, resolveBook, TOOLS } from '../src/ai/agent/tools';
import { StubLlm } from '../src/ai/stubLlm';
import { indexBooks } from '../src/search/indexer';
import { StubEmbedder } from '../src/search/stubEmbedder';
import { sampleDb, type TestDb } from './helpers/engine';

let db: TestDb;
const embedder = new StubEmbedder();
beforeAll(async () => {
  db = await sampleDb();
  await indexBooks(db, embedder);
});

const step = (tool: string, input: string, thought = 't') => JSON.stringify({ thought, tool, input });

describe('tools', () => {
  const tool = (name: string) => TOOLS.find((t) => t.name === name)!;
  const context = () => ({ db, llm: new StubLlm(), embedder });

  it('search_books lists matches with authors and years', async () => {
    const out = await tool('search_books').run('colonization of Mars', context());
    expect(out.observation).toMatch(/^Books related to "colonization of Mars" \(semantic and keyword search; relevance only[^\n]*\):\n1\. Red Mars by Kim Stanley Robinson \(1992\) rated 3\.6 · Kindle Edition USD 3\.99 · 592 pages/);
    expect(out.books[0].title).toBe('Red Mars');
    expect(out.table!.rows[0]).toMatchObject({ title: 'Red Mars', match: 'both' });
    expect((await tool('search_books').run('zzzz qqqq', { ...context(), embedder: null })).observation).toBe('No books match "zzzz qqqq".');
  });

  it('query_graph runs text-to-Cypher and reports rows and the statement', async () => {
    const llm = new StubLlm(['MATCH (b:Book) RETURN count(b) AS books']);
    const out = await tool('query_graph').run('How many books are there?', { db, llm, embedder });
    expect(out.observation).toBe('Query result (1 row):\nbooks: 6');
    expect(out.cypher).toBe('MATCH (b:Book) RETURN count(b) AS books\nLIMIT 25');
    const failed = await tool('query_graph').run('delete everything', { db, llm: new StubLlm(['MATCH (n) DETACH DELETE n']), embedder });
    expect(failed.failed).toBe(true);
    expect(failed.observation).toMatch(/^LOOKUP FAILED, nothing was found out: DETACH is not allowed/);

    // A failed paraphrase is retried once with what the user actually asked.
    const retry = new StubLlm(['MATCH (', 'MATCH ((', 'nope', 'MATCH (b:Book) RETURN count(b) AS books']);
    const second = await tool('query_graph').run('books total number please', { db, llm: retry, embedder, userQuestion: 'How many books are there?' });
    expect(second.failed).toBeUndefined();
    expect(second.observation).toBe('Query result (1 row):\nbooks: 6');
    expect(retry.calls[3].messages[retry.calls[3].messages.length - 1].content).toContain('How many books are there?');
    expect((await db.query('MATCH (b:Book) RETURN count(b) AS n')).rows[0]).toEqual({ n: 6 });
  });

  it('book_details resolves a partial title and summarises the book', async () => {
    const out = await tool('book_details').run('left hand of darkness', context());
    expect(out.observation).toContain('The Left Hand of Darkness by Ursula K. Le Guin, first published 1969.');
    expect(out.observation).toContain('Series: Hainish Cycle #4.');
    expect(out.observation).toContain('Awards:');
    expect(out.books).toEqual([expect.objectContaining({ title: 'The Left Hand of Darkness' })]);
    expect((await tool('book_details').run('Moby-Dick', context())).failed).toBe(true);
  });

  it('similar_books ranks neighbours and excludes the book', async () => {
    const out = await tool('similar_books').run('Red Mars', context());
    expect(out.observation).toMatch(/^Most similar to "Red Mars":\n1\. /);
    expect(out.books[0].title).toBe('Red Mars');
    expect(out.books.slice(1).map((b) => b.title)).not.toContain('Red Mars');
  });

  it('resolveBook tries exact, contains, then fulltext', async () => {
    expect((await resolveBook(db, 'RED MARS'))?.title).toBe('Red Mars');
    expect((await resolveBook(db, '"Project Hail"'))?.title).toBe('Project Hail Mary');
    expect((await resolveBook(db, 'Curious Incident Dog Night-Time'))?.title).toBe('The Curious Incident of the Dog in the Night-Time');
    expect(await resolveBook(db, 'No Such Book At All')).toBeNull();
    expect(await resolveBook(db, '  ')).toBeNull();
  });

  it('formatRows keeps observations small', () => {
    const rows = Array.from({ length: 20 }, (_, i) => ({ title: `Book ${i}`, n: i + 0.123456 }));
    const text = formatRows(['title', 'n'], rows, 3);
    expect(text).toBe('title: Book 0 | n: 0.12\ntitle: Book 1 | n: 1.12\ntitle: Book 2 | n: 2.12\n… and 17 more rows');
    expect(formatRows(['x'], [])).toBe('(no rows)');
    expect(formatRows(['title'], [{ title: 'A' }, { title: 'A' }, { title: 'B' }])).toBe('title: A\ntitle: B');
    expect(formatRows(['n', 'e', 'l'], [{ n: { kind: 'node', labels: ['Book'], properties: { title: 'Red Mars', embedding: { values: [1] } } }, e: { values: [1, 2] }, l: ['a', 'b'] }])).toBe(
      'n: (:Book Red Mars) | e: [vector] | l: [a, b]',
    );
  });
});

describe('parseStep', () => {
  it('reads a step, tolerates wrapping text, rejects unknown tools', () => {
    expect(parseStep(step('search_books', 'mars'))).toEqual({ thought: 't', tool: 'search_books', input: 'mars' });
    expect(parseStep(`<think>hmm</think> Sure: ${step('answer', '')} done`)).toEqual({ thought: 't', tool: 'answer', input: '' });
    expect(parseStep(step('delete_books', 'x'))).toBeNull();
    expect(parseStep('not json')).toBeNull();
    expect(parseStep('{"tool": "query_graph", "input": {"q": 1}}')).toEqual({ thought: '', tool: 'query_graph', input: '{"q":1}' });
  });

  it('has a schema that lists every tool plus answer', () => {
    expect(STEP_SCHEMA.properties.tool.enum).toEqual(['search_books', 'query_graph', 'book_details', 'similar_books', 'answer']);
    for (const t of TOOLS) expect(plannerPrompt()).toContain(`- ${t.name}: `);
    expect(answerPrompt()).toMatch(/only the observations/);
    expect(answerPrompt()).toMatch(/Never invent one/);
  });
});

describe('runAgent', () => {
  it('calls a tool, then answers from the observation, streaming the answer', async () => {
    const llm = new StubLlm([step('search_books', 'colonization of Mars'), step('answer', ''), 'Red Mars by Kim Stanley Robinson fits.']);
    const events: AgentEvent[] = [];
    const out = await runAgent({ db, llm, embedder, question: 'Anything about colonizing Mars?', onEvent: (e) => events.push(e) });
    expect(out.answer).toBe('Red Mars by Kim Stanley Robinson fits.');
    expect(out.steps).toHaveLength(1);
    expect(out.steps[0]).toMatchObject({ tool: 'search_books', input: 'colonization of Mars' });
    expect(out.books.map((b) => b.title)).toContain('Red Mars');
    expect(events.map((e) => e.type).filter((t) => t !== 'answer-token')).toEqual(['thinking', 'tool-start', 'tool-end', 'thinking', 'answer-start']);
    expect(events.filter((e) => e.type === 'answer-token').map((e) => (e as { delta: string }).delta).join('')).toBe(out.answer);

    // The planner is constrained to the step schema; the answer is free text over the observations.
    expect(llm.calls[0].options?.jsonSchema).toBe(STEP_SCHEMA);
    expect(llm.calls[1].messages[llm.calls[1].messages.length - 1].content).toMatch(/^Observation:\nBooks related to "colonization of Mars"/);
    expect(llm.calls[2].options?.jsonSchema).toBeUndefined();
    expect(llm.calls[2].messages[llm.calls[2].messages.length - 1].content).toMatch(/^Question: Anything about colonizing Mars\?\n\nObservations:\n\[1\] search_books\("colonization of Mars"\)/);
  });

  it('chains tools and uses the nested text-to-Cypher model call', async () => {
    const llm = new StubLlm([
      step('query_graph', 'How many books are on the list?'),
      'MATCH (b:Book) RETURN count(b) AS books', // the Cypher generation inside query_graph
      step('book_details', 'Project Hail Mary'),
      step('answer', ''),
      'Six books; Project Hail Mary is by Andy Weir.',
    ]);
    const out = await runAgent({ db, llm, embedder, question: 'How many books, and who wrote Project Hail Mary?' });
    expect(out.steps.map((s) => s.tool)).toEqual(['query_graph', 'book_details']);
    expect(out.steps[0].result.cypher).toContain('count(b) AS books');
    expect(out.steps[0].result.table!.rows).toEqual([{ books: 6 }]);
    expect(out.answer).toContain('Six books');
  });

  it("sends the user's own words to the first graph lookup, and the model's words to later ones", async () => {
    const llm = new StubLlm([
      step('query_graph', 'a clumsy paraphrase about book totals'),
      'MATCH (b:Book) RETURN count(b) AS books',
      step('query_graph', 'How many authors are there?'),
      'MATCH (a:Author) RETURN count(a) AS authors',
      step('answer', ''),
      'Six books, eight author records.',
    ]);
    const out = await runAgent({ db, llm, embedder, question: 'How many books are on my list?' });
    expect(out.steps.map((s) => s.input)).toEqual(['How many books are on my list?', 'How many authors are there?']);
    // The Cypher prompt for the first lookup carries the user's question.
    expect(llm.calls[1].messages[llm.calls[1].messages.length - 1].content).toContain('How many books are on my list?');

    // In a follow-up turn the paraphrase carries context the bare question lacks, so it is kept.
    const followUp = new StubLlm([step('query_graph', 'How many books by Andy Weir are there?'), 'MATCH (b:Book) RETURN count(b) AS books', step('answer', ''), 'One.']);
    const second = await runAgent({ db, llm: followUp, embedder, question: 'and how many by him?', history: [{ question: 'Who wrote Project Hail Mary?', answer: 'Andy Weir.' }] });
    expect(second.steps[0].input).toBe('How many books by Andy Weir are there?');
  });

  it('answers at once when no data is needed, and survives a malformed step', async () => {
    const direct = await runAgent({ db, llm: new StubLlm([step('answer', ''), 'Hello!']), embedder, question: 'hi' });
    expect(direct.steps).toEqual([]);
    expect(direct.answer).toBe('Hello!');
    const llm = new StubLlm(['garbage', 'I could not plan that.']);
    const out = await runAgent({ db, llm, embedder, question: '??' });
    expect(out.steps).toEqual([]);
    expect(llm.calls[1].messages[llm.calls[1].messages.length - 1].content).toContain('(no tools were used)');
  });

  it('does not repeat an identical call and stops at the step budget', async () => {
    const llm = new StubLlm([step('search_books', 'mars'), step('search_books', 'MARS'), step('search_books', 'venus'), step('search_books', 'jupiter'), 'Done.']);
    const out = await runAgent({ db, llm, embedder, question: 'planets', maxSteps: 4 });
    expect(out.steps.map((s) => s.input)).toEqual(['mars', 'venus', 'jupiter']);
    expect(llm.calls[2].messages[llm.calls[2].messages.length - 1].content).toMatch(/already made that call/);
    expect(llm.calls).toHaveLength(5);
  });

  it('reports a failing tool to the model instead of throwing', async () => {
    const llm = new StubLlm([step('book_details', 'Nonexistent Book'), step('answer', ''), 'That book is not on the list.']);
    const out = await runAgent({ db, llm, embedder, question: 'Tell me about Nonexistent Book' });
    expect(out.steps[0].result.failed).toBe(true);
    expect(out.answer).toBe('That book is not on the list.');
  });

  it('carries the last turns of the conversation', async () => {
    const llm = new StubLlm([step('answer', ''), 'Yes.']);
    await runAgent({
      db, llm, embedder, question: 'And the second one?',
      history: [{ question: 'q1', answer: 'a1' }, { question: 'q2', answer: 'a2' }, { question: 'q3', answer: 'a3' }, { question: 'q4', answer: 'x'.repeat(900) }],
    });
    const planning = llm.calls[0].messages;
    expect(planning.map((m) => m.role)).toEqual(['system', 'user', 'assistant', 'user', 'assistant', 'user', 'assistant', 'user']);
    expect(planning[1].content).toBe('q2');
    expect(planning[6].content.length).toBe(501);
  });

  it('works end to end with the built-in stub behaviour', async () => {
    const out = await runAgent({ db, llm: new StubLlm(), embedder, question: 'Which authors have the most books on my list?' });
    expect(out.steps[0].tool).toBe('query_graph');
    expect(out.answer).toMatch(/^From the wishlist graph: /);
  });

  it('stops when aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(runAgent({ db, llm: new StubLlm(), embedder, question: 'x', signal: controller.signal })).rejects.toThrow();
  });
});
