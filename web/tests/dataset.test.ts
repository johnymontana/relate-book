import { describe, expect, it } from 'vitest';
import { DatasetError, datasetId, loadDataset, nodeStatement, parseDataset, relationshipStatement, type Dataset } from '../src/engine/dataset';
import { extractGraph, ident } from '../src/engine/wire';
import { emptyDb, sampleDataset, sampleDb } from './helpers/engine';

describe('parseDataset', () => {
  it('reads the bundled sample', () => {
    const d = sampleDataset();
    expect(d.name).toBe('Book List');
    expect(d.counts).toEqual({ nodes: 311, relationships: 344 });
    expect(d.schema.constraints).toHaveLength(13);
  });

  it('rejects non-JSON, other JSON and other versions with a usable message', () => {
    expect(() => parseDataset('nope')).toThrow(DatasetError);
    expect(() => parseDataset('{"hello": 1}')).toThrow(/not a Relate Books dataset/);
    expect(() => parseDataset(JSON.stringify({ ...sampleDataset(), version: 99 }))).toThrow(/version 99/);
  });

  it('refuses schema statements that are not CREATE CONSTRAINT / INDEX', () => {
    const d = sampleDataset();
    const evil: Dataset = { ...d, schema: { ...d.schema, indexes: ['MATCH (n) DETACH DELETE n'] } };
    expect(() => parseDataset(JSON.stringify(evil))).toThrow(/not a CREATE/);
    const chained: Dataset = { ...d, schema: { ...d.schema, indexes: ['CREATE INDEX x FOR (n:A) ON (n.a); MATCH (n) DETACH DELETE n'] } };
    expect(() => parseDataset(JSON.stringify(chained))).toThrow(/not a CREATE/);
  });
});

describe('statements', () => {
  it('quote labels, types and typed keys', () => {
    expect(ident('Book')).toBe('Book');
    expect(ident('odd label`x')).toBe('`odd label``x`');
    expect(nodeStatement({ labels: ['Item', 'Edition'], typed: {}, rows: [] })).toBe(
      'UNWIND $rows AS row CREATE (n:Item:Edition) SET n = row[1] RETURN row[0] AS exportId, id(n) AS id',
    );
    expect(nodeStatement({ labels: ['Place'], typed: { location: { kind: 'point' } }, rows: [] })).toContain(', n.location = point(row[2].location)');
    expect(nodeStatement({ labels: ['Book'], typed: { embedding: { kind: 'vector', coordinateType: 'FLOAT32', dimensions: 384 } }, rows: [] })).toContain(
      'n.embedding = vector(row[2].embedding, 384, FLOAT32)',
    );
    expect(relationshipStatement({ type: 'WRITTEN BY', typed: {}, rows: [] })).toContain('CREATE (a)-[r:`WRITTEN BY`]->(b)');
  });
});

describe('loadDataset', () => {
  it('loads every node and relationship of the sample, with typed values restored', async () => {
    const db = await sampleDb();
    expect(db.summary).toMatchObject({ nodes: 311, relationships: 344 });

    const counts = await db.query<{ label: string; n: number }>('MATCH (n) UNWIND labels(n) AS label RETURN label, count(*) AS n ORDER BY label');
    expect(Object.fromEntries(counts.rows.map((r) => [r.label, r.n]))).toEqual({
      Author: 8, Award: 58, Book: 6, Country: 2, Edition: 6, Era: 4, Genre: 3, Item: 6, Person: 9, Place: 34, Publisher: 6, Series: 1, Subject: 173, Wishlist: 1,
    });
    expect((await db.query('MATCH ()-[r]->() RETURN count(r) AS n')).rows[0]).toEqual({ n: 344 });

    const typed = await db.query(
      'MATCH (p:Place) WHERE p.location IS NOT NULL WITH count(p) AS located, collect(valueType(p.location))[0] AS pointType MATCH (w:Wishlist) RETURN located, pointType, valueType(w.imported_at) AS stamp',
    );
    expect(typed.rows[0]).toEqual({ located: 19, pointType: 'POINT NOT NULL', stamp: 'ZONED DATETIME NOT NULL' });
  });

  it('keeps relationships attached to the right nodes and their properties', async () => {
    const db = await sampleDb();
    const authors = await db.query<{ title: string; authors: string[] }>(
      "MATCH (b:Book)-[:WRITTEN_BY]->(a:Author) WITH b, a ORDER BY a.name RETURN b.title AS title, collect(a.name) AS authors ORDER BY title",
    );
    const byTitle = Object.fromEntries(authors.rows.map((r) => [r.title, r.authors]));
    expect(byTitle['Project Hail Mary']).toEqual(['Andy Weir']);
    expect(byTitle['The Left Hand of Darkness']).toContain('Ursula K. Le Guin');
    const contains = await db.query('MATCH (:Wishlist)-[c:CONTAINS]->(i:Item) RETURN c.position AS position, i.title AS title ORDER BY position LIMIT 1');
    expect(contains.rows[0].position).toBe(1);
  });

  it('recreates the constraints and indexes of the store', async () => {
    const db = await sampleDb();
    const indexes = await db.query<{ name: string; type: string }>('SHOW INDEXES YIELD name, type RETURN name, type');
    const names = new Map(indexes.rows.map((r) => [r.name, r.type]));
    expect(names.get('book_text')).toBe('FULLTEXT');
    expect(names.get('place_location')).toBe('POINT');
    expect(names.get('book_key')).toBe('RANGE');
    expect(names.get('book_embedding')).toBe('VECTOR');
    expect(names.get('term_text')).toBe('FULLTEXT');
    await expect(db.query("CREATE (:Book {key: '/works/OL21745884W'})")).rejects.toThrow();
  });

  it('reports progress through every phase', async () => {
    const db = await emptyDb();
    const phases: string[] = [];
    loadDataset(sampleDataset(), db.exec, (p) => {
      if (phases[phases.length - 1] !== p.phase) phases.push(p.phase);
    });
    expect(phases).toEqual(['schema', 'nodes', 'relationships', 'indexes']);
  });

  it('fails cleanly on a relationship to a missing node', async () => {
    const db = await emptyDb();
    const d = sampleDataset();
    d.relationships[0].rows.push([999_999, 0]);
    expect(() => loadDataset(d, db.exec)).toThrow(/not in the dataset/);
  });

  it('gives a dataset a stable id', () => {
    const d = sampleDataset();
    expect(datasetId(d)).toBe(`Book List|${d.exportedAt}|311|344`);
  });
});

describe('extractGraph', () => {
  it('finds nodes and relationships in rows, paths and collections, each once', async () => {
    const db = await sampleDb();
    const result = await db.query("MATCH p = (b:Book {title: 'Project Hail Mary'})-[:WRITTEN_BY]->(a) RETURN p, b, collect(a) AS authors");
    const graph = extractGraph(result.rows);
    expect(graph.nodes.map((n) => n.labels[0]).sort()).toEqual(['Author', 'Book']);
    expect(graph.relationships).toHaveLength(1);
    expect(graph.relationships[0].type).toBe('WRITTEN_BY');
  });
});
