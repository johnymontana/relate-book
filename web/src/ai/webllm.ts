// The in-browser language model: WebLLM (MLC) on WebGPU, in a worker.

import type { ChatCompletionMessageParam, InitProgressReport, WebWorkerMLCEngine } from '@mlc-ai/web-llm';
import type { ChatMessage, Llm, LlmOptions } from './llm';
import { modelChoice } from './models';

export interface LoadProgress {
  /** 0 to 1. */
  progress: number;
  text: string;
}

/** Roomier than WebLLM's 4,096-token default: the schema, five examples and a tool observation need it. */
const CONTEXT_WINDOW = 8192;

export function webGpuAvailable(): boolean {
  return typeof navigator !== 'undefined' && 'gpu' in navigator;
}

export async function isModelCached(modelId: string): Promise<boolean> {
  const { hasModelInCache } = await import('@mlc-ai/web-llm');
  try {
    return await hasModelInCache(modelId);
  } catch {
    return false;
  }
}

export async function deleteCachedModel(modelId: string): Promise<void> {
  const { deleteModelAllInfoInCache } = await import('@mlc-ai/web-llm');
  await deleteModelAllInfoInCache(modelId);
}

export class WebLlm implements Llm {
  readonly modelId: string;
  private engine: WebWorkerMLCEngine;
  private worker: Worker;
  private thinking: boolean;
  /** Generations run one at a time; a second caller waits. */
  private tail: Promise<unknown> = Promise.resolve();

  private constructor(modelId: string, engine: WebWorkerMLCEngine, worker: Worker) {
    this.modelId = modelId;
    this.engine = engine;
    this.worker = worker;
    this.thinking = modelChoice(modelId)?.thinking ?? false;
  }

  static async load(modelId: string, onProgress?: (p: LoadProgress) => void): Promise<WebLlm> {
    if (!webGpuAvailable()) throw new Error('This browser has no WebGPU, which the in-browser language model needs. Try a current Chrome, Edge or Safari.');
    const { CreateWebWorkerMLCEngine } = await import('@mlc-ai/web-llm');
    const worker = new Worker(new URL('./llm.worker.ts', import.meta.url), { type: 'module', name: 'relate-books-llm' });
    try {
      const engine = await CreateWebWorkerMLCEngine(
        worker,
        modelId,
        { initProgressCallback: (report: InitProgressReport) => onProgress?.({ progress: report.progress, text: report.text }) },
        { context_window_size: CONTEXT_WINDOW },
      );
      return new WebLlm(modelId, engine, worker);
    } catch (err) {
      worker.terminate();
      throw err;
    }
  }

  complete(messages: ChatMessage[], options: LlmOptions = {}): Promise<string> {
    const run = this.tail.then(() => this.generate(messages, options));
    this.tail = run.catch(() => undefined);
    return run;
  }

  private async generate(messages: ChatMessage[], options: LlmOptions): Promise<string> {
    options.signal?.throwIfAborted();
    const onAbort = () => void this.engine.interruptGenerate();
    options.signal?.addEventListener('abort', onAbort, { once: true });
    try {
      const stream = await this.engine.chat.completions.create({
        messages: messages as ChatCompletionMessageParam[],
        temperature: options.temperature ?? 0,
        // Models ship with a repetition penalty (Qwen2.5: 1.05). It is poison
        // for code: with it on, "2000" came out as "200" and "[:WON]" as "[:WON)".
        repetition_penalty: 1.0,
        frequency_penalty: 0,
        presence_penalty: 0,
        max_tokens: options.maxTokens ?? 512,
        stream: true,
        ...(options.jsonSchema ? { response_format: { type: 'json_object' as const, schema: JSON.stringify(options.jsonSchema) } } : {}),
        ...(this.thinking ? { extra_body: { enable_thinking: false } } : {}),
      });
      let text = '';
      for await (const chunk of stream) {
        const delta = chunk.choices[0]?.delta?.content ?? '';
        if (!delta) continue;
        text += delta;
        options.onToken?.(delta);
      }
      options.signal?.throwIfAborted();
      return text;
    } finally {
      options.signal?.removeEventListener('abort', onAbort);
    }
  }

  async unload(): Promise<void> {
    try {
      await this.engine.unload();
    } finally {
      this.worker.terminate();
    }
  }
}
