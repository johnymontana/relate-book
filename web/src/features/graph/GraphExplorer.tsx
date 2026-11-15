import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { CypherDisclosure } from '../../components/Cypher';
import { GraphCanvas, type GraphCanvasHandle } from '../../components/GraphCanvas';
import { SearchIcon } from '../../components/Icons';
import { extractGraph, type GraphData, type WireNode, type WireRelationship } from '../../engine/wire';
import { formatValue, integer, ms, plural } from '../../lib/format';
import { labelColor, LEGEND_ORDER, nodeCaption, primaryLabel } from '../../lib/labels';
import * as graphQueries from '../../queries/graph';
import * as searchQueries from '../../queries/search';
import type { Statement } from '../../queries/statement';
import { KeywordQuery } from '../../search/keywordQuery';
import { useEngine } from '../../state/engine';
import { useNav } from '../../state/nav';

const EXPAND_LIMIT = 40;
/** Canvas rendering stays readable and quick up to about this many nodes. */
const NODE_BUDGET = 600;

interface Loaded {
  title: string;
  statement: Statement;
  elapsedMs: number;
}

function merge(base: GraphData, extra: GraphData): GraphData {
  const nodes = new Map(base.nodes.map((n) => [n.id, n]));
  for (const n of extra.nodes) if (!nodes.has(n.id)) nodes.set(n.id, n);
  const relationships = new Map(base.relationships.map((r) => [r.id, r]));
  for (const r of extra.relationships) if (!relationships.has(r.id)) relationships.set(r.id, r);
  return { nodes: [...nodes.values()], relationships: [...relationships.values()] };
}

function Properties({ properties }: { properties: Record<string, unknown> }) {
  const entries = Object.entries(properties).filter(([k]) => k !== 'embedding' && k !== 'embedding_text_hash');
  if (entries.length === 0) return <p className="muted small">No properties.</p>;
  return (
    <dl className="props">
      {entries.map(([k, v]) => (
        <div key={k} style={{ display: 'contents' }}>
          <dt>{k}</dt>
          <dd>{formatValue(v, 400)}</dd>
        </div>
      ))}
    </dl>
  );
}

