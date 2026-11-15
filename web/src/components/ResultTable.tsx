import { isWireNode, isWireRelationship, type Row } from '../engine/wire';
import { formatValue } from '../lib/format';
import { nodeCaption, primaryLabel } from '../lib/labels';

function Cell({ value }: { value: unknown }) {
  if (value === null || value === undefined) return <span className="cell-null">null</span>;
  if (isWireNode(value)) return <span className="cell-entity">(:{value.labels.join(':')} {nodeCaption(value, 48)})</span>;
  if (isWireRelationship(value)) return <span className="cell-entity">[:{value.type}]</span>;
  if (Array.isArray(value) && value.length > 0 && (isWireNode(value[0]) || isWireRelationship(value[0]))) {
    // A path, or a collected list of nodes.
    const nodes = value.filter(isWireNode);
    const rels = value.filter(isWireRelationship);
    if (rels.length) {
      return <span className="cell-entity">{value.map((v) => (isWireNode(v) ? `(${nodeCaption(v, 24)})` : isWireRelationship(v) ? `-[:${v.type}]-` : '')).join('')}</span>;
    }
    return <span className="cell-entity">[{nodes.map((n) => `(:${primaryLabel(n.labels)} ${nodeCaption(n, 24)})`).join(', ')}]</span>;
  }
  return <>{formatValue(value)}</>;
}

export function ResultTable({ columns, rows, maxRows = 200 }: { columns: string[]; rows: Row[]; maxRows?: number }) {
  if (columns.length === 0) return <div className="muted small">The statement returned no columns.</div>;
  const shown = rows.slice(0, maxRows);
  const numeric = columns.map((c) => shown.length > 0 && shown.every((r) => r[c] === null || typeof r[c] === 'number'));
  return (
    <div className="stack">
      <div className="table-wrap" style={{ maxHeight: 460 }}>
        <table className="data" data-testid="result-table">
          <thead>
            <tr>
              {columns.map((c, i) => (
                <th key={c} className={numeric[i] ? 'num' : undefined}>
                  {c}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {shown.map((row, r) => (
              <tr key={r}>
                {columns.map((c, i) => (
                  <td key={c} className={numeric[i] ? 'num' : undefined}>
                    <Cell value={row[c]} />
                  </td>
                ))}
              </tr>
            ))}
            {shown.length === 0 && (
              <tr>
                <td colSpan={columns.length} className="muted">
                  No rows.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {rows.length > maxRows && <div className="muted small">Showing the first {maxRows} of {rows.length} rows.</div>}
    </div>
  );
}
