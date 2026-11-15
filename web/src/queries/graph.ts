// Cypher behind the Graph tab. Every statement returns nodes and
// relationships (or paths); `extractGraph` turns the rows into what NVL draws.

import { cypher, type Statement } from './statement';

/** A node's neighbours, most connected last so a hub does not crowd out the rest. */
export function expand(nodeId: number, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (n)-[r]-(m)
      WHERE id(n) = $id
      RETURN n, r, m
      LIMIT $limit`,
    params: { id: nodeId, limit },
  };
}

export function degree(nodeId: number): Statement {
  return { cypher: 'MATCH (n) WHERE id(n) = $id RETURN COUNT { (n)--() } AS degree', params: { id: nodeId } };
}

/** A book with everything attached to it (subjects capped: a book can have a hundred). */
export function bookNeighborhood(key: string, limit = 80): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book {key: $key})-[r]-(m)
      RETURN b, r, m
      LIMIT $limit`,
    params: { key, limit },
  };
}

/** The same, for a book known by its title (the graph's "find a node"). */
export function bookNeighborhoodByTitle(title: string, limit = 80): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book {title: $title})-[r]-(m)
      RETURN b, r, m
      LIMIT $limit`,
    params: { title, limit },
  };
}

/** Books attached to one term (an author, a subject, a place, ...). */
export function termNeighborhood(label: string, name: string, limit = 60): Statement {
  if (!/^[A-Za-z]+$/.test(label)) throw new Error(`bad label ${label}`);
  return {
    cypher: cypher`
      MATCH (t:${label} {name: $name})-[r]-(m)
      RETURN t, r, m
      LIMIT $limit`,
    params: { name, limit },
  };
}

/** The relationships among nodes already on the canvas (after an expansion adds nodes). */
export function relationshipsAmong(ids: number[]): Statement {
  return {
    cypher: cypher`
      MATCH (a)-[r]->(b)
      WHERE id(a) IN $ids AND id(b) IN $ids
      RETURN r`,
    params: { ids },
  };
}

export interface GraphPreset {
  id: string;
  title: string;
  description: string;
  statement: Statement;
}

export const presets: GraphPreset[] = [
  {
    id: 'authors',
    title: 'Books and their authors',
    description: 'The wishlist as a bipartite graph: the authors with the most books, and those books.',
    statement: {
      cypher: cypher`
        MATCH (a:Author)<-[:WRITTEN_BY]-(:Book)
        WITH a, count(*) AS books
        ORDER BY books DESC, a.name
        LIMIT 25
        MATCH p = (a)<-[:WRITTEN_BY]-(:Book)
        RETURN p
        LIMIT 150`,
    },
  },
  {
    id: 'genres',
    title: 'Genres, series and awards',
    description: 'What Wikidata knows: books by genre and series, and the awards they won.',
    statement: {
      cypher: cypher`
        MATCH p = (b:Book)-[:IN_GENRE|PART_OF|WON]->(x)
        RETURN p
        LIMIT 200`,
    },
  },
  {
    id: 'places',
    title: 'Where books are set',
    description: 'The places with the most books, and the books set there.',
    statement: {
      cypher: cypher`
        MATCH (pl:Place)<-[:SET_IN]-(:Book)
        WITH pl, count(*) AS books
        ORDER BY books DESC, pl.name
        LIMIT 20
        MATCH p = (pl)<-[:SET_IN]-(:Book)
        RETURN p
        LIMIT 150`,
    },
  },
  {
    id: 'shared-subjects',
    title: 'Books linked by shared subjects',
    description: 'Subjects that connect two or more books, catalogue tags left out.',
    statement: {
      cypher: cypher`
        MATCH (s:Subject)<-[:ABOUT]-(:Book)
        WHERE NOT toLower(s.name) IN ['fiction', 'nonfiction', 'general', 'new york times bestseller', 'new york times reviewed']
          AND NOT s.name CONTAINS ':'
        WITH s, count(*) AS books
        WHERE books >= 2
        ORDER BY books DESC, s.name
        LIMIT 15
        MATCH p = (s)<-[:ABOUT]-(:Book)
        RETURN p
        LIMIT 200`,
    },
  },
  {
    id: 'author-origins',
    title: 'Authors, birthplaces and countries',
    description: 'Where the authors come from (from Wikidata).',
    statement: {
      cypher: cypher`
        MATCH p = (a:Author)-[:BORN_IN|CITIZEN_OF]->(x)
        RETURN p
        LIMIT 150`,
    },
  },
  {
    id: 'wishlist',
    title: 'The wishlist itself',
    description: 'The list, its first items, and the books behind them.',
    statement: {
      cypher: cypher`
        MATCH p = (w:Wishlist)-[c:CONTAINS]->(i:Item)
        WITH p, i ORDER BY c.position LIMIT 40
        OPTIONAL MATCH q = (i)-[:EDITION_OF]->(:Book)
        RETURN p, q`,
    },
  },
];
