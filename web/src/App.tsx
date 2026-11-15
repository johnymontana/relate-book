import { useEffect, useRef, useState } from 'react';
import { BookMark } from './components/Icons';
import { Chat } from './features/chat/Chat';
import { GraphExplorer } from './features/graph/GraphExplorer';
import { Library } from './features/library/Library';
import { ModelsDrawer } from './features/models/ModelsDrawer';
import { Overview } from './features/overview/Overview';
import { QueryConsole } from './features/query/QueryConsole';
import { bytes, integer, ms } from './lib/format';
import { AiProvider, useAi } from './state/ai';
import { EngineProvider, LOCAL_EXPORT_URL, SAMPLE_URL, useEngine } from './state/engine';
import { NavProvider, TABS, useNav, type Tab } from './state/nav';

const PHASE: Record<string, string> = { schema: 'Creating constraints', nodes: 'Creating nodes', relationships: 'Creating relationships', indexes: 'Building indexes' };

function LoadScreen() {
  const { status } = useEngine();
  const p = status.progress;
  const fraction = p && p.total ? p.done / p.total : 0;
  return (
    <div className="center-screen" data-testid="load-screen">
      <div className="card card-pad load-card stack" style={{ gap: 12 }}>
        <div className="brand">
          <span className="brand-mark">
            <BookMark />
          </span>
          Relate Books
        </div>
        {status.state === 'error' ? (
          <>
            <div className="banner error">{status.error}</div>
            <button className="btn" onClick={() => window.location.reload()} style={{ alignSelf: 'flex-start' }}>
              Reload
            </button>
          </>
        ) : (
          <>
            <p className="sub">{status.state === 'starting' ? 'Starting the Relate engine (WebAssembly)…' : p ? `${PHASE[p.phase]}: ${integer(p.done)} of ${integer(p.total)}` : 'Fetching the dataset…'}</p>
            <div className="progress">
              <div style={{ width: `${Math.round(fraction * 100)}%` }} />
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function DatasetMenu() {
  const { status, localExport, loadDataset } = useEngine();
  const [open, setOpen] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const anchor = useRef<HTMLDivElement>(null);
  const dataset = status.dataset;

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!anchor.current?.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener('mousedown', onDown);
    return () => window.removeEventListener('mousedown', onDown);
  }, [open]);

  const pick = (action: () => void) => {
    setOpen(false);
    action();
  };

  return (
    <div className="popover-anchor" ref={anchor}>
      <button className="chip" onClick={() => setOpen((o) => !o)} aria-expanded={open} data-testid="dataset-chip" title="Dataset and storage">
        <span className={`dot ${status.state === 'ready' ? 'good' : 'busy'}`} />
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{dataset?.name ?? 'Loading'}</span>
        <span className="muted">· {status.storage === 'opfs' ? 'OPFS' : 'memory'}</span>
      </button>
      {open && (
        <div className="popover" data-testid="dataset-menu">
          {dataset && (
            <div className="stack small" style={{ gap: 4, marginBottom: 10 }}>
              <strong style={{ fontSize: 14 }}>{dataset.name}</strong>
              <span className="sub">
                {integer(dataset.nodes)} nodes · {integer(dataset.relationships)} relationships · loaded in {ms(dataset.loadMs)}
              </span>
              <span className="sub">
                {status.storage === 'opfs'
                  ? 'Stored in this browser (Origin Private File System): a reload reopens it without importing again.'
                  : `Held in memory${status.fallbackReason ? ` (${/locked/i.test(status.fallbackReason) ? 'another tab has the stored copy open' : 'this browser has no usable OPFS'})` : ''}: it is imported again on each visit.`}
              </span>
              <span className="muted">Engine memory: {bytes(status.wasmBytes)}</span>
            </div>
          )}
          {status.error && status.state === 'ready' && <div className="banner error small" style={{ marginBottom: 8 }}>{status.error}</div>}
          <button className="menu-item" onClick={() => pick(() => void loadDataset({ kind: 'url', url: SAMPLE_URL }, 'sample'))} data-testid="load-sample">
            <strong>Sample list</strong>
            <div className="sub small">Six books from a public wishlist.</div>
          </button>
          {localExport && (
            <button className="menu-item" onClick={() => pick(() => void loadDataset({ kind: 'url', url: LOCAL_EXPORT_URL }, 'local'))} data-testid="load-local">
              <strong>Your export</strong>
              <div className="sub small">web/local/books.json, served by the dev server only.</div>
            </button>
          )}
          <button className="menu-item" onClick={() => pick(() => file.current?.click())} data-testid="load-file">
            <strong>Open an export…</strong>
            <div className="sub small">
              A file made with <span className="mono">npm run export-store -- books.rl</span>. It stays in this browser.
            </div>
          </button>
          <input
            ref={file}
            type="file"
            accept=".json,application/json"
            hidden
            data-testid="dataset-file"
            onChange={(e) => {
              const picked = e.target.files?.[0];
              e.target.value = '';
              setOpen(false);
              if (picked) void loadDataset({ kind: 'blob', blob: picked }, 'file');
            }}
          />
        </div>
      )}
    </div>
  );
}

function AiChip() {
  const { embedderState, llmState, index } = useAi();
  const { setModelsOpen } = useNav();
  const busy = embedderState.phase === 'loading' || llmState.phase === 'loading' || index.phase === 'indexing';
  const on = embedderState.phase === 'ready' || llmState.phase === 'ready';
  const failed = embedderState.phase === 'error' || llmState.phase === 'error';
  let text = 'Models off';
  if (llmState.phase === 'loading') text = `Loading model ${Math.round(llmState.fraction * 100)}%`;
  else if (embedderState.phase === 'loading') text = 'Loading embeddings';
  else if (index.phase === 'indexing') text = `Embedding ${index.progress.scanned}/${index.progress.total}`;
  else if (llmState.phase === 'ready') text = llmState.modelId.replace(/-Instruct|-q4f.*|-MLC/g, '');
  else if (embedderState.phase === 'ready') text = 'Embeddings on';
  else if (failed) text = 'Model error';
  return (
    <button className="chip" onClick={() => setModelsOpen(true)} data-testid="ai-chip" title="In-browser models">
      <span className={`dot ${failed ? 'bad' : busy ? 'busy' : on ? 'good' : ''}`} />
      {text}
    </button>
  );
}

function Shell() {
  const { status } = useEngine();
  const { tab, setTab } = useNav();
  // Tabs that have been opened stay mounted (hidden), so the graph on the
  // canvas, the query and the conversation survive a visit to another tab.
  const [visited, setVisited] = useState<Set<Tab>>(() => new Set([tab]));
  useEffect(() => {
    setVisited((seen) => (seen.has(tab) ? seen : new Set(seen).add(tab)));
  }, [tab]);
  const keep = (id: Tab) => tab === id || visited.has(id);
  // The first load shows the load screen; a later dataset switch keeps the shell.
  const booted = useRef(false);
  if (status.state === 'ready') booted.current = true;
  if (!booted.current) return <LoadScreen />;

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">
            <BookMark />
          </span>
          <span className="brand-name">Relate Books</span>
        </div>
        <nav className="tabs" role="tablist" aria-label="Sections">
          {TABS.map((t) => (
            <button key={t.id} role="tab" className="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)} data-testid={`tab-${t.id}`}>
              {t.label}
            </button>
          ))}
        </nav>
        <div className="topbar-right">
          <AiChip />
          <DatasetMenu />
        </div>
      </header>
      <main className="main" style={{ opacity: status.state === 'ready' ? 1 : 0.5 }} aria-busy={status.state !== 'ready'}>
        {status.state === 'error' && <div className="banner error" style={{ margin: 16 }}>{status.error}</div>}
        {tab === 'overview' && <Overview />}
        {tab === 'library' && <Library />}
        <div style={{ display: tab === 'graph' ? 'contents' : 'none' }}>{keep('graph') && <GraphExplorer />}</div>
        <div style={{ display: tab === 'query' ? 'contents' : 'none' }}>{keep('query') && <QueryConsole />}</div>
        <div style={{ display: tab === 'chat' ? 'contents' : 'none' }}>{keep('chat') && <Chat />}</div>
      </main>
      <ModelsDrawer />
    </div>
  );
}

export function App() {
  const memoryOnly = new URLSearchParams(window.location.search).has('memory');
  return (
    <EngineProvider memoryOnly={memoryOnly}>
      <NavProvider>
        <AiProvider>
          <Shell />
        </AiProvider>
      </NavProvider>
    </EngineProvider>
  );
}
