// Charts for the Overview tab, built by hand in HTML and SVG to the dataviz
// spec: one hue for magnitude, thin marks with a 4px rounded data end
// anchored to the baseline, hairline solid gridlines, values labelled
// selectively, a hover/focus tooltip on every mark, and a table view of
// every chart so no value is reachable by hover alone.

import { useId, useState, type KeyboardEvent, type ReactNode } from 'react';
import { integer } from '../lib/format';

export interface Datum {
  /** The raw category (what a click reports). */
  key: string | number;
  /** How the category reads on the axis. */
  label: string;
  value: number;
}

interface TooltipState {
  x: number;
  y: number;
  datum: Datum;
}

function Tooltip({ state, unit }: { state: TooltipState | null; unit: string }) {
  if (!state) return null;
  // Value leads, label follows.
  return (
    <div className="tooltip" role="status" style={{ left: Math.min(state.x + 12, window.innerWidth - 220), top: state.y + 14 }}>
      <strong>{integer(state.datum.value)}</strong> {unit} · {state.datum.label}
    </div>
  );
}

function useTooltip() {
  const [state, setState] = useState<TooltipState | null>(null);
  return {
    state,
    handlers: (datum: Datum) => ({
      onPointerMove: (e: { clientX: number; clientY: number }) => setState({ x: e.clientX, y: e.clientY, datum }),
      onPointerLeave: () => setState(null),
      onFocus: (e: { currentTarget: Element }) => {
        const box = e.currentTarget.getBoundingClientRect();
        setState({ x: box.left + box.width / 2, y: box.top + box.height / 2, datum });
      },
      onBlur: () => setState(null),
    }),
  };
}

/** Nominal categories, largest first: one horizontal bar each, all the same hue, value at the tip. */
export function RankedBars({ data, unit, onSelect }: { data: Datum[]; unit: string; onSelect?: (d: Datum) => void }) {
  const tip = useTooltip();
  const max = Math.max(1, ...data.map((d) => d.value));
  return (
    <div className="bars" role="list">
      {data.map((d) => (
        <div className="bar-row" role="listitem" key={String(d.key)}>
          <button
            type="button"
            className="bar-hit"
            onClick={() => onSelect?.(d)}
            aria-label={`${d.label}: ${integer(d.value)} ${unit}`}
            {...tip.handlers(d)}
          >
            <span className="bar-label" title={d.label}>
              {d.label}
            </span>
            <span className="bar-track">
              {/* The value label needs room after the longest bar. */}
              <span className="bar-fill" style={{ width: `calc((100% - 44px) * ${d.value / max})` }} />
              <span className="bar-value">{integer(d.value)}</span>
            </span>
          </button>
        </div>
      ))}
      <Tooltip state={tip.state} unit={unit} />
    </div>
  );
}

function niceTicks(max: number, count = 4): number[] {
  if (max <= 0) return [0];
  const rough = max / count;
  const magnitude = 10 ** Math.floor(Math.log10(rough));
  const step = [1, 2, 5, 10].map((m) => m * magnitude).find((s) => s >= rough) ?? magnitude * 10;
  const whole = Math.max(1, Math.round(step));
  const ticks: number[] = [];
  for (let v = 0; v <= max + whole * 0.999; v += whole) ticks.push(v);
  return ticks;
}

/** An ordered scale (decades, half-stars, page bands): one column per bin, one hue, the peak labelled. */
export function Columns({ data, unit, onSelect, everyNthLabel }: { data: Datum[]; unit: string; onSelect?: (d: Datum) => void; everyNthLabel?: number }) {
  const tip = useTooltip();
  const titleId = useId();
  const W = 560;
  const H = 210;
  const m = { top: 16, right: 6, bottom: 24, left: 34 };
  const plotW = W - m.left - m.right;
  const plotH = H - m.top - m.bottom;
  const ticks = niceTicks(Math.max(...data.map((d) => d.value), 1));
  const top = ticks[ticks.length - 1] || 1;
  const band = plotW / Math.max(1, data.length);
  // Thin marks: never fill the band, cap at 24, and leave at least a 2px gap.
  const width = Math.max(2, Math.min(24, band - 2));
  const peak = data.reduce((best, d) => (d.value > best.value ? d : best), data[0]);
  const nth = everyNthLabel ?? Math.max(1, Math.ceil(data.length / 12));
  const y = (v: number) => m.top + plotH - (v / top) * plotH;

  const onKey = (d: Datum) => (e: KeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      onSelect?.(d);
    }
  };

  return (
    <>
      <svg className="columns-svg" viewBox={`0 0 ${W} ${H}`} role="group" aria-labelledby={titleId}>
        <title id={titleId}>{`${unit} per bin`}</title>
        {ticks.map((t) => (
          <g key={t}>
            <line className={t === 0 ? 'baseline' : 'gridline'} x1={m.left} x2={W - m.right} y1={y(t)} y2={y(t)} />
            <text x={m.left - 6} y={y(t) + 4} textAnchor="end">
              {integer(t)}
            </text>
          </g>
        ))}
        {data.map((d, i) => {
          const cx = m.left + band * i + band / 2;
          const h = d.value > 0 ? Math.max(2, (d.value / top) * plotH) : 0;
          const x = cx - width / 2;
          const r = Math.min(4, width / 2, h);
          const yTop = m.top + plotH - h;
          // Rounded at the data end, square on the baseline.
          const path = `M${x},${m.top + plotH} V${yTop + r} Q${x},${yTop} ${x + r},${yTop} H${x + width - r} Q${x + width},${yTop} ${x + width},${yTop + r} V${m.top + plotH} Z`;
          return (
            <g key={String(d.key)} className="bin" tabIndex={0} role="button" aria-label={`${d.label}: ${integer(d.value)} ${unit}`} onClick={() => onSelect?.(d)} onKeyDown={onKey(d)} {...tip.handlers(d)}>
              {/* The hit target is the whole band, not just the painted column. */}
              <rect className="hit" x={m.left + band * i} y={m.top} width={band} height={plotH + 4} rx={3} />
              {h > 0 && <path className="col" d={path} />}
              {d === peak && d.value > 0 && (
                <text className="peak" x={cx} y={yTop - 5} textAnchor="middle">
                  {integer(d.value)}
                </text>
              )}
              {i % nth === 0 && (
                <text x={cx} y={H - 7} textAnchor="middle">
                  {d.label}
                </text>
              )}
            </g>
          );
        })}
      </svg>
      <Tooltip state={tip.state} unit={unit} />
    </>
  );
}

/** The table view of a chart: every value, no hover needed. */
export function ChartTable({ data, categoryHeader, unit }: { data: Datum[]; categoryHeader: string; unit: string }) {
  return (
    <div className="table-wrap" style={{ maxHeight: 260 }}>
      <table className="data">
        <thead>
          <tr>
            <th>{categoryHeader}</th>
            <th className="num">{unit}</th>
          </tr>
        </thead>
        <tbody>
          {data.map((d) => (
            <tr key={String(d.key)}>
              <td>{d.label}</td>
              <td className="num">{integer(d.value)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function StatTile({ label, value, note }: { label: string; value: ReactNode; note?: ReactNode }) {
  return (
    <div className="card tile">
      <div className="tile-label">{label}</div>
      <div className="tile-value">{value}</div>
      {note && <div className="tile-note">{note}</div>}
    </div>
  );
}
