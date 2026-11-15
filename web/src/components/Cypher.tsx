import { useMemo, useState } from 'react';
import { highlightCypher } from '../lib/cypherHighlight';
import { useNav } from '../state/nav';

/** A highlighted Cypher block. Text is rendered as text nodes (never as HTML). */
export function CypherCode({ cypher }: { cypher: string }) {
  const tokens = useMemo(() => highlightCypher(cypher), [cypher]);
  return (
    <pre className="code" data-testid="cypher-code">
      {tokens.map((t, i) => (t.kind === 'plain' ? t.text : <span key={i} className={t.kind}>{t.text}</span>))}
    </pre>
  );
}

/** "Cypher" disclosure: the statement, its parameters, and a way to take it to the Query tab. */
export function CypherDisclosure({ cypher, params, label = 'Cypher' }: { cypher: string; params?: Record<string, unknown>; label?: string }) {
  const { openQuery } = useNav();
  const [copied, setCopied] = useState(false);
  const shown = useMemo(() => inlineParams(cypher, params), [cypher, params]);
  return (
    <details className="disclosure">
      <summary>{label}</summary>
      <div className="stack" style={{ marginTop: 6 }}>
        <CypherCode cypher={shown} />
        <div className="row">
          <button className="btn small" onClick={() => openQuery(shown)}>
            Open in Query
          </button>
          <button
            className="btn small ghost"
            onClick={() => {
              void navigator.clipboard?.writeText(shown).then(() => {
                setCopied(true);
                setTimeout(() => setCopied(false), 1200);
              });
            }}
          >
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>
    </details>
  );
}

function literal(value: unknown): string {
  if (typeof value === 'string') return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
  if (Array.isArray(value)) return value.length > 12 ? `[/* ${value.length} values */]` : `[${value.map(literal).join(', ')}]`;
  if (value === null || value === undefined) return 'null';
  if (typeof value === 'object') return `{${Object.entries(value).map(([k, v]) => `${k}: ${literal(v)}`).join(', ')}}`;
  return String(value);
}

/** Replace `$name` with its value so a displayed statement runs as shown. */
export function inlineParams(cypher: string, params?: Record<string, unknown>): string {
  if (!params) return cypher;
  return cypher.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (whole, name: string) => (name in params ? literal(params[name]) : whole));
}
