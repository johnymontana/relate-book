import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { textToCypher, type Attempt, type LinkedName, type TextToCypherResult } from '../../ai/text2cypher/pipeline';
import type { RetrievedExample } from '../../ai/text2cypher/retrieve';
import { CypherCode } from '../../components/Cypher';
import { GraphCanvas } from '../../components/GraphCanvas';
import { ResultTable } from '../../components/ResultTable';
import { CypherError, extractGraph, type PlanOperator, type QueryResult, type WireNode } from '../../engine/wire';
import { formatValue, ms, plural } from '../../lib/format';
import { nodeCaption } from '../../lib/labels';
import { useAi } from '../../state/ai';
import { useEngine } from '../../state/engine';
import { useNav } from '../../state/nav';
import { SAMPLE_CYPHER, SAMPLE_QUESTIONS } from '../../queries/samples';

type View = 'table' | 'graph' | 'json' | 'plan';

interface Trace {
  question: string;
  examples: RetrievedExample[] | null;
  names: LinkedName[] | null;
  attempts: Attempt[];
  generating: boolean;
  draft: string;
  outcome: TextToCypherResult | null;
}

function Plan({ op, depth = 0 }: { op: PlanOperator; depth?: number }) {
  return (
    <>
      <div style={{ paddingLeft: depth * 18 }} className="mono">
        <strong>{op.operator}</strong> <span className="muted">{op.details}</span>
        {op.estimated_rows != null && <span className="muted"> · ~{op.estimated_rows} rows</span>}
      </div>
      {op.children?.map((child, i) => <Plan key={i} op={child} depth={depth + 1} />)}
    </>
  );
}

/** Wire JSON for display: vectors collapsed so a row of books stays readable. */
function displayJson(rows: unknown): string {
  return JSON.stringify(rows, (_key, value) => (value && typeof value === 'object' && Array.isArray((value as { values?: unknown }).values) && 'dim' in value ? formatValue(value) : value), 2);
}

function TraceView({ trace, llmName }: { trace: Trace; llmName: string }) {
  const failed = trace.outcome?.error;
  return (
    <div className="card card-pad trace" data-testid="ask-trace" aria-live="polite">
      <div className="trace-step">
        <span className={`trace-icon ${trace.examples ? 'ok' : ''}`}>{trace.examples ? '✓' : '1'}</span>
        <div>
          <strong>Retrieve examples.</strong>{' '}
          {trace.examples ? (
            <details className="disclosure" style={{ display: 'inline' }}>
              <summary>{trace.examples.length} nearest question–Cypher pairs, by embedding similarity</summary>
              <div className="example-list" style={{ marginTop: 6 }}>
                {trace.examples.map((e) => (
                  <div key={e.question} className="small sub">
                    <span className="mono">{e.similarity.toFixed(2)}</span> {e.question}
                  </div>
                ))}
              </div>
            </details>
          ) : (
            <span className="muted">Embedding the question…</span>
          )}
        </div>
      </div>
      <div className="trace-step">
        <span className={`trace-icon ${trace.names ? 'ok' : ''}`}>{trace.names ? '✓' : '2'}</span>
        <div>
          <strong>Link names.</strong>{' '}
          {trace.names ? (
            trace.names.length ? (
              <span className="tag-list" style={{ display: 'inline-flex', verticalAlign: 'middle' }}>
                {trace.names.map((n) => (
                  <span key={`${n.label}:${n.name}`} className="chip">
                    {n.label}: {n.name}
                  </span>
                ))}
              </span>
            ) : (
              <span className="muted">No node names found in the question.</span>
            )
          ) : (
            <span className="muted">Searching the fulltext index…</span>
          )}
        </div>
      </div>
      {trace.attempts.map((attempt, i) => (
        <div className="trace-step" key={i}>
          <span className={`trace-icon ${attempt.problem ? 'bad' : 'ok'}`}>{attempt.problem ? '✗' : '✓'}</span>
          <div className="stack" style={{ minWidth: 0 }}>
            <div>
              <strong>{i === 0 ? 'Generate' : 'Repair'}</strong> <span className="muted">with {llmName}</span>
              {attempt.problem ? ' — rejected, sent back to the model:' : ' — validated with EXPLAIN and run.'}
            </div>
            {attempt.fixes?.map((fix) => (
              <div key={fix} className="muted small">
                Corrected without asking again: {fix}
              </div>
            ))}
            {attempt.problem && (
              <>
                <CypherCode cypher={attempt.cypher} />
                <div className="banner error small" style={{ whiteSpace: 'pre-wrap' }}>
                  {attempt.problem}
                </div>
              </>
            )}
          </div>
        </div>
      ))}
      {trace.generating && (
        <div className="trace-step">
          <span className="spinner" style={{ marginTop: 2 }} />
          <div className="stack" style={{ minWidth: 0 }}>
            <div>
              <strong>{trace.attempts.length ? 'Repairing' : 'Generating'} Cypher</strong> <span className="muted">with {llmName}…</span>
            </div>
            {trace.draft && <CypherCode cypher={trace.draft} />}
          </div>
        </div>
      )}
      {failed && <div className="banner error">{failed}</div>}
    </div>
  );
}

