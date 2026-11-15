import { useState } from 'react';
import { ChartTable, Columns, RankedBars, StatTile, type Datum } from '../../components/charts';
import { CypherDisclosure } from '../../components/Cypher';
import { compact, integer, money, ms } from '../../lib/format';
import { labelColor, LEGEND_ORDER } from '../../lib/labels';
import type { BookFilter } from '../../queries/library';
import * as overview from '../../queries/overview';
import { useEngine, useStatement } from '../../state/engine';
import { useNav } from '../../state/nav';

function binLabel(chart: overview.ChartSpec, key: number): string {
  if (chart.id === 'decades') return key < 1900 ? '<1900' : `${key}s`;
  if (chart.id === 'ratings') return key.toFixed(1);
  if (chart.id === 'pages') return key >= 1000 ? '1000+' : String(key);
  return String(key);
}

/** Fill the gaps of an ordered scale so an empty decade is an empty slot, not a missing one. */
function fillBins(chart: overview.ChartSpec, rows: Array<Record<string, unknown>>): Datum[] {
  const values = new Map(rows.map((r) => [Number(r[chart.category]), Number(r[chart.value])]));
  if (values.size === 0) return [];
  const keys = [...values.keys()];
  const step = chart.id === 'ratings' ? 0.5 : chart.id === 'pages' ? 100 : 10;
  const from = chart.id === 'ratings' ? 1 : Math.min(...keys);
  const to = chart.id === 'ratings' ? 5 : Math.max(...keys);
  const data: Datum[] = [];
  for (let k = from; k <= to + 1e-9; k += step) {
    const key = Math.round(k * 10) / 10;
    data.push({ key, label: binLabel(chart, key), value: values.get(key) ?? 0 });
  }
  return data;
}

function drillFilter(chart: overview.ChartSpec, datum: Datum): BookFilter | null {
  if (!chart.drill) return null;
  if ('label' in chart.drill) return { kind: 'term', label: chart.drill.label, name: String(datum.key) };
  switch (chart.drill.filter) {
    case 'decade':
      return { kind: 'decade', decade: Number(datum.key) };
    case 'rating':
      return { kind: 'rating', rating: Number(datum.key) };
    case 'format':
      return { kind: 'format', format: String(datum.key) };
    case 'pages':
      return { kind: 'pages', pages: Number(datum.key) };
  }
}

function ChartCard({ chart }: { chart: overview.ChartSpec }) {
  const { result, error } = useStatement(chart.statement);
  const { openLibrary } = useNav();
  const [table, setTable] = useState(false);
  const rows = result?.rows ?? [];
  const data: Datum[] =
    chart.kind === 'bins' ? fillBins(chart, rows) : rows.map((r) => ({ key: String(r[chart.category]), label: String(r[chart.category]), value: Number(r[chart.value]) }));
  const select = (d: Datum) => {
    const filter = drillFilter(chart, d);
    if (filter && d.value > 0) openLibrary(filter);
  };
  return (
    <section className="card chart-card" data-testid={`chart-${chart.id}`} aria-label={chart.title}>
      <div className="chart-head">
        <div>
          <h2 className="chart-title">{chart.title}</h2>
          {chart.note && <p className="chart-note">{chart.note}</p>}
        </div>
        <span className="spacer" />
        <button className="btn small ghost" aria-pressed={table} onClick={() => setTable((t) => !t)}>
          {table ? 'Chart' : 'Table'}
        </button>
      </div>
      {error && <div className="banner error">{error}</div>}
      {/* A reload keeps the previous render; nothing flashes empty. */}
      <div style={{ opacity: result ? 1 : 0.5 }}>
        {data.length === 0 && result ? (
          <p className="muted small">Nothing to chart in this list.</p>
        ) : table ? (
          <ChartTable data={data} categoryHeader={chart.category} unit={chart.unit} />
        ) : chart.kind === 'ranked' ? (
          <RankedBars data={data} unit={chart.unit} onSelect={select} />
        ) : (
          <Columns data={data} unit={chart.unit} onSelect={select} />
        )}
      </div>
      <div className="row">
        <CypherDisclosure cypher={chart.statement.cypher} params={chart.statement.params} />
        <span className="spacer" />
        {result && <span className="muted small">{ms(result.elapsedMs)}</span>}
      </div>
    </section>
  );
}

