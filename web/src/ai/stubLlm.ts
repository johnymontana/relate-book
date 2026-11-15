// A scripted stand-in for the language model, for tests and `?stub-ai` in the
// dev server. It is deterministic and knows nothing: for a Cypher request it
// replays the nearest few-shot example from the prompt, for an agent step it
// searches once and then answers, and for an answer it repeats the
// observations. Enough to exercise every code path without a GPU.

import type { ChatMessage, Llm, LlmOptions } from './llm';

export type Scripted = string | ((messages: ChatMessage[], options?: LlmOptions) => string);

export class StubLlm implements Llm {
  readonly modelId = 'stub/scripted';
  /** Replies used first, in order; when empty the built-in behaviour answers. */
  script: Scripted[];
  calls: Array<{ messages: ChatMessage[]; options?: LlmOptions }> = [];

  constructor(script: Scripted[] = []) {
    this.script = [...script];
  }

  async complete(messages: ChatMessage[], options?: LlmOptions): Promise<string> {
    options?.signal?.throwIfAborted();
    this.calls.push({ messages: messages.map((m) => ({ ...m })), options });
    const next = this.script.shift();
    const reply = next === undefined ? this.builtin(messages, options) : typeof next === 'function' ? next(messages, options) : next;
    if (options?.onToken) {
      // Stream in a few pieces so the UI's streaming path runs.
      for (const piece of reply.match(/[\s\S]{1,24}/g) ?? []) {
        await Promise.resolve();
        options.onToken(piece);
      }
    }
    return reply;
  }

  private builtin(messages: ChatMessage[], options?: LlmOptions): string {
    const system = messages[0]?.content ?? '';
    const last = messages[messages.length - 1]?.content ?? '';
    if (options?.jsonSchema) {
      const observed = messages.some((m) => m.role === 'user' && m.content.startsWith('Observation:'));
      const question = [...messages].reverse().find((m) => m.role === 'user' && !m.content.startsWith('Observation:'))?.content ?? '';
      if (observed) return JSON.stringify({ thought: 'The observation has the answer.', tool: 'answer', input: '' });
      const factual = /\b(how many|which|who|count|most|average|total)\b/i.test(question);
      return JSON.stringify({ thought: factual ? 'This is a question for the graph.' : 'Search the list.', tool: factual ? 'query_graph' : 'search_books', input: question });
    }
    if (system.includes('into Cypher')) {
      // The nearest example is the last assistant message before the question.
      const example = [...messages].reverse().find((m) => m.role === 'assistant');
      return example?.content ?? 'MATCH (b:Book)\nRETURN count(b) AS books';
    }
    const observations = /Observations:\n([\s\S]*)$/.exec(last)?.[1]?.trim();
    return observations ? `From the wishlist graph: ${observations.split('\n').slice(1, 4).join('; ')}` : 'I have no information about that on this wishlist.';
  }
}
