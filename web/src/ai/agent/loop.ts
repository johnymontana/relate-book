// The chat agent: a small ReAct loop built for in-browser models.
//
// Each step the model emits one JSON object, constrained by a JSON schema
// (grammar-constrained decoding, so it always parses): a thought, a tool name
// and one string of input. The tool runs against the graph, its observation
// goes back into the conversation, and the loop continues until the model
// picks "answer" or the step budget runs out. The answer itself is a second,
// unconstrained generation over the observations, streamed to the UI.

import type { ChatMessage } from '../llm';
import { stripThinking } from '../llm';
import { TOOLS, type BookRef, type ToolContext, type ToolName, type ToolResult } from './tools';

export interface AgentStep {
  thought: string;
  tool: ToolName;
  input: string;
  result: ToolResult;
  ms: number;
}

export type AgentEvent =
  | { type: 'thinking'; step: number }
  | { type: 'tool-start'; step: number; thought: string; tool: ToolName; input: string }
  | { type: 'tool-end'; step: number; record: AgentStep }
  | { type: 'answer-start' }
  | { type: 'answer-token'; delta: string };

export interface AgentTurn {
  question: string;
  answer: string;
}

export interface AgentResult {
  answer: string;
  steps: AgentStep[];
  books: BookRef[];
  ms: number;
}

export interface AgentOptions extends ToolContext {
  question: string;
  /** Earlier turns of this conversation (question and final answer only). */
  history?: AgentTurn[];
  maxSteps?: number;
  onEvent?: (event: AgentEvent) => void;
}

const ACTIONS = [...TOOLS.map((t) => t.name), 'answer'] as const;

export const STEP_SCHEMA = {
  type: 'object',
  properties: {
    thought: { type: 'string', description: 'One short sentence: what is needed next.' },
    tool: { type: 'string', enum: ACTIONS },
    input: { type: 'string', description: 'The input for the tool. Empty for "answer".' },
  },
  required: ['thought', 'tool', 'input'],
  additionalProperties: false,
};

export function plannerPrompt(): string {
  return `You are a librarian for one person's book wishlist, stored as a graph (books, authors, subjects, genres, places, people, eras, series, awards, publishers, editions with prices).

You cannot see the list directly. Use tools to look things up, one per step:
${TOOLS.map((t) => `- ${t.name}: ${t.description}`).join('\n')}
- answer: You have what you need (or the tools cannot help). Input: empty.

Reply with one JSON object: {"thought": "...", "tool": "...", "input": "..."}

How to choose:
- Any request for something to read ("recommend", "suggest", "I want something ...", "books like/about ..."), and any mood or topic: search_books, with the qualities asked for as the phrase.
- Counts, rankings, lists and facts about authors, awards, places, prices or years: query_graph. Ask it one thing per call; split a two-part question into two calls.
- A question about one named book: book_details. "Similar to <book>": similar_books.
- Use the results of earlier steps; do not repeat a call with the same input.
- Only a greeting or thanks needs no tool: answer immediately.
- Choose answer as soon as the observations contain what the user asked for.`;
}

export function answerPrompt(): string {
  return `You are a librarian for one person's book wishlist. Answer the user's question using only the observations from the tools below.

- Be concise and specific: name the books, authors and numbers found.
- When the observations list several items that answer the question, give all of them (up to ten), not just the first.
- State an author, price, year, rating, page count or award only if it appears in the observations. Never invent one.
- A search result lists books related to the search phrase. It is not evidence that they won an award, share an author, or have any other property.
- If an observation says a lookup failed, or the observations do not contain the answer, say what could not be found instead of guessing.
- Do not mention tools, JSON or Cypher. Plain text or a short list.`;
}

function historyMessages(history: AgentTurn[]): ChatMessage[] {
  // The last three turns, answers clipped: enough for follow-ups in a small context.
  return history.slice(-3).flatMap((turn): ChatMessage[] => [
    { role: 'user', content: turn.question },
    { role: 'assistant', content: turn.answer.length > 500 ? `${turn.answer.slice(0, 500)}…` : turn.answer },
  ]);
}