export function GraphExplorer() {
  const { db, status } = useEngine();
  const { graphRequest, openBook } = useNav();
  const canvas = useRef<GraphCanvasHandle>(null);
  const [graph, setGraph] = useState<GraphData>({ nodes: [], relationships: [] });
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [selected, setSelected] = useState<WireNode | null>(null);
  const [selectedRel, setSelectedRel] = useState<WireRelationship | null>(null);
  const [degree, setDegree] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showTypes, setShowTypes] = useState(true);
  const [find, setFind] = useState('');
  const [matches, setMatches] = useState<Array<{ label: string; name: string }>>([]);
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;

  const load = useCallback(
    async (title: string, statement: Statement) => {
      setBusy(true);
      setError(null);
      setNotice(null);
      try {
        const result = await db.query(statement.cypher, statement.params);
        const next = extractGraph(result.rows);
        setGraph(next);
        setLoaded({ title, statement, elapsedMs: result.elapsedMs });
        setSelected(null);
        setSelectedRel(null);
        if (next.nodes.length === 0) setNotice('That query returned no nodes. Return nodes, relationships or paths to draw a graph.');
      } catch (err) {
        setError((err as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [db],
  );

  // A hand-off from another tab, or the first preset.
  const handled = useRef<number | null>(null);
  useEffect(() => {
    if (status.state !== 'ready') return;
    if (graphRequest && handled.current !== graphRequest.nonce) {
      handled.current = graphRequest.nonce;
      void load(graphRequest.title, graphRequest.statement);
    } else if (!loaded && !graphRequest) {
      const first = graphQueries.presets[0];
      void load(first.title, first.statement);
    }
  }, [graphRequest, load, loaded, status.state]);

  // A new dataset invalidates what is on the canvas.
  const generation = useRef(status.generation);
  useEffect(() => {
    if (generation.current === status.generation) return;
    generation.current = status.generation;
    const first = graphQueries.presets[0];
    void load(first.title, first.statement);
  }, [status.generation, load]);

  const expand = useCallback(
    async (node: WireNode) => {
      if (graph.nodes.length >= NODE_BUDGET) {
        setNotice(`The canvas holds ${graph.nodes.length} nodes. Remove some, or start a new view, before expanding further.`);
        return;
      }
      setBusy(true);
      setNotice(null);
      try {
        const statement = graphQueries.expand(node.id, EXPAND_LIMIT);
        const [around, total] = await Promise.all([db.query(statement.cypher, statement.params), db.query<{ degree: number }>(graphQueries.degree(node.id).cypher, graphQueries.degree(node.id).params)]);
        const next = merge(graph, extractGraph(around.rows));
        // Relationships among nodes that are now both on the canvas.
        const among = graphQueries.relationshipsAmong(next.nodes.map((n) => n.id));
        const links = await db.query(among.cypher, among.params);
        setGraph(merge(next, { nodes: [], relationships: extractGraph(links.rows).relationships }));
        const all = total.rows[0]?.degree ?? 0;
        if (all > EXPAND_LIMIT) setNotice(`${nodeCaption(node)} has ${integer(all)} relationships; ${EXPAND_LIMIT} are shown.`);
      } catch (err) {
        setError((err as Error).message);
      } finally {
        setBusy(false);
      }
    },
    [db, graph],
  );

  const remove = useCallback(
    (node: WireNode) => {
      setGraph((g) => ({ nodes: g.nodes.filter((n) => n.id !== node.id), relationships: g.relationships.filter((r) => r.start_node !== node.id && r.end_node !== node.id) }));
      setSelected(null);
    },
    [],
  );

  useEffect(() => {
    setDegree(null);
    if (!selected) return;
    let cancelled = false;
    const statement = graphQueries.degree(selected.id);
    void db
      .query<{ degree: number }>(statement.cypher, statement.params)
      .then((r) => !cancelled && setDegree(r.rows[0]?.degree ?? 0))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [db, selected]);

  // "Find a node": names from the fulltext index over every term, plus book titles.
  useEffect(() => {
    const query = KeywordQuery.parse(find);
    if (!query) {
      setMatches([]);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      const terms = searchQueries.terms(query.text, 8);
      const books = searchQueries.bookText(query.text, 6);
      void Promise.all([db.query<{ label: string; name: string }>(terms.cypher, terms.params), db.query<{ key: string; title: string }>(books.cypher, books.params)])
        .then(([t, b]) => {
          if (cancelled) return;
          const titled = b.rows.filter((r) => query.isCoveredBy([r.title])).map((r) => ({ label: 'Book', name: r.title }));
          setMatches([...titled, ...t.rows.filter((r) => typeof r.name === 'string')].slice(0, 10));
        })
        .catch(() => undefined);
    }, 150);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [db, find]);

  const openMatch = (match: { label: string; name: string }) => {
    setFind('');
    setMatches([]);
    if (match.label === 'Book') {
      void load(match.name, graphQueries.bookNeighborhoodByTitle(match.name));
    } else {
      void load(`${match.label}: ${match.name}`, graphQueries.termNeighborhood(match.label, match.name));
    }
  };

  const legend = useMemo(() => {
    const counts = new Map<string, number>();
    for (const n of graph.nodes) counts.set(primaryLabel(n.labels), (counts.get(primaryLabel(n.labels)) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => LEGEND_ORDER.indexOf(a[0]) - LEGEND_ORDER.indexOf(b[0]));
  }, [graph.nodes]);

  const bookKey = selected?.labels.includes('Book') ? (selected.properties.key as string | undefined) : undefined;

  return (
    <div className="page-wide" data-testid="graph">
      <div className="graph-layout">
        <aside className="graph-side" aria-label="Views">
          <div className="side-title">Find a node</div>
          <div className="search-box" style={{ marginBottom: 6 }}>
            <SearchIcon />
            <input className="input" type="search" placeholder="Author, subject, place, title…" value={find} onChange={(e) => setFind(e.target.value)} aria-label="Find a node" data-testid="graph-find" />
          </div>
          {matches.map((m) => (
            <button key={`${m.label}:${m.name}`} className="sample-q" onClick={() => openMatch(m)}>
              <span className="label-pill" style={{ marginRight: 6 }}>
                <span className="swatch" style={{ background: labelColor(m.label, dark) }} />
                {m.label}
              </span>
              {m.name}
            </button>
          ))}
          <div className="side-title">Views</div>
          {graphQueries.presets.map((preset) => (
            <button key={preset.id} className="preset" aria-current={loaded?.title === preset.title} onClick={() => void load(preset.title, preset.statement)} data-testid={`preset-${preset.id}`}>
              <div className="preset-title">{preset.title}</div>
              <div className="preset-desc">{preset.description}</div>
            </button>
          ))}
          <div className="side-title">How to use</div>
          <p className="small sub">Click a node for its properties. Double-click to expand its neighbours. Drag nodes, scroll to zoom, drag the canvas to pan.</p>
        </aside>

        <div className="graph-stage">
          <GraphCanvas ref={canvas} graph={graph} selectedId={selected?.id ?? null} showTypes={showTypes} onSelectNode={(n) => { setSelected(n); setSelectedRel(null); }} onSelectRelationship={(r) => { setSelectedRel(r); setSelected(null); }} onExpandNode={(n) => void expand(n)} />
          <div className="graph-status row">
            <span className="chip" data-testid="graph-counts">
              {busy && <span className="spinner" />}
              {plural(graph.nodes.length, 'node')} · {plural(graph.relationships.length, 'relationship')}
              {loaded && ` · ${ms(loaded.elapsedMs)}`}
            </span>
          </div>
          <div className="graph-tools">
            <button className="btn small" onClick={() => setShowTypes((s) => !s)} aria-pressed={showTypes}>
              {showTypes ? 'Hide types' : 'Show types'}
            </button>
            <button className="btn small" onClick={() => canvas.current?.zoomBy(1.3)} aria-label="Zoom in">
              +
            </button>
            <button className="btn small" onClick={() => canvas.current?.zoomBy(1 / 1.3)} aria-label="Zoom out">
              −
            </button>
            <button className="btn small" onClick={() => canvas.current?.fit()}>
              Fit
            </button>
            <button className="btn small" onClick={() => canvas.current?.savePng('relate-books-graph.png')}>
              PNG
            </button>
          </div>
          <div className="graph-overlay">
            {legend.map(([label, n]) => (
              <span key={label} className="label-pill">
                <span className="swatch" style={{ background: labelColor(label, dark) }} />
                {label} <span className="muted">{n}</span>
              </span>
            ))}
          </div>
        </div>

        <aside className="graph-side right" aria-label="Details">
          {error && <div className="banner error" style={{ marginBottom: 8 }}>{error}</div>}
          {notice && <div className="banner" style={{ marginBottom: 8 }}>{notice}</div>}
          {selected ? (
            <div data-testid="node-details">
              <div className="tag-list" style={{ marginBottom: 6 }}>
                {selected.labels.map((l) => (
                  <span key={l} className="label-pill">
                    <span className="swatch" style={{ background: labelColor(l, dark) }} />
                    {l}
                  </span>
                ))}
              </div>
              <h2 style={{ fontSize: 16, lineHeight: 1.3 }}>{nodeCaption(selected, 120)}</h2>
              <p className="muted small" style={{ marginBottom: 8 }}>
                id {selected.id}
                {degree !== null && ` · ${plural(degree, 'relationship')}`}
              </p>
              <div className="row wrap" style={{ marginBottom: 10 }}>
                <button className="btn small primary" onClick={() => void expand(selected)} disabled={busy}>
                  Expand
                </button>
                {bookKey && (
                  <button className="btn small" onClick={() => openBook(bookKey)}>
                    Open book
                  </button>
                )}
                <button className="btn small ghost" onClick={() => remove(selected)}>
                  Remove
                </button>
              </div>
              <Properties properties={selected.properties} />
            </div>
          ) : selectedRel ? (
            <div>
              <span className="label-pill mono">[:{selectedRel.type}]</span>
              <p className="muted small" style={{ margin: '6px 0 8px' }}>id {selectedRel.id}</p>
              <Properties properties={selectedRel.properties} />
            </div>
          ) : (
            <>
              <div className="side-title">{loaded?.title ?? 'Graph'}</div>
              <p className="small sub" style={{ marginBottom: 8 }}>Select a node or a relationship to see its properties.</p>
              {loaded && <CypherDisclosure cypher={loaded.statement.cypher} params={loaded.statement.params} label="Cypher for this view" />}
            </>
          )}
        </aside>
      </div>
    </div>
  );
}
