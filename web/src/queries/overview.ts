// Cypher behind the Overview tab. No React here; each chart is a statement
// plus how to read its rows.

import { ident } from '../engine/wire';
import { SUBJECT_STOPLIST } from '../search/embeddingText';
import { cypher, type Statement } from './statement';

export interface LibraryTotals {
  books: number;
  rated: number;
  avgRating: number | null;
  pages: number | null;
  earliest: number | null;
  latest: number | null;
}

export const totals: Statement = {
  cypher: cypher`
    MATCH (b:Book)
    WITH b, CASE WHEN b.ol_rating > 0 THEN b.ol_rating END AS rating
    RETURN count(b) AS books, count(rating) AS rated, avg(rating) AS avgRating,
           sum(b.pages_median) AS pages, min(b.first_publish_year) AS earliest, max(b.first_publish_year) AS latest`,
};

export const labelCounts: Statement = {
  cypher: cypher`
    MATCH (n)
    UNWIND labels(n) AS label
    RETURN label, count(*) AS n
    ORDER BY n DESC, label`,
};

export const relationshipCounts: Statement = {
  cypher: cypher`
    MATCH (a)-[r]->(b)
    RETURN labels(a)[0] AS from, type(r) AS type, labels(b)[size(labels(b)) - 1] AS to, count(*) AS n
    ORDER BY n DESC, type`,
};

export const presentLabels: Statement = { cypher: 'CALL db.labels()' };
export const presentTypes: Statement = { cypher: 'CALL db.relationshipTypes()' };

/** A first look at one label, for the Query tab. */
export function labelSample(label: string): string {
  return `MATCH (n:${ident(label)})\nRETURN n\nLIMIT 25`;
}

/** A first look at one relationship type between two labels, for the Query tab. */
export function relationshipSample(from: string, type: string, to: string): string {
  return `MATCH p = (:${ident(from)})-[:${ident(type)}]->(:${ident(to)})\nRETURN p\nLIMIT 50`;
}

export const listValue: Statement = {
  cypher: cypher`
    MATCH (:Wishlist)-[:CONTAINS]->(i:Item)
    WHERE i.price IS NOT NULL
    RETURN coalesce(i.currency, 'USD') AS currency, sum(i.price) AS total, count(i) AS priced
    ORDER BY priced DESC`,
};

export const placesLocated: Statement = {
  cypher: cypher`
    MATCH (p:Place)
    RETURN count(p) AS places, count(p.location) AS located, count(DISTINCT p.geocoded_label) AS pins`,
};

export type DrillLabel = 'Author' | 'Subject' | 'Genre' | 'Place' | 'Award' | 'Publisher' | 'Series';

export interface ChartSpec {
  id: string;
  title: string;
  /** What one row counts, for the axis and the tooltip ("books", "editions"). */
  unit: string;
  /** `ranked`: nominal categories, largest first. `bins`: an ordered numeric scale. */
  kind: 'ranked' | 'bins';
  statement: Statement;
  /** Row keys for the category and the value. */
  category: string;
  value: string;
  /** Clicking a bar opens the books behind it. */
  drill?: { label: DrillLabel } | { filter: 'decade' | 'rating' | 'format' | 'pages' };
  note?: string;
}

const TOP = 12;

