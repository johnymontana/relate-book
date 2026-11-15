// The two in-browser models for the React tree: the embedding model (and the
// index of book vectors it writes into the graph) and the language model.
// Nothing is downloaded until the user asks for it; after that the choice is
// remembered and a cached model loads again on the next visit.

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Llm } from '../ai/llm';
import { DEFAULT_MODEL_ID } from '../ai/models';
import * as searchQueries from '../queries/search';
import type { Embedder } from '../search/embedder';
import { indexBooks, type IndexProgress } from '../search/indexer';
import { useEngine } from './engine';

export type EmbedderState =
  | { phase: 'off' }
  | { phase: 'loading'; file: string; fraction: number }
  | { phase: 'ready'; device: string }
  | { phase: 'error'; message: string };

export type IndexState =
  /** Before the first pass over the books: nothing is known yet. */
  | { phase: 'pending' }
  | { phase: 'idle'; embedded: number; total: number }
  | { phase: 'indexing'; progress: IndexProgress }
  | { phase: 'error'; message: string; embedded: number; total: number };

export type LlmState =
  | { phase: 'off' }
  | { phase: 'loading'; modelId: string; fraction: number; text: string }
  | { phase: 'ready'; modelId: string }
  | { phase: 'error'; modelId: string; message: string };

interface AiValue {
  /** `?stub-ai` in the dev server: deterministic stand-ins, no downloads, no GPU. */
  stub: boolean;
  embedder: Embedder | null;
  embedderState: EmbedderState;
  index: IndexState;
  enableEmbeddings(): Promise<void>;
  llm: Llm | null;
  llmState: LlmState;
  selectedModel: string;
  selectModel(id: string): void;
  loadLlm(modelId?: string): Promise<void>;
  unloadLlm(): Promise<void>;
}

const AiContext = createContext<AiValue | null>(null);

const EMBED_KEY = 'relate-books:embeddings';
const MODEL_KEY = 'relate-books:llm';
const AUTOLOAD_KEY = 'relate-books:llm-autoload';

const remember = (key: string, value: string | null) => {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    // Private mode: nothing is remembered.
  }
};
const recall = (key: string): string | null => {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
};

export function stubRequested(): boolean {
  return import.meta.env.DEV && new URLSearchParams(window.location.search).has('stub-ai');
}

