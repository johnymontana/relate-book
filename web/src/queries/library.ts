// Cypher behind the Library tab: the book list, a book's page, and the books
// behind a chart bar.

import type { GraphDb } from '../engine/wire';
import { cypher, run, type Statement } from './statement';

export interface BookSummary {
  key: string;
  title: string;
  subtitle: string | null;
  year: number | null;
  rating: number | null;
  wantToRead: number | null;
  pages: number | null;
  cover: string | null;
  authors: string[];
  format: string | null;
  price: number | null;
  currency: string | null;
}

/** RETURN for a `b` in scope. No pattern comprehension over editions: one OPTIONAL MATCH keeps it flat. */
const SUMMARY = cypher`
  OPTIONAL MATCH (b)<-[:EDITION_OF]-(e:Edition)
  WITH b, sortKey, head(collect(e)) AS e
  RETURN b.key AS key, b.title AS title, b.subtitle AS subtitle, b.first_publish_year AS year,
         b.ol_rating AS rating, b.ol_want_to_read AS wantToRead, b.pages_median AS pages,
         coalesce(b.cover_url, e.image_url) AS cover,
         [(b)-[:WRITTEN_BY]->(a:Author) | a.name] AS authors,
         e.format AS format, e.price AS price, e.currency AS currency, sortKey`;

export type BookSort = 'title' | 'newest' | 'oldest' | 'rating' | 'wanted';

export const SORTS: Array<{ id: BookSort; label: string }> = [
  { id: 'title', label: 'Title' },
  { id: 'rating', label: 'Highest rated' },
  { id: 'wanted', label: 'Most wanted on Open Library' },
  { id: 'newest', label: 'Newest first' },
  { id: 'oldest', label: 'Oldest first' },
];

// ORDER BY ... DESC puts nulls first in Cypher, so each descending key gets a floor.
const SORT_KEY: Record<BookSort, { expr: string; dir: 'ASC' | 'DESC' }> = {
  title: { expr: 'toLower(b.title)', dir: 'ASC' },
  newest: { expr: 'coalesce(b.first_publish_year, -99999)', dir: 'DESC' },
  oldest: { expr: 'coalesce(b.first_publish_year, 99999)', dir: 'ASC' },
  rating: { expr: 'coalesce(b.ol_rating, -1.0)', dir: 'DESC' },
  wanted: { expr: 'coalesce(b.ol_want_to_read, -1)', dir: 'DESC' },
};

export type BookFilter =
  | { kind: 'all' }
  | { kind: 'term'; label: string; name: string }
  | { kind: 'decade'; decade: number }
  | { kind: 'rating'; rating: number }
  | { kind: 'format'; format: string }
  | { kind: 'pages'; pages: number };

const TERM_PATTERNS: Record<string, string> = {
  Author: '(b)-[:WRITTEN_BY]->(t:Author)',
  Subject: '(b)-[:ABOUT]->(t:Subject)',
  Genre: '(b)-[:IN_GENRE]->(t:Genre)',
  Place: '(b)-[:SET_IN]->(t:Place)',
  Person: '(b)-[:FEATURES]->(t:Person)',
  Era: '(b)-[:SET_DURING]->(t:Era)',
  Series: '(b)-[:PART_OF]->(t:Series)',
  Publisher: '(b)<-[:EDITION_OF]-(:Edition)-[:PUBLISHED_BY]->(t:Publisher)',
};

function filterClause(filter: BookFilter): { match: string; params: Record<string, unknown> } {
  switch (filter.kind) {
    case 'all':
      return { match: 'MATCH (b:Book)', params: {} };
    case 'term': {
      if (filter.label === 'Award') {
        // A book counts when it, or one of its authors, won the award.
        return {
          match: 'MATCH (b:Book)\nWHERE EXISTS { (b)-[:WON]->(:Award {name: $name}) } OR EXISTS { (b)-[:WRITTEN_BY]->(:Author)-[:WON]->(:Award {name: $name}) }',
          params: { name: filter.name },
        };
      }
      const pattern = TERM_PATTERNS[filter.label];
      if (!pattern) throw new Error(`No book filter for label ${filter.label}`);
      // Subjects and places are counted case-insensitively and by map label on
      // the charts, so the drill-down matches the same way.
      const where =
        filter.label === 'Subject'
          ? 'toLower(t.name) = toLower($name)'
          : filter.label === 'Place'
            ? 'coalesce(t.geocoded_label, t.name) = $name OR t.name = $name'
            : 't.name = $name';
      return { match: `MATCH ${pattern}\nWHERE ${where}\nWITH DISTINCT b`, params: { name: filter.name } };
    }
    case 'decade':
      return filter.decade < 1900
        ? { match: 'MATCH (b:Book)\nWHERE b.first_publish_year < 1900', params: {} }
        : { match: 'MATCH (b:Book)\nWHERE b.first_publish_year >= $from AND b.first_publish_year < $to', params: { from: filter.decade, to: filter.decade + 10 } };
    case 'rating':
      return { match: 'MATCH (b:Book)\nWHERE b.ol_rating > 0 AND round(b.ol_rating * 2) / 2.0 = $rating', params: { rating: filter.rating } };
    case 'format':
      return { match: 'MATCH (b:Book)<-[:EDITION_OF]-(f:Edition)\nWHERE f.format = $format\nWITH DISTINCT b', params: { format: filter.format } };
    case 'pages':
      return filter.pages >= 1000
        ? { match: 'MATCH (b:Book)\nWHERE b.pages_median >= 1000', params: {} }
        : { match: 'MATCH (b:Book)\nWHERE b.pages_median >= $from AND b.pages_median < $to', params: { from: Math.max(1, filter.pages), to: filter.pages + 100 } };
  }
}

