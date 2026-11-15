import { beforeAll, describe, expect, it } from 'vitest';
import { extractGraph } from '../src/engine/wire';
import * as graph from '../src/queries/graph';
import * as library from '../src/queries/library';
import * as overview from '../src/queries/overview';
import { run } from '../src/queries/statement';
import { sampleDb, type TestDb } from './helpers/engine';

let db: TestDb;
beforeAll(async () => {
  db = await sampleDb();
});

describe('overview', () => {
  it('totals the library', async () => {
    const t = (await run<overview.LibraryTotals>(db, overview.totals)).rows[0];
    expect(t.books).toBe(6);
    expect(t.rated).toBeGreaterThan(0);
    expect(t.avgRating).toBeGreaterThan(3);
    expect(t.earliest).toBe(1969);
  });

  it('counts labels, relationship types, prices and places', async () => {
    const labels = Object.fromEntries((await run<{ label: string; n: number }>(db, overview.labelCounts)).rows.map((r) => [r.label, r.n]));
    expect(labels.Book).toBe(6);
    expect(labels.Subject).toBe(173);
    const rels = (await run<{ from: string; type: string; to: string; n: number }>(db, overview.relationshipCounts)).rows;
    expect(rels.find((r) => r.type === 'ABOUT')).toEqual({ from: 'Book', type: 'ABOUT', to: 'Subject', n: 187 });
    expect(rels.find((r) => r.type === 'EDITION_OF')?.from).toBe('Item');
    const value = (await run<{ currency: string; total: number; priced: number }>(db, overview.listValue)).rows;
    expect(value[0].currency).toBe('USD');
    expect(value[0].total).toBeGreaterThan(0);
    const places = (await run<{ places: number; located: number; pins: number }>(db, overview.placesLocated)).rows[0];
    expect(places).toMatchObject({ places: 34, located: 19 });
  });

  it('runs every chart and returns its category and value columns', async () => {
    for (const chart of overview.charts) {
      const result = await run(db, chart.statement);
      expect(result.columns, chart.id).toContain(chart.category);
      expect(result.columns, chart.id).toContain(chart.value);
      expect(result.rows.length, chart.id).toBeGreaterThan(0);
      for (const row of result.rows) expect(typeof row[chart.value], chart.id).toBe('number');
    }
  });

  it('charts the sample as expected', async () => {
    const chart = (id: string) => overview.charts.find((c) => c.id === id)!;
    const decades = (await run<{ decade: number; books: number }>(db, chart('decades').statement)).rows;
    expect(decades).toEqual([
      { decade: 1960, books: 1 },
      { decade: 1990, books: 1 },
      { decade: 2000, books: 2 },
      { decade: 2010, books: 1 },
      { decade: 2020, books: 1 },
    ]);
    const subjects = (await run<{ subject: string; books: number }>(db, chart('subjects').statement)).rows;
    expect(subjects[0].books).toBeGreaterThanOrEqual(2);
    expect(subjects.map((s) => s.subject)).not.toContain('fiction');
    // Three Open Library records share the name David Allen; the book counts once.
    const authors = (await run<{ author: string; books: number }>(db, chart('authors').statement)).rows;
    expect(authors).toContainEqual({ author: 'Andy Weir', books: 1 });
    expect(authors.filter((r) => r.author === 'David Allen')).toEqual([{ author: 'David Allen', books: 1 }]);
  });
});