export function AiProvider({ children }: { children: ReactNode }) {
  const { db, status, present } = useEngine();
  const stub = useMemo(stubRequested, []);
  const [embedder, setEmbedder] = useState<Embedder | null>(null);
  const [embedderState, setEmbedderState] = useState<EmbedderState>({ phase: 'off' });
  const [index, setIndex] = useState<IndexState>({ phase: 'pending' });
  const [llm, setLlm] = useState<Llm | null>(null);
  const [llmState, setLlmState] = useState<LlmState>({ phase: 'off' });
  const [selectedModel, setSelectedModel] = useState<string>(() => recall(MODEL_KEY) ?? DEFAULT_MODEL_ID);
  const loadingEmbedder = useRef(false);
  const loadingLlm = useRef(false);
  const llmRef = useRef<Llm | null>(null);
  const ready = status.state === 'ready';

  const enableEmbeddings = useCallback(async () => {
    if (loadingEmbedder.current || embedder) return;
    loadingEmbedder.current = true;
    setEmbedderState({ phase: 'loading', file: '', fraction: 0 });
    try {
      if (stub) {
        const { StubEmbedder } = await import('../search/stubEmbedder');
        setEmbedder(new StubEmbedder());
        setEmbedderState({ phase: 'ready', device: 'stub' });
      } else {
        const { WorkerEmbedder } = await import('../ai/embedderClient');
        const loaded = await WorkerEmbedder.load((p) => setEmbedderState({ phase: 'loading', file: p.file, fraction: p.total ? p.loaded / p.total : 0 }));
        setEmbedder(loaded);
        setEmbedderState({ phase: 'ready', device: loaded.device === 'webgpu' ? 'WebGPU' : 'WASM' });
      }
      remember(EMBED_KEY, '1');
    } catch (err) {
      setEmbedderState({ phase: 'error', message: err instanceof Error ? err.message : String(err) });
    } finally {
      loadingEmbedder.current = false;
    }
  }, [embedder, stub]);

  // Embed whatever is stale whenever a model and a graph are both there.
  useEffect(() => {
    if (!embedder || !ready) return;
    const controller = new AbortController();
    setIndex((current) => (current.phase === 'idle' ? { phase: 'pending' } : current));
    void (async () => {
      try {
        const coverage = await db.query<{ books: number; embedded: number }>(
          searchQueries.embeddingCoverage(embedder.modelId).cypher,
          searchQueries.embeddingCoverage(embedder.modelId).params,
        );
        const { books, embedded } = coverage.rows[0] ?? { books: 0, embedded: 0 };
        setIndex({ phase: 'indexing', progress: { scanned: 0, total: books, embedded: 0 } });
        const summary = await indexBooks(db, embedder, {
          signal: controller.signal,
          onProgress: (progress) => setIndex({ phase: 'indexing', progress }),
        });
        setIndex({ phase: 'idle', embedded: Math.max(embedded, summary.total), total: summary.total });
      } catch (err) {
        if (controller.signal.aborted) return;
        setIndex({ phase: 'error', message: err instanceof Error ? err.message : String(err), embedded: 0, total: 0 });
      }
    })();
    return () => controller.abort();
  }, [db, embedder, ready, status.generation]);

  const unloadLlm = useCallback(async () => {
    const current = llmRef.current as (Llm & { unload?: () => Promise<void> }) | null;
    llmRef.current = null;
    setLlm(null);
    setLlmState({ phase: 'off' });
    remember(AUTOLOAD_KEY, null);
    await current?.unload?.().catch(() => undefined);
  }, []);

  const loadLlm = useCallback(
    async (modelId: string = selectedModel) => {
      if (loadingLlm.current) return;
      loadingLlm.current = true;
      setSelectedModel(modelId);
      remember(MODEL_KEY, modelId);
      setLlmState({ phase: 'loading', modelId, fraction: 0, text: 'Starting…' });
      try {
        const previous = llmRef.current as (Llm & { unload?: () => Promise<void> }) | null;
        llmRef.current = null;
        setLlm(null);
        await previous?.unload?.().catch(() => undefined);
        let loaded: Llm;
        if (stub) {
          const { StubLlm } = await import('../ai/stubLlm');
          loaded = new StubLlm();
        } else {
          const { WebLlm } = await import('../ai/webllm');
          loaded = await WebLlm.load(modelId, (p) => setLlmState({ phase: 'loading', modelId, fraction: p.progress, text: p.text }));
        }
        llmRef.current = loaded;
        setLlm(loaded);
        setLlmState({ phase: 'ready', modelId: loaded.modelId });
        remember(AUTOLOAD_KEY, modelId);
      } catch (err) {
        setLlmState({ phase: 'error', modelId, message: err instanceof Error ? err.message : String(err) });
      } finally {
        loadingLlm.current = false;
      }
    },
    [selectedModel, stub],
  );

  // On a return visit: models the user turned on before, and that are already
  // downloaded, come back without another click.
  const resumed = useRef(false);
  useEffect(() => {
    if (resumed.current || !ready) return;
    resumed.current = true;
    if (stub) return;
    if (recall(EMBED_KEY)) void enableEmbeddings();
    const auto = recall(AUTOLOAD_KEY);
    if (auto) {
      void import('../ai/webllm').then(async ({ isModelCached, webGpuAvailable }) => {
        if (webGpuAvailable() && (await isModelCached(auto))) void loadLlm(auto);
      });
    }
  }, [ready, stub, enableEmbeddings, loadLlm]);

  // Dev server only: a console handle for trying the pipelines by hand and for
  // the model evaluation notes in the README (`await __relateBooks.ask('…')`).
  useEffect(() => {
    if (!import.meta.env.DEV) return;
    const handle = {
      db,
      llm,
      embedder,
      ask: async (question: string) => {
        if (!llm) throw new Error('load a language model first');
        const { textToCypher } = await import('../ai/text2cypher/pipeline');
        const out = await textToCypher({ db, llm, embedder, question, present });
        return { cypher: out.cypher, error: out.error, attempts: out.attempts, rows: out.result?.rows.slice(0, 8) ?? null, rowCount: out.result?.rows.length ?? 0, ms: Math.round(out.ms), names: out.names.map((n) => `${n.label}:${n.name}`), examples: out.examples.map((e) => e.question) };
      },
      chat: async (question: string) => {
        if (!llm) throw new Error('load a language model first');
        const { runAgent } = await import('../ai/agent/loop');
        const out = await runAgent({ db, llm, embedder, question, present });
        return { answer: out.answer, ms: Math.round(out.ms), steps: out.steps.map((s) => ({ tool: s.tool, input: s.input, thought: s.thought, failed: s.result.failed ?? false, cypher: s.result.cypher ?? null, observation: s.result.observation.slice(0, 500) })) };
      },
    };
    (window as unknown as { __relateBooks?: typeof handle }).__relateBooks = handle;
  }, [db, llm, embedder, present]);

  const selectModel = useCallback((id: string) => {
    setSelectedModel(id);
    remember(MODEL_KEY, id);
  }, []);

  const value = useMemo<AiValue>(
    () => ({ stub, embedder, embedderState, index, enableEmbeddings, llm, llmState, selectedModel, selectModel, loadLlm, unloadLlm }),
    [stub, embedder, embedderState, index, enableEmbeddings, llm, llmState, selectedModel, selectModel, loadLlm, unloadLlm],
  );
  return <AiContext.Provider value={value}>{children}</AiContext.Provider>;
}

export function useAi(): AiValue {
  const value = useContext(AiContext);
  if (!value) throw new Error('useAi outside AiProvider');
  return value;
}
