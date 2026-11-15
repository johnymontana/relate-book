import { useEffect, useMemo, useState } from 'react';
import { Cover } from '../../components/Cover';
import { CypherDisclosure } from '../../components/Cypher';
import { CloseIcon, SearchIcon } from '../../components/Icons';
import { integer, money, ms, plural } from '../../lib/format';
import * as graphQueries from '../../queries/graph';
import { bookDetail, countBooks, describeFilter, fetchBooks, getBook, listBooks, SORTS, type BookDetail, type BookSort, type BookSummary } from '../../queries/library';
import type { SearchHit } from '../../search/rankFusion';
import { searchBooks, similarBooks, type SearchResponse } from '../../search/searchService';
import { useAi } from '../../state/ai';
import { useEngine, useStatement } from '../../state/engine';
import { useNav } from '../../state/nav';

const PAGE = 60;

const REASON: Record<SearchHit['reason'], string> = { both: 'meaning + keywords', semantic: 'meaning', keyword: 'keywords' };

function BookRow({ book, selected, onOpen, hit }: { book: BookSummary; selected: boolean; onOpen: () => void; hit?: SearchHit }) {
  return (
    <button type="button" className="book-row" onClick={onOpen} aria-current={selected} data-testid="book-row">
      <Cover src={book.cover} title={book.title} />
      <span style={{ minWidth: 0 }}>
        <span className="book-title">{book.title}</span>
        <span className="book-meta" style={{ display: 'block' }}>
          {book.authors.join(', ') || 'Unknown author'}
        </span>
        <span className="book-facts">
          {book.year && <span>{book.year}</span>}
          {book.rating != null && book.rating > 0 && <span>★ {book.rating.toFixed(1)}</span>}
          {book.format && <span>{book.format}</span>}
          {book.price != null && <span>{money(book.price, book.currency ?? 'USD')}</span>}
          {hit && <span className="badge">{REASON[hit.reason]}</span>}
        </span>
      </span>
    </button>
  );
}

function Tags({ label, names, onPick }: { label: string; names: string[]; onPick: (name: string) => void }) {
  const [all, setAll] = useState(false);
  if (names.length === 0) return null;
  const shown = all ? names : names.slice(0, 14);
  return (
    <div className="panel-section">
      <h3>{label}</h3>
      <div className="tag-list">
        {shown.map((name) => (
          <button key={name} className="tag" title={name} onClick={() => onPick(name)}>
            {name}
          </button>
        ))}
        {names.length > shown.length && (
          <button className="tag" onClick={() => setAll(true)}>
            +{names.length - shown.length} more
          </button>
        )}
      </div>
    </div>
  );
}

