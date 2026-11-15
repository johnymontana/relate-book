import { useCallback, useEffect, useRef, useState, type KeyboardEvent } from 'react';
import { runAgent, type AgentStep, type AgentTurn } from '../../ai/agent/loop';
import type { BookRef, ToolName } from '../../ai/agent/tools';
import { CypherDisclosure } from '../../components/Cypher';
import { SendIcon, StopIcon } from '../../components/Icons';
import { ResultTable } from '../../components/ResultTable';
import { ms } from '../../lib/format';
import { useAi } from '../../state/ai';
import { useEngine } from '../../state/engine';
import { useNav } from '../../state/nav';

interface PendingStep {
  tool: ToolName;
  input: string;
  thought: string;
  record: AgentStep | null;
}

interface Message {
  id: number;
  question: string;
  steps: PendingStep[];
  phase: 'planning' | 'tool' | 'answering' | 'done' | 'stopped' | 'error';
  answer: string;
  books: BookRef[];
  error?: string;
  ms?: number;
}

const SUGGESTIONS = [
  'Recommend something like Project Hail Mary',
  'Which authors do I have the most books by?',
  'Tell me about The Left Hand of Darkness',
  'What should I read if I want something about Mars?',
  'How many books won awards, and which ones?',
];

const TOOL_LABEL: Record<ToolName, string> = {
  search_books: 'Search books',
  query_graph: 'Query the graph',
  book_details: 'Look up a book',
  similar_books: 'Find similar books',
};

function Step({ step }: { step: PendingStep }) {
  const result = step.record?.result;
  return (
    <div className="step" data-testid="chat-step">
      <div className="step-head">
        {step.record ? <span className={`trace-icon ${result?.failed ? 'bad' : 'ok'}`}>{result?.failed ? '✗' : '✓'}</span> : <span className="spinner" />}
        <span className="step-tool">{TOOL_LABEL[step.tool]}</span>
        <span className="step-input" title={step.input}>
          {step.input}
        </span>
        <span className="spacer" />
        {step.record && <span className="muted small">{ms(step.record.ms)}</span>}
      </div>
      {step.record && result && (
        <details className="disclosure" style={{ marginTop: 6 }}>
          <summary>{step.thought ? `Why: ${step.thought}` : 'Details'}</summary>
          <div className="step-body">
            {result.trace && result.trace.attempts.length > 1 && (
              <p className="muted small">
                {result.trace.attempts.length} attempts: the model repaired its Cypher after the engine rejected it.
              </p>
            )}
            {result.cypher && <CypherDisclosure cypher={result.cypher} label="Generated Cypher" />}
            {result.table ? <ResultTable columns={result.table.columns} rows={result.table.rows} maxRows={15} /> : <pre className="code">{result.observation}</pre>}
          </div>
        </details>
      )}
    </div>
  );
}