export function describeFilter(filter: BookFilter): string {
  switch (filter.kind) {
    case 'all':
      return 'All books';
    case 'term':
      return `${filter.label}: ${filter.name}`;
    case 'decade':
      return filter.decade < 1900 ? 'First published before 1900' : `First published in the ${filter.decade}s`;
    case 'rating':
      return `Rated ${filter.rating.toFixed(1)} on Open Library`;
    case 'format':
      return `Format: ${filter.format}`;
    case 'pages':
      return filter.pages >= 1000 ? '1,000 pages or more' : `${filter.pages} to ${filter.pages + 99} pages`;
  }
}

export function listBooks(filter: BookFilter, sort: BookSort, limit: number, skip = 0): Statement {
  const { match, params } = filterClause(filter);
  const { expr, dir } = SORT_KEY[sort];
  return {
    cypher: `${match}\nWITH b, ${expr} AS sortKey\nORDER BY sortKey ${dir}, b.key\nSKIP $skip LIMIT $limit\n${SUMMARY}\nORDER BY sortKey ${dir}, key`,
    params: { ...params, skip, limit },
  };
}

/** Run a statement that returns `BookSummary` rows. Open Library can list one author under several records, so names are deduped here. */
export async function fetchBooks(db: GraphDb, statement: Statement): Promise<BookSummary[]> {
  const result = await run<BookSummary>(db, statement);
  return result.rows.map((book) => ({ ...book, authors: [...new Set(book.authors.filter((a) => typeof a === 'string'))] }));
}

export function countBooks(filter: BookFilter): Statement {
  const { match, params } = filterClause(filter);
  return { cypher: `${match}\nRETURN count(b) AS books`, params };
}

/** `BookSummary` rows for keys, in the order given (search results). */
export function booksByKeys(keys: string[]): Statement {
  return {
    cypher: `UNWIND range(0, size($keys) - 1) AS sortKey\nMATCH (b:Book {key: $keys[sortKey]})\nWITH b, sortKey\n${SUMMARY}\nORDER BY sortKey`,
    params: { keys },
  };
}

export interface BookDetail {
  id: number;
  key: string;
  title: string;
  subtitle: string | null;
  description: string | null;
  firstSentence: string | null;
  year: number | null;
  rating: number | null;
  ratingCount: number | null;
  wantToRead: number | null;
  alreadyRead: number | null;
  pages: number | null;
  editionCount: number | null;
  cover: string | null;
  url: string | null;
  embedded: boolean;
  authors: Array<{ name: string; role: string | null }>;
  subjects: string[];
  genres: string[];
  places: string[];
  people: string[];
  eras: string[];
  series: Array<{ name: string; position: string | null }>;
  awards: string[];
  editions: Array<{ title: string; format: string | null; price: number | null; currency: string | null; url: string | null; publisher: string | null; year: number | null; image: string | null }>;
}

export function bookDetail(key: string): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book {key: $key})
      RETURN id(b) AS id, b.key AS key, b.title AS title, b.subtitle AS subtitle, b.description AS description,
             b.first_sentence AS firstSentence, b.first_publish_year AS year, b.ol_rating AS rating,
             b.ol_rating_count AS ratingCount, b.ol_want_to_read AS wantToRead, b.ol_already_read AS alreadyRead,
             b.pages_median AS pages, b.edition_count AS editionCount, b.cover_url AS cover, b.url AS url,
             b.embedding IS NOT NULL AS embedded,
             [(b)-[w:WRITTEN_BY]->(a:Author) | {name: a.name, role: w.role}] AS authors,
             [(b)-[:ABOUT]->(s:Subject) | s.name] AS subjects,
             [(b)-[:IN_GENRE]->(g:Genre) | g.name] AS genres,
             [(b)-[:SET_IN]->(p:Place) | p.name] AS places,
             [(b)-[:FEATURES]->(c:Person) | c.name] AS people,
             [(b)-[:SET_DURING]->(t:Era) | t.name] AS eras,
             [(b)-[r:PART_OF]->(x:Series) | {name: x.name, position: r.position}] AS series,
             [(b)-[:WON]->(aw:Award) | aw.name] AS awards,
             [(b)<-[:EDITION_OF]-(e:Edition) | {title: e.title, format: e.format, price: e.price, currency: e.currency,
               url: e.url, year: e.publish_year, image: e.image_url,
               publisher: head([(e)-[:PUBLISHED_BY]->(pub:Publisher) | pub.name])}] AS editions`,
    params: { key },
  };
}

export async function getBook(db: GraphDb, key: string): Promise<BookDetail | null> {
  const book = (await run<BookDetail>(db, bookDetail(key))).rows[0];
  if (!book) return null;
  // One author under several Open Library records shows once.
  const seen = new Set<string>();
  const authors = book.authors.filter((a) => typeof a.name === 'string' && !seen.has(a.name) && seen.add(a.name));
  const unique = (xs: string[]) => [...new Set(xs.filter((x) => typeof x === 'string'))].sort((a, b) => a.localeCompare(b));
  return { ...book, authors, subjects: unique(book.subjects), genres: unique(book.genres), places: unique(book.places), people: unique(book.people), eras: unique(book.eras), awards: unique(book.awards) };
}
