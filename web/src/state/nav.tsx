// Which tab is showing, and the hand-offs between tabs (open this book, draw
// this statement, run this Cypher). The tab is mirrored in the URL hash.

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { BookFilter } from '../queries/library';
import type { Statement } from '../queries/statement';

export type Tab = 'overview' | 'library' | 'graph' | 'query' | 'chat';

export const TABS: Array<{ id: Tab; label: string }> = [
  { id: 'overview', label: 'Overview' },
  { id: 'library', label: 'Library' },
  { id: 'graph', label: 'Graph' },
  { id: 'query', label: 'Query' },
  { id: 'chat', label: 'Chat' },
];

export interface GraphRequest {
  title: string;
  statement: Statement;
  /** Changes on every request so the same statement can be asked for twice. */
  nonce: number;
}

interface NavValue {
  tab: Tab;
  setTab(tab: Tab): void;
  bookKey: string | null;
  filter: BookFilter;
  openBook(key: string | null): void;
  openLibrary(filter: BookFilter): void;
  graphRequest: GraphRequest | null;
  showGraph(title: string, statement: Statement): void;
  queryRequest: { cypher: string; nonce: number } | null;
  openQuery(cypher: string): void;
  modelsOpen: boolean;
  setModelsOpen(open: boolean): void;
}

const NavContext = createContext<NavValue | null>(null);

function tabFromHash(): Tab {
  const id = window.location.hash.replace(/^#\/?/, '').split(/[/?]/)[0];
  return TABS.some((t) => t.id === id) ? (id as Tab) : 'overview';
}

export function NavProvider({ children }: { children: ReactNode }) {
  const [tab, setTabState] = useState<Tab>(tabFromHash);
  const [bookKey, setBookKey] = useState<string | null>(null);
  const [filter, setFilter] = useState<BookFilter>({ kind: 'all' });
  const [graphRequest, setGraphRequest] = useState<GraphRequest | null>(null);
  const [queryRequest, setQueryRequest] = useState<{ cypher: string; nonce: number } | null>(null);
  const [modelsOpen, setModelsOpen] = useState(false);

  useEffect(() => {
    const onHash = () => setTabState(tabFromHash());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const setTab = useCallback((next: Tab) => {
    setTabState(next);
    if (tabFromHash() !== next) window.history.replaceState(null, '', `#${next}`);
  }, []);

  const value = useMemo<NavValue>(
    () => ({
      tab,
      setTab,
      bookKey,
      filter,
      openBook: (key) => {
        setBookKey(key);
        if (key) setTab('library');
      },
      openLibrary: (next) => {
        setFilter(next);
        setBookKey(null);
        setTab('library');
      },
      graphRequest,
      showGraph: (title, statement) => {
        setGraphRequest({ title, statement, nonce: Date.now() });
        setTab('graph');
      },
      queryRequest,
      openQuery: (cypher) => {
        setQueryRequest({ cypher, nonce: Date.now() });
        setTab('query');
      },
      modelsOpen,
      setModelsOpen,
    }),
    [tab, setTab, bookKey, filter, graphRequest, queryRequest, modelsOpen],
  );
  return <NavContext.Provider value={value}>{children}</NavContext.Provider>;
}

export function useNav(): NavValue {
  const value = useContext(NavContext);
  if (!value) throw new Error('useNav outside NavProvider');
  return value;
}