export function QueryConsole() {
  const { db, status, present } = useEngine();
  const { queryRequest, setModelsOpen } = useNav();
  const { llm, llmState, embedder, stub } = useAi();
  const [cypher, setCypher] = useState(SAMPLE_CYPHER[0].cypher);
  const [question, setQuestion] = useState('');
  const [result, setResult] = useState<QueryResult | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [running, setRunning] = useState(false);
  const [view, setView] = useState<View>('table');
  const [trace, setTrace] = useState<Trace | null>(null);
  const [selected, setSelected] = useState<WireNode | null>(null);
  const abort = useRef<AbortController | null>(null);

  const show = useCallback((next: QueryResult) => {
    setResult(next);
    setError(null);
    const graph = extractGraph(next.rows);
    setSelected(null);
    setView(next.plan ? 'plan' : graph.nodes.length > 0 && graph.relationships.length > 0 ? 'graph' : 'table');
  }, []);

  const run = useCallback(
    async (text: string) => {
      const statement = text.trim().replace(/;+\s*$/, '');
      if (!statement || running) return;
      setRunning(true);
      setError(null);
      try {
        const next = await db.query(statement);
        show(next);
        // A write from here changes what the other tabs show.
        if (Object.keys(next.stats).length > 0) db.notifyChanged();
      } catch (err) {
        setResult(null);
        setError(err instanceof CypherError ? err.message : (err as Error).message);
      } finally {
        setRunning(false);
      }
    },
    [db, running, show],
  );

  // A statement handed over from another tab is shown and run.
  const handled = useRef<number | null>(null);
  useEffect(() => {
    if (!queryRequest || handled.current === queryRequest.nonce || status.state !== 'ready') return;
    handled.current = queryRequest.nonce;
    setCypher(queryRequest.cypher);
    setTrace(null);
    void run(queryRequest.cypher);
  }, [queryRequest, run, status.state]);

  const ask = useCallback(
    async (text: string) => {
      const q = text.trim();
      if (!q || !llm) return;
      abort.current?.abort();
      const controller = new AbortController();
      abort.current = controller;
      const fresh: Trace = { question: q, examples: null, names: null, attempts: [], generating: false, draft: '', outcome: null };
      setTrace(fresh);
      setError(null);
      setRunning(true);
      const update = (patch: (t: Trace) => Trace) => setTrace((t) => (t && t.question === q ? patch(t) : t));
      try {
        const outcome = await textToCypher({
          db,
          llm,
          embedder,
          question: q,
          present,
          signal: controller.signal,
          onEvent: (event) => {
            if (event.type === 'examples') update((t) => ({ ...t, examples: event.examples }));
            else if (event.type === 'names') update((t) => ({ ...t, names: event.names }));
            else if (event.type === 'generating') update((t) => ({ ...t, generating: true, draft: '' }));
            else if (event.type === 'token') update((t) => ({ ...t, draft: t.draft + event.delta }));
            else if (event.type === 'attempt') update((t) => ({ ...t, attempts: [...t.attempts, event.attempt], generating: false, draft: '' }));
          },
        });
        update((t) => ({ ...t, outcome, generating: false }));
        if (outcome.cypher && outcome.result) {
          setCypher(outcome.cypher);
          show(outcome.result);
        } else {
          setResult(null);
        }
      } catch (err) {
        if (!controller.signal.aborted) setError((err as Error).message);
        update((t) => ({ ...t, generating: false }));
      } finally {
        setRunning(false);
      }
    },
    [db, llm, embedder, present, show],
  );

  const onEditorKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
      e.preventDefault();
      void run(cypher);
    }
  };

  const graph = useMemo(() => (result ? extractGraph(result.rows) : { nodes: [], relationships: [] }), [result]);
  const hasGraph = graph.nodes.length > 0;
  const llmName = llmState.phase === 'ready' ? llmState.modelId.replace(/-q4f.*$/, '') : 'the model';
  const counters = result ? Object.entries(result.stats) : [];

  return (
    <div className="page-wide" data-testid="query">
      <div className="query-page">
        <aside className="graph-side" aria-label="Examples">
          <div className="side-title">Ask in English</div>
          {SAMPLE_QUESTIONS.map((q) => (
            <button
              key={q}
              className="sample-q"
              onClick={() => {
                setQuestion(q);
                if (llm) void ask(q);
              }}
            >
              {q}
            </button>
          ))}
          <div className="side-title">Cypher</div>
          {SAMPLE_CYPHER.map((s) => (
            <button
              key={s.title}
              className="sample-q"
              onClick={() => {
                setCypher(s.cypher);
                setTrace(null);
                void run(s.cypher);
              }}
            >
              {s.title}
            </button>
          ))}
        </aside>

        <div className="query-main">
          <form
            className="ask-bar"
            onSubmit={(e) => {
              e.preventDefault();
              void ask(question);
            }}
          >
            <input
              className="input"
              placeholder={llm ? 'Ask a question about the list; it becomes Cypher' : 'Load a language model to ask in English'}
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              disabled={!llm}
              aria-label="Question"
              data-testid="ask-input"
            />
            {llm ? (
              <button className="btn primary" type="submit" disabled={running || !question.trim()} data-testid="ask-button">
                Ask
              </button>
            ) : (
              <button className="btn primary" type="button" onClick={() => setModelsOpen(true)} data-testid="ask-load-model">
                {llmState.phase === 'loading' ? `Loading… ${Math.round(llmState.fraction * 100)}%` : 'Load a model'}
              </button>
            )}
          </form>
          {llm && !embedder && !stub && (
            <p className="muted small">
              Examples are picked by shared words until the embedding model is on.{' '}
              <button className="btn small ghost" onClick={() => setModelsOpen(true)}>
                Models
              </button>
            </p>
          )}

          {trace && <TraceView trace={trace} llmName={llmName} />}

          <div className="stack">
            <textarea className="editor" value={cypher} onChange={(e) => setCypher(e.target.value)} onKeyDown={onEditorKey} spellCheck={false} aria-label="Cypher" data-testid="cypher-editor" />
            <div className="row wrap">
              <button className="btn primary" onClick={() => void run(cypher)} disabled={running} data-testid="run-button">
                {running ? 'Running…' : 'Run'}
              </button>
              <span className="muted small">⌘/Ctrl + Enter · runs in Relate WASM in this tab{status.storage === 'opfs' ? ', stored in OPFS' : ', in memory'}</span>
              <span className="spacer" />
              {result && (
                <span className="sub small" data-testid="query-stats">
                  {plural(result.rows.length, 'row')} · engine {ms(result.elapsedMs)} · round trip {ms(result.wallMs)}
                  {counters.length > 0 && ` · ${counters.map(([k, v]) => `${k.replace(/_/g, ' ')} ${v}`).join(', ')}`}
                </span>
              )}
            </div>
          </div>

          {error && (
            <div className="banner error mono" style={{ whiteSpace: 'pre-wrap' }} data-testid="query-error">
              {error}
            </div>
          )}

          {result && (
            <>
              <div className="row">
                <div className="segmented" role="group" aria-label="Result view">
                  <button aria-pressed={view === 'table'} onClick={() => setView('table')}>
                    Table
                  </button>
                  <button aria-pressed={view === 'graph'} onClick={() => setView('graph')} disabled={!hasGraph} title={hasGraph ? undefined : 'Return nodes, relationships or paths to draw a graph'}>
                    Graph
                  </button>
                  <button aria-pressed={view === 'json'} onClick={() => setView('json')}>
                    JSON
                  </button>
                  {result.plan && (
                    <button aria-pressed={view === 'plan'} onClick={() => setView('plan')}>
                      Plan
                    </button>
                  )}
                </div>
                {result.notifications.length > 0 && <span className="chip">{plural(result.notifications.length, 'notification')}</span>}
              </div>
              {result.notifications.map((n, i) => (
                <div key={i} className="banner small">
                  <strong>{n.title}.</strong> {n.description}
                </div>
              ))}
              {view === 'table' && <ResultTable columns={result.columns} rows={result.rows} />}
              {view === 'graph' && hasGraph && (
                <>
                  <div className="result-graph">
                    <GraphCanvas graph={graph} selectedId={selected?.id ?? null} onSelectNode={setSelected} showTypes={graph.relationships.length <= 80} />
                  </div>
                  <div className="muted small">
                    {plural(graph.nodes.length, 'node')}, {plural(graph.relationships.length, 'relationship')}
                    {selected && ` · selected: (:${selected.labels.join(':')}) ${nodeCaption(selected, 80)}`}
                  </div>
                </>
              )}
              {view === 'json' && <pre className="code" style={{ maxHeight: 460, overflow: 'auto' }}>{displayJson(result.rows.slice(0, 100))}</pre>}
              {view === 'plan' && result.plan && (
                <div className="card card-pad">
                  <Plan op={result.plan.root} />
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