/** Open Library descriptions run from a line to several pages; long ones start folded. */
function Description({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const long = text.length > 700;
  return (
    <div className="panel-section">
      <h3>Description</h3>
      <p className="description">{long && !open ? `${text.slice(0, 600).trimEnd()}…` : text}</p>
      {long && (
        <button className="btn small ghost" onClick={() => setOpen((o) => !o)} style={{ marginTop: 4 }}>
          {open ? 'Show less' : 'Show more'}
        </button>
      )}
    </div>
  );
}

function BookPanel({ bookKey }: { bookKey: string }) {
  const { db, status } = useEngine();
  const { openBook, openLibrary, showGraph } = useNav();
  const { embedder, index, enableEmbeddings, embedderState } = useAi();
  const [book, setBook] = useState<BookDetail | null | undefined>(undefined);
  const [similar, setSimilar] = useState<Array<{ book: BookSummary; cosine: number }>>([]);
  const indexed = index.phase === 'idle' ? index.embedded : 0;

  useEffect(() => {
    let cancelled = false;
    setBook(undefined);
    void getBook(db, bookKey).then((b) => !cancelled && setBook(b));
    return () => {
      cancelled = true;
    };
  }, [db, bookKey, status.generation]);

  useEffect(() => {
    let cancelled = false;
    setSimilar([]);
    void similarBooks(db, bookKey, 6)
      .then((rows) => !cancelled && setSimilar(rows))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [db, bookKey, indexed, status.generation]);

  if (book === undefined) return <aside className="card panel" aria-busy="true" />;
  if (book === null) {
    return (
      <aside className="card panel">
        <p className="muted">That book is not in this list.</p>
      </aside>
    );
  }
  const term = (label: string) => (name: string) => openLibrary({ kind: 'term', label, name });
  const statement = bookDetail(book.key);
  return (
    <aside className="card panel" data-testid="book-panel" aria-label={book.title}>
      <div className="row" style={{ alignItems: 'flex-start', gap: 14 }}>
        <Cover src={book.cover ?? book.editions[0]?.image} title={book.title} large />
        <div style={{ minWidth: 0, flex: 1 }}>
          <div className="row" style={{ alignItems: 'flex-start' }}>
            <h2 style={{ flex: 1 }}>{book.title}</h2>
            <button className="btn small ghost" onClick={() => openBook(null)} aria-label="Close">
              <CloseIcon />
            </button>
          </div>
          {book.subtitle && <p className="sub">{book.subtitle}</p>}
          <div className="tag-list" style={{ marginTop: 6 }}>
            {book.authors.map((a) => (
              <button key={a.name} className="tag" onClick={() => term('Author')(a.name)}>
                {a.name}
              </button>
            ))}
          </div>
          <div className="book-facts" style={{ marginTop: 8 }}>
            {book.year && <span>First published {book.year}</span>}
            {book.pages && <span>{integer(book.pages)} pages</span>}
            {book.rating != null && book.rating > 0 && (
              <span>
                ★ {book.rating.toFixed(2)} ({integer(book.ratingCount ?? 0)})
              </span>
            )}
            {book.wantToRead != null && <span>{integer(book.wantToRead)} want to read</span>}
          </div>
          <div className="row wrap" style={{ marginTop: 10 }}>
            <button className="btn small" onClick={() => showGraph(book.title, graphQueries.bookNeighborhood(book.key))}>
              Show in graph
            </button>
            {book.url && (
              <a className="btn small ghost" href={book.url} target="_blank" rel="noreferrer">
                Open Library ↗
              </a>
            )}
          </div>
        </div>
      </div>

      {book.description && <Description text={book.description} />}
      {book.series.length > 0 && (
        <div className="panel-section">
          <h3>Series</h3>
          <div className="tag-list">
            {book.series.map((s) => (
              <button key={s.name} className="tag" onClick={() => term('Series')(s.name)}>
                {s.name}
                {s.position ? ` #${s.position}` : ''}
              </button>
            ))}
          </div>
        </div>
      )}
      <Tags label="Genres" names={book.genres} onPick={term('Genre')} />
      <Tags label="Awards" names={book.awards} onPick={term('Award')} />
      <Tags label="Set in" names={book.places} onPick={term('Place')} />
      <Tags label="Features" names={book.people} onPick={term('Person')} />
      <Tags label="Set during" names={book.eras} onPick={term('Era')} />
      <Tags label="Subjects" names={book.subjects.filter((s) => !s.includes(':'))} onPick={term('Subject')} />

      <div className="panel-section">
        <h3>More like this</h3>
        {similar.length > 0 ? (
          <div>
            {similar.map((s) => (
              <button key={s.book.key} className="similar-row" onClick={() => openBook(s.book.key)}>
                <span>
                  {s.book.title} <span className="muted">· {s.book.authors[0] ?? ''}</span>
                </span>
                <span className="n" title="cosine similarity">
                  {s.cosine.toFixed(2)}
                </span>
              </button>
            ))}
          </div>
        ) : embedder ? (
          <p className="muted small">{index.phase === 'indexing' || index.phase === 'pending' ? 'Embedding the books…' : 'This book has no embedding yet.'}</p>
        ) : (
          <div className="row wrap">
            <span className="muted small">Needs the embedding model (about {embedderState.phase === 'off' ? '90 MB on WebGPU, 23 MB on WASM' : 'a moment'}).</span>
            <button className="btn small" onClick={() => void enableEmbeddings()} disabled={embedderState.phase === 'loading'}>
              {embedderState.phase === 'loading' ? 'Loading…' : 'Enable semantic search'}
            </button>
          </div>
        )}
      </div>

      {book.editions.length > 0 && (
        <div className="panel-section">
          <h3>On the list as</h3>
          {book.editions.map((e, i) => (
            <div key={i} className="small" style={{ marginBottom: 4 }}>
              {e.url ? (
                <a href={e.url} target="_blank" rel="noreferrer">
                  {e.format ?? 'Edition'}
                </a>
              ) : (
                (e.format ?? 'Edition')
              )}
              {e.price != null && ` · ${money(e.price, e.currency ?? 'USD')}`}
              {e.publisher && ` · ${e.publisher}`}
              {e.year && ` · ${e.year}`}
            </div>
          ))}
        </div>
      )}
      <div className="panel-section">
        <CypherDisclosure cypher={statement.cypher} params={statement.params} label="Cypher for this page" />
      </div>
    </aside>
  );
}

export function Library() {
  const { db, status } = useEngine();
  const { bookKey, openBook, filter, openLibrary } = useNav();
  const { embedder, index, embedderState, enableEmbeddings } = useAi();
  const [sort, setSort] = useState<BookSort>('title');
  const [limit, setLimit] = useState(PAGE);
  const [query, setQuery] = useState('');
  const [books, setBooks] = useState<BookSummary[]>([]);
  const [search, setSearch] = useState<SearchResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState<number | null>(null);

  const statement = useMemo(() => listBooks(filter, sort, limit), [filter, sort, limit]);
  const total = useStatement<{ books: number }>(countBooks(filter));
  const searching = query.trim().length >= 2;
  const indexed = index.phase === 'idle' ? index.embedded : -1;

  useEffect(() => setLimit(PAGE), [filter, sort]);

  useEffect(() => {
    if (searching || status.state !== 'ready') return;
    let cancelled = false;
    const started = performance.now();
    fetchBooks(db, statement)
      .then((rows) => {
        if (cancelled) return;
        setBooks(rows);
        setElapsed(performance.now() - started);
        setError(null);
      })
      .catch((err: Error) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [db, statement, searching, status.state, status.generation]);

  useEffect(() => {
    if (!searching || status.state !== 'ready') {
      setSearch(null);
      return;
    }
    let cancelled = false;
    // Debounce typing; the query itself takes tens of milliseconds.
    const timer = setTimeout(() => {
      searchBooks(db, embedder, query)
        .then((response) => {
          if (!cancelled) {
            setSearch(response);
            setError(null);
          }
        })
        .catch((err: Error) => !cancelled && setError(err.message));
    }, 180);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [db, embedder, query, searching, status.state, status.generation, indexed]);

  const count = total.result?.rows[0]?.books ?? 0;
  return (
    <div className="page" data-testid="library">
      <div className="toolbar">
        <div className="search-box">
          <SearchIcon />
          <input
            className="input"
            type="search"
            placeholder={embedder ? 'Search by meaning or keywords: “lonely astronaut saves earth”' : 'Search titles, authors and descriptions'}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            aria-label="Search books"
            data-testid="library-search"
          />
        </div>
        {!embedder && (
          <button className="btn" onClick={() => void enableEmbeddings()} disabled={embedderState.phase === 'loading'} data-testid="enable-semantic">
            {embedderState.phase === 'loading' ? `Loading model… ${Math.round(embedderState.fraction * 100)}%` : 'Enable semantic search'}
          </button>
        )}
        <label className="row small sub">
          Sort
          <select className="select" value={sort} onChange={(e) => setSort(e.target.value as BookSort)} disabled={searching} aria-label="Sort books">
            {SORTS.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="row wrap" style={{ marginBottom: 12 }}>
        {searching ? (
          <span className="sub" data-testid="library-status">
            {search ? `${plural(search.results.length, 'result')} for “${search.query}” in ${ms(search.ms)}` : 'Searching…'}
            {search && (search.semanticUsed ? ' · vector index + fulltext, fused' : ' · fulltext only')}
          </span>
        ) : (
          <>
            <span className="sub" data-testid="library-status">
              {filter.kind === 'all' ? plural(count, 'book') : `${plural(count, 'book')} · ${describeFilter(filter)}`}
            </span>
            {filter.kind !== 'all' && (
              <button className="chip" onClick={() => openLibrary({ kind: 'all' })}>
                Clear filter <CloseIcon />
              </button>
            )}
            {elapsed != null && <span className="muted small">{ms(elapsed)}</span>}
          </>
        )}
        <span className="spacer" />
        {!searching && <CypherDisclosure cypher={statement.cypher} params={statement.params} />}
        {embedder && index.phase === 'indexing' && (
          <span className="chip">
            <span className="dot busy" />
            Embedding {integer(index.progress.scanned)} / {integer(index.progress.total)}
          </span>
        )}
      </div>

      {error && <div className="banner error">{error}</div>}

      <div className={bookKey ? 'library with-panel' : 'library'}>
        <div>
          <div className="book-grid">
            {searching
              ? (search?.results ?? []).map((r) => <BookRow key={r.book.key} book={r.book} hit={r.hit} selected={r.book.key === bookKey} onOpen={() => openBook(r.book.key)} />)
              : books.map((b) => <BookRow key={b.key} book={b} selected={b.key === bookKey} onOpen={() => openBook(b.key)} />)}
          </div>
          {searching && search && search.results.length === 0 && (
            <div className="empty">
              <h2>No books match</h2>
              <p>{embedder ? 'Try other words.' : 'Keyword search needs every word to appear. Enable semantic search to match by meaning.'}</p>
            </div>
          )}
          {!searching && books.length < count && (
            <div style={{ textAlign: 'center', marginTop: 16 }}>
              <button className="btn" onClick={() => setLimit((l) => l + PAGE * 2)}>
                Show more ({integer(count - books.length)} left)
              </button>
            </div>
          )}
        </div>
        {bookKey && <BookPanel bookKey={bookKey} />}
      </div>
    </div>
  );
}
