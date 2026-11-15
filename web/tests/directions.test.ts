import { describe, expect, it } from 'vitest';
import { checkDirections } from '../src/ai/text2cypher/directions';
import { EXAMPLES } from '../src/ai/text2cypher/examples';
import * as graph from '../src/queries/graph';
import { charts } from '../src/queries/overview';
import { sampleDb } from './helpers/engine';

describe('checkDirections', () => {
  it('leaves correct statements alone', () => {
    for (const q of [
      'MATCH (b:Book)-[:WRITTEN_BY]->(a:Author) RETURN a.name',
      'MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book) RETURN a.name',
      'MATCH (b:Book)-[r]-(x) RETURN b, r, x',
      'MATCH (b:Book)-[:ABOUT]-(s:Subject) RETURN s.name',
      'MATCH (:Wishlist)-[:CONTAINS]->(i:Edition)-[:EDITION_OF]->(b:Book) RETURN b.title',
      'MATCH (e:Item)-[:PUBLISHED_BY]->(p:Publisher) RETURN p.name',
      'MATCH (w)-[:WON]->(a:Award) RETURN a.name',
      'MATCH p = (b:Book)-[:IN_GENRE|PART_OF|WON]->(x) RETURN p',
      'MATCH (a)-[:KNOWS]->(b:Author) RETURN a',
      'MATCH (b:Book)-[:WRITTEN_BY*1..2]->(a:Author) RETURN a',
    ]) {
      expect(checkDirections(q), q).toEqual({ cypher: q, fixes: [], problems: [] });
    }
  });

  it('flips a relationship that is written backwards', () => {
    const out = checkDirections("MATCH (a:Author)-[:WRITTEN_BY]->(b:Book)\nWHERE toLower(a.name) CONTAINS 'le guin'\nRETURN b.title AS title");
    expect(out.cypher).toBe("MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)\nWHERE toLower(a.name) CONTAINS 'le guin'\nRETURN b.title AS title");
    expect(out.fixes).toEqual(['WRITTEN_BY runs (:Book)-[:WRITTEN_BY]->(:Author); the arrow was reversed.']);
    expect(out.problems).toEqual([]);
  });

  it('flips each backwards link of a chain, keeps variables and properties, and resolves labels from earlier bindings', () => {
    const chain = checkDirections('MATCH (b:Book)-[:EDITION_OF]->(e:Edition)-[:PUBLISHED_BY]->(p:Publisher) RETURN p.name');
    expect(chain.cypher).toBe('MATCH (b:Book)<-[:EDITION_OF]-(e:Edition)-[:PUBLISHED_BY]->(p:Publisher) RETURN p.name');
    const left = checkDirections('MATCH (b:Book)<-[w:WRITTEN_BY {role: "Author"}]-(a:Author) RETURN w.role');
    expect(left.cypher).toBe('MATCH (b:Book)-[w:WRITTEN_BY {role: "Author"}]->(a:Author) RETURN w.role');
    const later = checkDirections('MATCH (a:Author) WHERE a.name = "X" MATCH (a)-[:WRITTEN_BY]->(b:Book) RETURN b.title');
    expect(later.cypher).toBe('MATCH (a:Author) WHERE a.name = "X" MATCH (a)<-[:WRITTEN_BY]-(b:Book) RETURN b.title');
    const two = checkDirections('MATCH (c:Country)-[:CITIZEN_OF]->(a:Author)-[:WRITTEN_BY]->(b:Book) RETURN b.title');
    expect(two.cypher).toBe('MATCH (c:Country)<-[:CITIZEN_OF]-(a:Author)<-[:WRITTEN_BY]-(b:Book) RETURN b.title');
    expect(two.fixes).toHaveLength(2);
  });

  it('reports a relationship between labels the model does not connect', () => {
    const out = checkDirections('MATCH (a:Author)-[:ABOUT]->(s:Subject) RETURN s.name');
    expect(out.cypher).toBe('MATCH (a:Author)-[:ABOUT]->(s:Subject) RETURN s.name');
    expect(out.problems).toEqual(['[:ABOUT] does not connect Author to Subject. In this graph: (:Book)-[:ABOUT]->(:Subject).']);
  });

  it('is not confused by strings and comments', () => {
    const q = "MATCH (b:Book) WHERE b.title = '(a:Author)-[:WRITTEN_BY]->(b:Book)' RETURN b // (a:Author)-[:WRITTEN_BY]->(b:Book)";
    expect(checkDirections(q).cypher).toBe(q);
  });

  it('agrees with every statement the app itself ships', async () => {
    const db = await sampleDb();
    const shipped = [...EXAMPLES.map((e) => e.cypher), ...charts.map((c) => c.statement.cypher), ...graph.presets.map((p) => p.statement.cypher)];
    for (const q of shipped) expect(checkDirections(q), q).toMatchObject({ cypher: q, fixes: [], problems: [] });
    // And a flipped statement really does find what the backwards one missed.
    const wrong = "MATCH (a:Author)-[:WRITTEN_BY]->(b:Book) WHERE a.name = 'Andy Weir' RETURN b.title AS title";
    expect((await db.query(wrong)).rows).toEqual([]);
    expect((await db.query(checkDirections(wrong).cypher)).rows).toEqual([{ title: 'Project Hail Mary' }]);
  });
});