export function parseStep(raw: string): { thought: string; tool: (typeof ACTIONS)[number]; input: string } | null {
  const text = stripThinking(raw);
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end <= start) return null;
  try {
    const value = JSON.parse(text.slice(start, end + 1)) as { thought?: unknown; tool?: unknown; input?: unknown };
    if (typeof value.tool !== 'string' || !(ACTIONS as readonly string[]).includes(value.tool)) return null;
    return {
      thought: typeof value.thought === 'string' ? value.thought : '',
      tool: value.tool as (typeof ACTIONS)[number],
      input: typeof value.input === 'string' ? value.input : value.input == null ? '' : JSON.stringify(value.input),
    };
  } catch {
    return null;
  }
}

export async function runAgent(options: AgentOptions): Promise<AgentResult> {
  const started = performance.now();
  const { llm, question, onEvent, signal } = options;
  const maxSteps = options.maxSteps ?? 4;
  const history = historyMessages(options.history ?? []);
  const steps: AgentStep[] = [];
  const seen = new Set<string>();

  const planning: ChatMessage[] = [{ role: 'system', content: plannerPrompt() }, ...history, { role: 'user', content: question }];

  for (let step = 0; step < maxSteps; step++) {
    signal?.throwIfAborted();
    onEvent?.({ type: 'thinking', step });
    const raw = await llm.complete(planning, { temperature: 0, maxTokens: 200, jsonSchema: STEP_SCHEMA, signal });
    const parsed = parseStep(raw);
    if (!parsed || parsed.tool === 'answer') break;

    const tool = TOOLS.find((t) => t.name === parsed.tool)!;
    // A small model's paraphrase of the question is where most graph lookups
    // went wrong in testing. When nothing has been looked up yet and there is
    // no earlier turn to carry context from, the user's own words are the
    // better input for the text-to-Cypher pipeline.
    const verbatim = tool.name === 'query_graph' && steps.length === 0 && history.length === 0;
    const input = verbatim ? question : parsed.input.trim() || question;
    const signature = `${tool.name}:${input.toLowerCase()}`;
    planning.push({ role: 'assistant', content: JSON.stringify({ thought: parsed.thought, tool: tool.name, input }) });
    if (seen.has(signature)) {
      // A repeated call adds nothing; tell the model and let it move on.
      planning.push({ role: 'user', content: 'Observation: you already made that call. Use its result, or choose "answer".' });
      continue;
    }
    seen.add(signature);

    onEvent?.({ type: 'tool-start', step, thought: parsed.thought, tool: tool.name, input });
    const toolStarted = performance.now();
    let result: ToolResult;
    try {
      result = await tool.run(input, { ...options, userQuestion: question });
    } catch (err) {
      if ((err as Error).name === 'AbortError') throw err;
      result = { observation: `The tool failed: ${(err as Error).message}`, books: [], failed: true };
    }
    const record: AgentStep = { thought: parsed.thought, tool: tool.name, input, result, ms: performance.now() - toolStarted };
    steps.push(record);
    onEvent?.({ type: 'tool-end', step, record });
    planning.push({ role: 'user', content: `Observation:\n${result.observation}\n\nNext step? (Choose "answer" if this is enough.)` });
  }

  signal?.throwIfAborted();
  onEvent?.({ type: 'answer-start' });
  const observations = steps.length
    ? steps.map((s, i) => `[${i + 1}] ${s.tool}("${s.input}")\n${s.result.observation}`).join('\n\n')
    : '(no tools were used)';
  const answering: ChatMessage[] = [
    { role: 'system', content: answerPrompt() },
    ...history,
    { role: 'user', content: `Question: ${question}\n\nObservations:\n${observations}` },
  ];
  const raw = await llm.complete(answering, { temperature: 0.3, maxTokens: 500, signal, onToken: (delta) => onEvent?.({ type: 'answer-token', delta }) });

  const books = new Map<string, BookRef>();
  for (const s of steps) for (const b of s.result.books) if (!books.has(b.key)) books.set(b.key, b);
  return { answer: stripThinking(raw), steps, books: [...books.values()], ms: performance.now() - started };
}
