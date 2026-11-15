// The language-model seam. The real implementation is WebLLM in a worker
// (webllm.ts); tests and `?stub-ai` use a scripted one (stubLlm.ts).

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface LlmOptions {
  temperature?: number;
  maxTokens?: number;
  /** Constrain the output to JSON matching this schema (grammar-constrained decoding). */
  jsonSchema?: Record<string, unknown>;
  /** Called with each piece of text as it is generated. */
  onToken?: (delta: string) => void;
  signal?: AbortSignal;
}

export interface Llm {
  readonly modelId: string;
  complete(messages: ChatMessage[], options?: LlmOptions): Promise<string>;
}

/** Drop a reasoning model's `<think>…</think>` block (closed or cut off). */
export function stripThinking(text: string): string {
  return text.replace(/<think>[\s\S]*?(<\/think>|$)/g, '').trim();
}