export function Chat() {
  const { db, present, status } = useEngine();
  const { llm, llmState, embedder, index } = useAi();
  const { setModelsOpen, openBook } = useNav();
  const [messages, setMessages] = useState<Message[]>([]);
  const [draft, setDraft] = useState('');
  const [busy, setBusy] = useState(false);
  const abort = useRef<AbortController | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const nextId = useRef(1);

  useEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  // A new dataset makes the conversation about another list.
  const generation = useRef(status.generation);
  useEffect(() => {
    if (generation.current !== status.generation) {
      generation.current = status.generation;
      abort.current?.abort();
      setMessages([]);
    }
  }, [status.generation]);

  const send = useCallback(
    async (text: string) => {
      const question = text.trim();
      if (!question || !llm || busy) return;
      const id = nextId.current++;
      const controller = new AbortController();
      abort.current = controller;
      setDraft('');
      setBusy(true);
      const history: AgentTurn[] = messages.filter((m) => m.phase === 'done').map((m) => ({ question: m.question, answer: m.answer }));
      setMessages((all) => [...all, { id, question, steps: [], phase: 'planning', answer: '', books: [] }]);
      const update = (patch: (m: Message) => Message) => setMessages((all) => all.map((m) => (m.id === id ? patch(m) : m)));
      try {
        const result = await runAgent({
          db,
          llm,
          embedder,
          question,
          history,
          present,
          signal: controller.signal,
          onEvent: (event) => {
            switch (event.type) {
              case 'thinking':
                update((m) => ({ ...m, phase: 'planning' }));
                break;
              case 'tool-start':
                update((m) => ({ ...m, phase: 'tool', steps: [...m.steps, { tool: event.tool, input: event.input, thought: event.thought, record: null }] }));
                break;
              case 'tool-end':
                update((m) => ({ ...m, phase: 'planning', steps: m.steps.map((s, i) => (i === m.steps.length - 1 ? { ...s, record: event.record } : s)) }));
                break;
              case 'answer-start':
                update((m) => ({ ...m, phase: 'answering' }));
                break;
              case 'answer-token':
                update((m) => ({ ...m, answer: m.answer + event.delta }));
                break;
            }
          },
        });
        update((m) => ({ ...m, phase: 'done', answer: result.answer, books: result.books, ms: result.ms }));
      } catch (err) {
        if (controller.signal.aborted) update((m) => ({ ...m, phase: 'stopped' }));
        else update((m) => ({ ...m, phase: 'error', error: (err as Error).message }));
      } finally {
        setBusy(false);
      }
    },
    [db, llm, embedder, present, busy, messages],
  );

  const onKey = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      void send(draft);
    }
  };

  if (!llm) {
    return (
      <div className="center-screen" data-testid="chat">
        <div className="empty" style={{ maxWidth: 520 }}>
          <h2>Chat with your wishlist</h2>
          <p style={{ marginBottom: 12 }}>
            An agent that runs in this tab: a language model on your GPU plans which tool to use, the tools query the Relate graph (semantic search, generated Cypher, book lookups), and the answer is written from what they return.
          </p>
          <button className="btn primary" onClick={() => setModelsOpen(true)} data-testid="chat-load-model">
            {llmState.phase === 'loading' ? `Loading model… ${Math.round(llmState.fraction * 100)}%` : 'Choose and load a model'}
          </button>
          {llmState.phase === 'error' && <p className="banner error" style={{ marginTop: 12 }}>{llmState.message}</p>}
        </div>
      </div>
    );
  }

  return (
    <div className="chat-page" data-testid="chat">
      <div className="chat-scroll" ref={scroller}>
        <div className="chat-inner">
          {messages.length === 0 && (
            <div className="empty">
              <h2>Ask about your list</h2>
              <p style={{ marginBottom: 12 }}>
                The agent picks tools, queries the graph and answers from the results.
                {!embedder && ' Semantic search is off, so book search uses keywords only.'}
                {embedder && index.phase === 'indexing' && ' Books are still being embedded; search improves as it finishes.'}
              </p>
              <div className="suggestions" style={{ justifyContent: 'center' }}>
                {SUGGESTIONS.map((s) => (
                  <button key={s} className="chip" onClick={() => void send(s)}>
                    {s}
                  </button>
                ))}
              </div>
            </div>
          )}
          {messages.map((m) => (
            <div key={m.id} className="stack" style={{ gap: 10 }}>
              <div className="msg-user">{m.question}</div>
              <div className="msg-agent" data-testid="chat-answer-block">
                {m.steps.map((s, i) => (
                  <Step key={i} step={s} />
                ))}
                {m.phase === 'planning' && (
                  <div className="row muted small">
                    <span className="spinner" /> {m.steps.length ? 'Deciding the next step…' : 'Deciding what to look up…'}
                  </div>
                )}
                {(m.answer || m.phase === 'answering') && (
                  <div className="answer" data-testid="chat-answer">
                    {m.answer || <span className="muted">Writing…</span>}
                  </div>
                )}
                {m.phase === 'stopped' && <div className="muted small">Stopped.</div>}
                {m.phase === 'error' && <div className="banner error">{m.error}</div>}
                {m.phase === 'done' && m.books.length > 0 && (
                  <div className="tag-list">
                    {m.books.slice(0, 10).map((b) => (
                      <button key={b.key} className="tag" onClick={() => openBook(b.key)} title={`Open ${b.title}`}>
                        {b.title}
                      </button>
                    ))}
                  </div>
                )}
                {m.phase === 'done' && m.ms != null && (
                  <div className="muted small">
                    {m.steps.length} tool {m.steps.length === 1 ? 'call' : 'calls'} · {ms(m.ms)}
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      </div>
      <div className="chat-compose">
        <div className="chat-compose-inner">
          <textarea
            rows={1}
            placeholder="Ask about your books…"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKey}
            aria-label="Message"
            data-testid="chat-input"
          />
          {busy ? (
            <button className="btn" onClick={() => abort.current?.abort()} aria-label="Stop">
              <StopIcon /> Stop
            </button>
          ) : (
            <button className="btn primary" onClick={() => void send(draft)} disabled={!draft.trim()} aria-label="Send" data-testid="chat-send">
              <SendIcon /> Send
            </button>
          )}
          {messages.length > 0 && !busy && (
            <button className="btn ghost" onClick={() => setMessages([])}>
              Clear
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
