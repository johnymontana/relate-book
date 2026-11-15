// The Relate engine for the React tree: one client for the page, its status,
// and a hook that runs a statement and reruns it when the graph changes.

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from 'react';
import { EngineClient, type DatasetMeta, type EngineStatus } from '../engine/client';
import type { DatasetSource } from '../engine/protocol';
import type { QueryResult, Row } from '../engine/wire';
import { presentLabels, presentTypes } from '../queries/overview';
import type { Statement } from '../queries/statement';

export const SAMPLE_URL = `${import.meta.env.BASE_URL}data/sample.json`;
/** Served by the dev server only, from the git-ignored `local/books.json` (npm run export-store). */
export const LOCAL_EXPORT_URL = '/local-data/books.json';

interface EngineContextValue {
  db: EngineClient;
  status: EngineStatus;
  /** True when the dev server has a personal export to offer. */
  localExport: boolean;
  /** Labels and relationship types present in the loaded graph. */
  present: { labels: Set<string>; types: Set<string> };
  loadDataset(source: DatasetSource, origin: DatasetMeta['origin']): Promise<void>;
}

const EngineContext = createContext<EngineContextValue | null>(null);

async function hasLocalExport(): Promise<boolean> {
  if (!import.meta.env.DEV) return false;
  try {
    const response = await fetch('/local-data/status');
    if (!response.ok) return false;
    return ((await response.json()) as { available?: boolean }).available === true;
  } catch {
    return false;
  }
}

export function EngineProvider({ children, memoryOnly = false }: { children: ReactNode; memoryOnly?: boolean }) {
  const clientRef = useRef<EngineClient | null>(null);
  clientRef.current ??= new EngineClient({ memoryOnly });
  const db = clientRef.current;
  const status = useSyncExternalStore(db.subscribe, db.getStatus);
  const [localExport, setLocalExport] = useState(false);
  const [present, setPresent] = useState<{ labels: Set<string>; types: Set<string> }>({ labels: new Set(), types: new Set() });

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      // `?dataset=sample` ignores a local export (the end-to-end tests name the sample's books).
      const forceSample = new URLSearchParams(window.location.search).get('dataset') === 'sample';
      const local = !forceSample && (await hasLocalExport());
      if (cancelled) return;
      setLocalExport(local);
      // Your own export, when the dev server has one; the public sample otherwise.
      const fallback = local ? { source: { kind: 'url' as const, url: LOCAL_EXPORT_URL }, origin: 'local' as const } : { source: { kind: 'url' as const, url: SAMPLE_URL }, origin: 'sample' as const };
      await db.start(fallback);
      const loaded = db.getStatus().dataset;
      // A graph that came back from OPFS was not loaded in this tab; remember
      // where it can be fetched again in case the engine has to restart in memory.
      if (loaded?.origin === 'sample') db.rememberSource({ kind: 'url', url: SAMPLE_URL }, 'sample');
      else if (loaded?.origin === 'local' && local) db.rememberSource({ kind: 'url', url: LOCAL_EXPORT_URL }, 'local');
    })();
    return () => {
      cancelled = true;
    };
  }, [db]);

  useEffect(() => {
    if (status.state !== 'ready') return;
    let cancelled = false;
    void Promise.all([db.query<{ label: string }>(presentLabels.cypher), db.query<{ relationshipType: string }>(presentTypes.cypher)])
      .then(([labels, types]) => {
        if (!cancelled) setPresent({ labels: new Set(labels.rows.map((r) => r.label)), types: new Set(types.rows.map((r) => r.relationshipType)) });
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [db, status.state, status.generation]);

  const loadDataset = useCallback(
    async (source: DatasetSource, origin: DatasetMeta['origin']) => {
      await db.load(source, origin).catch(() => undefined);
    },
    [db],
  );

  const value = useMemo(() => ({ db, status, localExport, present, loadDataset }), [db, status, localExport, present, loadDataset]);
  return <EngineContext.Provider value={value}>{children}</EngineContext.Provider>;
}

export function useEngine(): EngineContextValue {
  const value = useContext(EngineContext);
  if (!value) throw new Error('useEngine outside EngineProvider');
  return value;
}

export interface QueryState<T> {
  result: QueryResult<T> | null;
  error: string | null;
  loading: boolean;
}

/**
 * Run a statement and keep its result. Reruns when the statement changes or
 * the graph is replaced; while a rerun is in flight the previous result stays
 * (no flash of empty).
 */
export function useStatement<T = Row>(statement: Statement | null, extraKey: unknown = null): QueryState<T> {
  const { db, status } = useEngine();
  const [state, setState] = useState<QueryState<T>>({ result: null, error: null, loading: statement !== null });
  const key = statement ? `${statement.cypher}\u0000${JSON.stringify(statement.params ?? null)}` : null;
  const ready = status.state === 'ready';

  useEffect(() => {
    if (!statement || !ready) return;
    let cancelled = false;
    setState((s) => ({ ...s, loading: true, error: null }));
    db.query<T>(statement.cypher, statement.params)
      .then((result) => {
        if (!cancelled) setState({ result, error: null, loading: false });
      })
      .catch((err: Error) => {
        if (!cancelled) setState({ result: null, error: err.message, loading: false });
      });
    return () => {
      cancelled = true;
    };
    // `key` stands for the statement's content.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [db, key, ready, status.generation, extraKey]);

  return state;
}