export const charts: ChartSpec[] = [
  {
    id: 'decades',
    title: 'Books by decade first published',
    unit: 'books',
    kind: 'bins',
    category: 'decade',
    value: 'books',
    drill: { filter: 'decade' },
    note: 'Everything before 1900 shares the first bar.',
    statement: {
      cypher: cypher`
        MATCH (b:Book)
        WHERE b.first_publish_year IS NOT NULL
        WITH CASE WHEN b.first_publish_year < 1900 THEN 1890 ELSE (b.first_publish_year / 10) * 10 END AS decade
        RETURN decade, count(*) AS books
        ORDER BY decade`,
    },
  },
  {
    id: 'ratings',
    title: 'Open Library rating',
    unit: 'books',
    kind: 'bins',
    category: 'rating',
    value: 'books',
    drill: { filter: 'rating' },
    note: 'Average reader rating, rounded to the nearest half star.',
    statement: {
      cypher: cypher`
        MATCH (b:Book)
        WHERE b.ol_rating > 0
        RETURN round(b.ol_rating * 2) / 2.0 AS rating, count(*) AS books
        ORDER BY rating`,
    },
  },
  {
    id: 'authors',
    title: 'Authors with the most books',
    unit: 'books',
    kind: 'ranked',
    category: 'author',
    value: 'books',
    drill: { label: 'Author' },
    note: 'Open Library sometimes has several records for one author; books are counted once per name.',
    statement: {
      cypher: cypher`
        MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)
        WITH a.name AS author, count(DISTINCT b) AS books
        RETURN author, books
        ORDER BY books DESC, author
        LIMIT $top`,
      params: { top: TOP },
    },
  },
  {
    id: 'subjects',
    title: 'Most common subjects',
    unit: 'books',
    kind: 'ranked',
    category: 'subject',
    value: 'books',
    drill: { label: 'Subject' },
    note: 'Spellings that differ only in case are counted together; catalogue tags such as "Fiction" are left out.',
    statement: {
      cypher: cypher`
        MATCH (b:Book)-[:ABOUT]->(s:Subject)
        WHERE NOT toLower(s.name) IN $stoplist AND NOT s.name CONTAINS ':'
        WITH toLower(s.name) AS subject, count(DISTINCT b) AS books
        RETURN subject, books
        ORDER BY books DESC, subject
        LIMIT $top`,
      params: { top: TOP, stoplist: [...SUBJECT_STOPLIST] },
    },
  },
  {
    id: 'places',
    title: 'Where the books are set',
    unit: 'books',
    kind: 'ranked',
    category: 'place',
    value: 'books',
    drill: { label: 'Place' },
    statement: {
      cypher: cypher`
        MATCH (b:Book)-[:SET_IN]->(p:Place)
        WITH coalesce(p.geocoded_label, p.name) AS place, count(DISTINCT b) AS books
        RETURN place, books
        ORDER BY books DESC, place
        LIMIT $top`,
      params: { top: TOP },
    },
  },
  {
    id: 'formats',
    title: 'Editions by format',
    unit: 'editions',
    kind: 'ranked',
    category: 'format',
    value: 'editions',
    drill: { filter: 'format' },
    statement: {
      cypher: cypher`
        MATCH (e:Edition)
        WHERE e.format IS NOT NULL
        RETURN e.format AS format, count(*) AS editions
        ORDER BY editions DESC, format
        LIMIT 8`,
    },
  },
  {
    id: 'pages',
    title: 'Length in pages',
    unit: 'books',
    kind: 'bins',
    category: 'pages',
    value: 'books',
    drill: { filter: 'pages' },
    note: 'Median page count across editions, in bands of 100; 1,000 and over share the last bar.',
    statement: {
      cypher: cypher`
        MATCH (b:Book)
        WHERE b.pages_median IS NOT NULL AND b.pages_median > 0
        WITH CASE WHEN b.pages_median >= 1000 THEN 1000 ELSE (b.pages_median / 100) * 100 END AS pages
        RETURN pages, count(*) AS books
        ORDER BY pages`,
    },
  },
  {
    id: 'awards',
    title: 'Awards won by books and their authors',
    unit: 'winners',
    kind: 'ranked',
    category: 'award',
    value: 'winners',
    drill: { label: 'Award' },
    statement: {
      cypher: cypher`
        MATCH (w)-[:WON]->(a:Award)
        RETURN a.name AS award, count(DISTINCT w) AS winners
        ORDER BY winners DESC, award
        LIMIT $top`,
      params: { top: TOP },
    },
  },
];
