import { useEffect, useState } from 'react';
import { MODELS, modelChoice } from '../../ai/models';
import { CloseIcon } from '../../components/Icons';
import { EMBEDDING_MODEL_ID } from '../../engine/schema';
import { integer } from '../../lib/format';
import { useAi } from '../../state/ai';
import { useNav } from '../../state/nav';

export function ModelsDrawer() {
  const { modelsOpen, setModelsOpen } = useNav();
  const ai = useAi();
  const [cached, setCached] = useState<Record<string, boolean>>({});
  const [webgpu, setWebgpu] = useState(true);

  useEffect(() => {
    if (!modelsOpen || ai.stub) return;
    let cancelled = false;
    void import('../../ai/webllm').then(async ({ isModelCached, webGpuAvailable }) => {
      setWebgpu(webGpuAvailable());
      const entries = await Promise.all(MODELS.map(async (m) => [m.id, await isModelCached(m.id)] as const));
      if (!cancelled) setCached(Object.fromEntries(entries));
    });
    return () => {
      cancelled = true;
    };
  }, [modelsOpen, ai.stub, ai.llmState.phase]);

  useEffect(() => {
    if (!modelsOpen) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setModelsOpen(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [modelsOpen, setModelsOpen]);

  if (!modelsOpen) return null;
  const { embedderState, index, llmState } = ai;
  const loading = llmState.phase === 'loading';
  const loadedId = llmState.phase === 'ready' ? llmState.modelId : null;

  const forget = async (id: string) => {
    const { deleteCachedModel } = await import('../../ai/webllm');
    if (loadedId === id) await ai.unloadLlm();
    await deleteCachedModel(id);
    setCached((c) => ({ ...c, [id]: false }));
  };

  return (
    <>
      <div className="drawer-backdrop" onClick={() => setModelsOpen(false)} />
      <aside className="drawer" role="dialog" aria-label="Models" data-testid="models-drawer">
        <div className="row">
          <h2>Models</h2>
          <span className="spacer" />
          <button className="btn small ghost" onClick={() => setModelsOpen(false)} aria-label="Close">
            <CloseIcon />
          </button>
        </div>
        <p className="sub" style={{ marginTop: 6 }}>
          Both models run in this browser tab. They are downloaded once from Hugging Face and kept in the browser cache; your books and questions are never sent anywhere.
          {ai.stub && ' (stub-ai is on: scripted stand-ins are used, nothing is downloaded.)'}
        </p>

        <section>
          <h3>Embedding model</h3>
          <p className="sub small">
            <span className="mono">{EMBEDDING_MODEL_ID}</span>, 384 dimensions. Used for semantic book search, “more like this”, and to pick the examples shown to the language model. About 90 MB on WebGPU, 23 MB on WASM.
          </p>
          <div className="stack" style={{ marginTop: 8 }}>
            {embedderState.phase === 'off' && (
              <button className="btn primary" onClick={() => void ai.enableEmbeddings()} style={{ alignSelf: 'flex-start' }} data-testid="enable-embeddings">
                Download and enable
              </button>
            )}
            {embedderState.phase === 'loading' && (
              <>
                <div className="progress">
                  <div style={{ width: `${Math.round(embedderState.fraction * 100)}%` }} />
                </div>
                <span className="muted small">Loading {embedderState.file || 'the model'}…</span>
              </>
            )}
            {embedderState.phase === 'error' && <div className="banner error">{embedderState.message}</div>}
            {embedderState.phase === 'ready' && (
              <div className="row" data-testid="embedder-ready">
                <span className="dot good" /> Running on {embedderState.device}
              </div>
            )}
            {embedderState.phase === 'ready' && index.phase === 'indexing' && (
              <>
                <div className="progress">
                  <div style={{ width: `${index.progress.total ? Math.round((index.progress.scanned / index.progress.total) * 100) : 0}%` }} />
                </div>
                <span className="muted small">
                  Embedding books into the graph: {integer(index.progress.scanned)} of {integer(index.progress.total)}
                </span>
              </>
            )}
            {embedderState.phase === 'ready' && index.phase === 'pending' && <span className="muted small">Checking which books need embedding…</span>}
            {embedderState.phase === 'ready' && index.phase === 'idle' && (
              <span className="muted small" data-testid="index-done">
                {integer(index.total)} books embedded and stored as <span className="mono">Book.embedding</span> (vector index <span className="mono">book_embedding</span>).
              </span>
            )}
            {index.phase === 'error' && <div className="banner error">{index.message}</div>}
          </div>
        </section>

        <section>
          <h3>Language model</h3>
          <p className="sub small">Runs on your GPU through WebGPU (WebLLM). Writes the Cypher for the Query tab and drives the Chat agent. Larger models answer better and need more GPU memory.</p>
          {!webgpu && !ai.stub && <div className="banner error" style={{ marginTop: 8 }}>This browser has no WebGPU, so the language model cannot run here. Everything else works. Try a current Chrome, Edge or Safari.</div>}
          <div role="radiogroup" aria-label="Language model" style={{ marginTop: 8 }}>
            {MODELS.map((m) => (
              <label key={m.id} className="model-option">
                <input type="radio" name="model" checked={ai.selectedModel === m.id} onChange={() => ai.selectModel(m.id)} disabled={loading} />
                <span>
                  <strong>{m.name}</strong> <span className="muted small">about {m.vramGb} GB</span>
                  <br />
                  <span className="sub small">{m.note}</span>
                  <br />
                  <span className="muted small">{m.licence}</span>
                </span>
                <span className="stack" style={{ alignItems: 'flex-end', gap: 2 }}>
                  {loadedId === m.id && <span className="badge">loaded</span>}
                  {cached[m.id] && loadedId !== m.id && <span className="muted small">downloaded</span>}
                  {cached[m.id] && (
                    <button className="btn small ghost danger" onClick={(e) => { e.preventDefault(); void forget(m.id); }} disabled={loading}>
                      Delete
                    </button>
                  )}
                </span>
              </label>
            ))}
          </div>
          <div className="stack" style={{ marginTop: 10 }}>
            {loading && (
              <>
                <div className="progress">
                  <div style={{ width: `${Math.round(llmState.fraction * 100)}%` }} />
                </div>
                <span className="muted small">{llmState.text}</span>
              </>
            )}
            {llmState.phase === 'error' && <div className="banner error">{llmState.message}</div>}
            <div className="row">
              <button className="btn primary" onClick={() => void ai.loadLlm(ai.selectedModel)} disabled={loading || loadedId === ai.selectedModel || (!webgpu && !ai.stub)} data-testid="load-llm">
                {loading ? 'Loading…' : loadedId === ai.selectedModel ? 'Loaded' : cached[ai.selectedModel] ? `Load ${modelChoice(ai.selectedModel)?.name ?? ''}` : `Download and load ${modelChoice(ai.selectedModel)?.name ?? ''}`}
              </button>
              {loadedId && (
                <button className="btn" onClick={() => void ai.unloadLlm()} disabled={loading}>
                  Unload
                </button>
              )}
            </div>
          </div>
        </section>
      </aside>
    </>
  );
}