describe('library', () => {
  it('lists books with authors, cover and edition facts, in each sort order', async () => {
    const byTitle = await library.fetchBooks(db, library.listBooks({ kind: 'all' }, 'title', 50));
    expect(byTitle.find((b) => b.title === 'Getting Things Done')!.authors).toEqual(['David Allen']);
    expect(byTitle.map((b) => b.title)).toEqual([
      'A Truck Full of Money',
      'Getting Things Done',
      'Project Hail Mary',
      'Red Mars',
      'The Curious Incident of the Dog in the Night-Time',
      'The Left Hand of Darkness',
    ]);
    const hail = byTitle.find((b) => b.title === 'Project Hail Mary')!;
    expect(hail.authors).toEqual(['Andy Weir']);
    expect(hail.cover).toMatch(/^https:\/\//);
    expect(hail.format).toBeTruthy();

    const newest = (await run<library.BookSummary>(db, library.listBooks({ kind: 'all' }, 'newest', 50))).rows;
    expect(newest[0].title).toBe('Project Hail Mary');
    expect(newest[newest.length - 1].title).toBe('The Left Hand of Darkness');
    const oldest = (await run<library.BookSummary>(db, library.listBooks({ kind: 'all' }, 'oldest', 50))).rows;
    expect(oldest[0].title).toBe('The Left Hand of Darkness');
    for (const sort of library.SORTS) {
      const rows = (await run<library.BookSummary>(db, library.listBooks({ kind: 'all' }, sort.id, 3, 2))).rows;
      expect(rows, sort.id).toHaveLength(3);
    }
  });

  it('filters by term, decade, rating, format and pages, and counts the same set', async () => {
    const cases: Array<[library.BookFilter, string[]]> = [
      [{ kind: 'term', label: 'Author', name: 'Ursula K. Le Guin' }, ['The Left Hand of Darkness']],
      [{ kind: 'term', label: 'Place', name: 'San Francisco' }, ['Project Hail Mary']],
      [{ kind: 'term', label: 'Author', name: 'David Allen' }, ['Getting Things Done']],
      [{ kind: 'term', label: 'Series', name: 'Hainish Cycle' }, ['The Left Hand of Darkness']],
      [{ kind: 'decade', decade: 2000 }, ['Getting Things Done', 'The Curious Incident of the Dog in the Night-Time']],
      [{ kind: 'decade', decade: 1890 }, []],
    ];
    for (const [filter, titles] of cases) {
      const rows = (await run<library.BookSummary>(db, library.listBooks(filter, 'title', 50))).rows;
      expect(rows.map((b) => b.title), library.describeFilter(filter)).toEqual(titles);
      const count = (await run<{ books: number }>(db, library.countBooks(filter))).rows[0].books;
      expect(count, library.describeFilter(filter)).toBe(titles.length);
    }
    const awarded = (await run<library.BookSummary>(db, library.listBooks({ kind: 'term', label: 'Award', name: 'Hugo Award for Best Novel' }, 'title', 50))).rows;
    expect(awarded.map((b) => b.title)).toContain('The Left Hand of Darkness');
  });

  it('every chart bar drills down to at least one book', async () => {
    for (const chart of overview.charts) {
      if (!chart.drill) continue;
      const first = (await run(db, chart.statement)).rows[0];
      const category = first[chart.category];
      const filter: library.BookFilter =
        'label' in chart.drill
          ? { kind: 'term', label: chart.drill.label, name: String(category) }
          : chart.drill.filter === 'decade'
            ? { kind: 'decade', decade: Number(category) }
            : chart.drill.filter === 'rating'
              ? { kind: 'rating', rating: Number(category) }
              : chart.drill.filter === 'format'
                ? { kind: 'format', format: String(category) }
                : { kind: 'pages', pages: Number(category) };
      const count = (await run<{ books: number }>(db, library.countBooks(filter))).rows[0].books;
      expect(count, `${chart.id}: ${String(category)}`).toBeGreaterThan(0);
      if (chart.unit === 'books') expect(count, `${chart.id}: ${String(category)}`).toBe(first[chart.value]);
    }
  });

  it('reads one book with everything attached', async () => {
    const key = (await db.query<{ key: string }>("MATCH (b:Book {title: 'The Left Hand of Darkness'}) RETURN b.key AS key")).rows[0].key;
    const book = (await library.getBook(db, key))!;
    expect(book.title).toBe('The Left Hand of Darkness');
    expect(book.authors.map((a) => a.name)).toContain('Ursula K. Le Guin');
    expect(book.series).toEqual([{ name: 'Hainish Cycle', position: '4' }]);
    expect(book.places).toContain('Gethen');
    expect(book.subjects.length).toBeGreaterThan(5);
    expect(book.editions).toHaveLength(1);
    expect(book.editions[0].publisher).toBeTruthy();
    expect(book.embedded).toBe(false);
    expect(await library.getBook(db, 'nope')).toBeNull();
  });

  it('returns books by key in the order asked', async () => {
    const all = (await run<library.BookSummary>(db, library.listBooks({ kind: 'all' }, 'title', 50))).rows;
    const keys = [all[4].key, all[0].key, 'missing', all[2].key];
    const rows = (await run<library.BookSummary>(db, library.booksByKeys(keys))).rows;
    expect(rows.map((b) => b.key)).toEqual([all[4].key, all[0].key, all[2].key]);
  });
});

describe('graph', () => {
  it('every preset returns a graph', async () => {
    for (const preset of graph.presets) {
      const g = extractGraph((await run(db, preset.statement)).rows);
      expect(g.nodes.length, preset.id).toBeGreaterThan(1);
      expect(g.relationships.length, preset.id).toBeGreaterThan(0);
      const ids = new Set(g.nodes.map((n) => n.id));
      for (const r of g.relationships) expect(ids.has(r.start_node) && ids.has(r.end_node), preset.id).toBe(true);
    }
  });

  it('expands a node, a book and a term, and finds relationships among nodes', async () => {
    const book = (await db.query<{ id: number; key: string }>("MATCH (b:Book {title: 'Red Mars'}) RETURN id(b) AS id, b.key AS key")).rows[0];
    const around = extractGraph((await run(db, graph.bookNeighborhood(book.key))).rows);
    expect(around.nodes.some((n) => n.labels.includes('Author') && n.properties.name === 'Kim Stanley Robinson')).toBe(true);
    const expanded = extractGraph((await run(db, graph.expand(book.id, 5))).rows);
    expect(expanded.relationships).toHaveLength(5);
    const degree = (await run<{ degree: number }>(db, graph.degree(book.id))).rows[0].degree;
    expect(degree).toBeGreaterThan(5);
    const term = extractGraph((await run(db, graph.termNeighborhood('Author', 'Andy Weir'))).rows);
    expect(term.nodes.some((n) => n.properties.title === 'Project Hail Mary')).toBe(true);
    const among = extractGraph((await run(db, graph.relationshipsAmong(around.nodes.map((n) => n.id)))).rows);
    expect(among.relationships.length).toBeGreaterThanOrEqual(around.relationships.length);
    expect(() => graph.termNeighborhood('Book) DETACH DELETE (n', 'x')).toThrow();
    const byTitle = extractGraph((await run(db, graph.bookNeighborhoodByTitle('Red Mars'))).rows);
    expect(byTitle.nodes.length).toBe(around.nodes.length);
    expect(overview.labelSample('Book')).toBe('MATCH (n:Book)\nRETURN n\nLIMIT 25');
    expect(overview.relationshipSample('Book', 'WRITTEN BY', 'Author')).toBe('MATCH p = (:Book)-[:`WRITTEN BY`]->(:Author)\nRETURN p\nLIMIT 50');
    expect((await run(db, overview.presentLabels)).rows.length).toBe(14);
  });
});