function Schema() {
  const labels = useStatement<{ label: string; n: number }>(overview.labelCounts);
  const rels = useStatement<{ from: string; type: string; to: string; n: number }>(overview.relationshipCounts);
  const { openQuery } = useNav();
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const order = (l: string) => {
    const i = LEGEND_ORDER.indexOf(l);
    return i === -1 ? 99 : i;
  };
  const sorted = [...(labels.result?.rows ?? [])].sort((a, b) => order(a.label) - order(b.label));
  return (
    <section className="card card-pad" aria-label="Graph model" style={{ marginTop: 12 }}>
      <div className="chart-head" style={{ marginBottom: 10 }}>
        <div>
          <h2 className="chart-title">The graph model</h2>
          <p className="chart-note">Every label and relationship type in the loaded store, with counts. Click one to query it.</p>
        </div>
      </div>
      <div className="tag-list" style={{ marginBottom: 12 }}>
        {sorted.map((l) => (
          <button key={l.label} className="label-pill" style={{ cursor: 'pointer' }} onClick={() => openQuery(overview.labelSample(l.label))}>
            <span className="swatch" style={{ background: labelColor(l.label, dark) }} />
            {l.label} <span className="muted">{integer(l.n)}</span>
          </button>
        ))}
      </div>
      <div className="schema-list">
        {(rels.result?.rows ?? []).map((r) => (
          <button
            key={`${r.from}-${r.type}-${r.to}`}
            className="schema-rel sample-q"
            style={{ padding: '2px 6px' }}
            onClick={() => openQuery(overview.relationshipSample(r.from, r.type, r.to))}
          >
            <span className="mono">
              (:{r.from})-[:{r.type}]-&gt;(:{r.to})
            </span>
            <span className="n">{integer(r.n)}</span>
          </button>
        ))}
      </div>
      <div className="row" style={{ marginTop: 10 }}>
        <CypherDisclosure cypher={overview.relationshipCounts.cypher} />
      </div>
    </section>
  );
}

export function Overview() {
  const { status } = useEngine();
  const totals = useStatement<overview.LibraryTotals>(overview.totals);
  const labels = useStatement<{ label: string; n: number }>(overview.labelCounts);
  const value = useStatement<{ currency: string; total: number; priced: number }>(overview.listValue);
  const places = useStatement<{ places: number; located: number; pins: number }>(overview.placesLocated);
  const t = totals.result?.rows[0];
  const count = (label: string) => labels.result?.rows.find((r) => r.label === label)?.n ?? 0;
  const v = value.result?.rows[0];
  const p = places.result?.rows[0];
  const dataset = status.dataset;

  return (
    <div className="page" data-testid="overview">
      <section className="card hero" aria-label="Summary">
        <div>
          <div className="tile-label">Books on “{dataset?.name ?? 'the list'}”</div>
          <div className="hero-value" data-testid="hero-books">
            {t ? integer(t.books) : '—'}
          </div>
        </div>
        <p className="sub" style={{ maxWidth: 560 }}>
          {t && t.earliest && t.latest ? `First published between ${t.earliest} and ${t.latest}. ` : ''}
          {dataset
            ? `${integer(dataset.nodes)} nodes and ${integer(dataset.relationships)} relationships, loaded into Relate WASM in ${ms(dataset.loadMs)} and queried in this tab. Nothing is sent to a server.`
            : ''}
        </p>
      </section>

      <div className="tiles">
        <StatTile label="Authors" value={compact(count('Author'))} />
        <StatTile label="Subjects" value={compact(count('Subject'))} />
        <StatTile label="Places" value={compact(count('Place'))} note={p ? `${integer(p.located)} located on the map` : undefined} />
        <StatTile label="Awards" value={compact(count('Award'))} />
        <StatTile label="Average rating" value={t?.avgRating ? t.avgRating.toFixed(2) : '—'} note={t ? `Open Library, ${integer(t.rated)} rated books` : undefined} />
        <StatTile label="Pages to read" value={t?.pages ? compact(t.pages) : '—'} />
        <StatTile label="List value" value={v ? money(v.total, v.currency) : '—'} note={v ? `${integer(v.priced)} priced items` : undefined} />
      </div>

      <div className="chart-grid">
        {overview.charts.map((chart) => (
          <ChartCard key={chart.id} chart={chart} />
        ))}
      </div>

      <Schema />
    </div>
  );
}
