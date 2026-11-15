import { describe, expect, it } from 'vitest';
import { checkReadOnly, stripLiterals, writeOperators } from '../src/ai/text2cypher/guard';
import { dropExtraBraces, ensureLimit, extractCypher, restoreNumbers } from '../src/ai/text2cypher/prepare';
import { sampleDb } from './helpers/engine';

describe('checkReadOnly', () => {
  const ok = (q: string) => expect(checkReadOnly(q), q).toEqual({ ok: true });
  const no = (q: string, reason?: RegExp) => {
    const verdict = checkReadOnly(q);
    expect(verdict.ok, q).toBe(false);
    if (reason) expect(verdict.reason).toMatch(reason);
  };

  it('lets reads through', () => {
    ok('MATCH (b:Book) RETURN b.title LIMIT 5');
    ok('MATCH (b:Book) RETURN b.title;');
    ok("MATCH (b:Book) WHERE b.title = 'CREATE; DELETE' RETURN b // SET x = 1");
    ok('MATCH (b:Book) /* MERGE */ RETURN b.`set` AS x, b.set, {set: 1, create: 2} AS m');
    ok('MATCH (b:Book) CALL (b) { MATCH (b)-[:WRITTEN_BY]->(a) RETURN count(a) AS n } RETURN b.title, n');
    ok('MATCH (b:Book) CALL { WITH b MATCH (b)-->(x) RETURN count(x) AS n } RETURN n');
    ok("CALL db.index.fulltext.queryNodes('book_text', 'mars') YIELD node, score RETURN node.title, score");
    ok('CALL db.labels()');
    ok('MATCH (b:Book) SEARCH b IN (FULLTEXT INDEX book_text FOR $t LIMIT 5) SCORE AS score RETURN b.title, score');
    ok('MATCH (b:Book) RETURN b.title ORDER BY b.title SKIP 5 LIMIT 5');
    ok('MATCH (n:Set) RETURN n.offset, $set AS p');
    ok('SHOW INDEXES YIELD name, type RETURN name, type');
  });

  it('refuses writes, schema changes, several statements and unknown procedures', () => {
    no('CREATE (n:Book)', /CREATE/);
    no('MATCH (b:Book) SET b.title = "x"', /SET/);
    no('match (b:Book) set b.title = "x"', /SET/);
    no('MATCH (b:Book) DETACH DELETE b');
    no('MATCH (b:Book) REMOVE b.title');
    no('MERGE (n:Tag {name: "x"})');
    no('DROP INDEX book_text');
    no('MATCH (b:Book) FOREACH (x IN [1] | SET b.y = x)');
    no("LOAD CSV FROM 'https://example.com/x.csv' AS row RETURN row");
    no('MATCH (b:Book) RETURN b; MATCH (n) DETACH DELETE n', /one statement/);
    no('CALL apoc.periodic.iterate("MATCH (n) RETURN n", "DETACH DELETE n", {})', /apoc/);
    no('CALL db.createLabel("X")');
    no('MATCH (b:Book) CALL (b) { SET b.x = 1 } IN TRANSACTIONS');
    no('', /empty/);
    no('  // nothing here', /empty/);
  });

  it('is not fooled by quotes, escapes and comments', () => {
    no("MATCH (b:Book) WHERE b.title = 'it\\'s' SET b.x = 1");
    no('MATCH (b:Book) WHERE b.title = "a" /* " */ DELETE b');
    no("MATCH (b {`odd``name`: 1}) // '\n DELETE b");
    expect(stripLiterals("a 'b' `c` /* d */ e // f")).toBe("a ' ' ` `         e     ");
  });
});

describe('writeOperators', () => {
  it('reads the EXPLAIN plan as the engine sees it', async () => {
    const db = await sampleDb();
    const plan = async (q: string) => (await db.query(`EXPLAIN ${q}`)).plan;
    expect(writeOperators(await plan('MATCH (b:Book)-[:WRITTEN_BY]->(a) RETURN a.name, count(b) AS n ORDER BY n DESC LIMIT 3'))).toEqual([]);
    expect(writeOperators(await plan("MATCH (b:Book) SEARCH b IN (FULLTEXT INDEX book_text FOR 'mars' LIMIT 3) SCORE AS s RETURN b.title, s"))).toEqual([]);
    expect(writeOperators(await plan("MATCH (b:Book {key: 'x'}) RETURN b"))).toEqual([]);
    expect(writeOperators(await plan('MATCH (b:Book) SET b.x = 1')).length).toBeGreaterThan(0);
    expect(writeOperators(await plan('CREATE (n:Foo)')).length).toBeGreaterThan(0);
    expect(writeOperators(await plan('MATCH (b:Book) DETACH DELETE b')).length).toBeGreaterThan(0);
    expect(writeOperators(await plan('MERGE (n:Foo {a: 1})')).length).toBeGreaterThan(0);
    expect(writeOperators(await plan('MATCH (b:Book) REMOVE b.title')).length).toBeGreaterThan(0);
    expect(writeOperators(null)).toEqual([]);
    // EXPLAIN never ran the writes.
    expect((await db.query('MATCH (b:Book) RETURN count(b) AS n, count(b.x) AS x')).rows[0]).toEqual({ n: 6, x: 0 });
  });
});

describe('extractCypher / ensureLimit', () => {
  it('pulls the statement out of a chatty reply', () => {
    expect(extractCypher('```cypher\nMATCH (b:Book) RETURN b.title;\n```')).toBe('MATCH (b:Book) RETURN b.title');
    expect(extractCypher('Here is the query:\n\nMATCH (b:Book)\nRETURN b.title\n\nThis returns every title.')).toBe('MATCH (b:Book)\nRETURN b.title');
    expect(extractCypher('<think>MATCH is needed</think>\nMATCH (b:Book)\n\nWHERE b.x = 1\nRETURN b')).toBe('MATCH (b:Book)\n\nWHERE b.x = 1\nRETURN b');
    expect(extractCypher('<think>never closed MATCH (x)')).toBe('');
    expect(extractCypher('MATCH (a) RETURN a ```')).toBe('MATCH (a) RETURN a');
  });

  it('adds a LIMIT only when the final RETURN has none', () => {
    expect(ensureLimit('MATCH (b:Book) RETURN b.title')).toBe('MATCH (b:Book) RETURN b.title\nLIMIT 50');
    expect(ensureLimit('MATCH (b:Book) RETURN b.title LIMIT 5')).toBe('MATCH (b:Book) RETURN b.title LIMIT 5');
    expect(ensureLimit('MATCH (b:Book) WITH b LIMIT 5 RETURN b.title', 20)).toBe('MATCH (b:Book) WITH b LIMIT 5 RETURN b.title\nLIMIT 20');
    expect(ensureLimit("MATCH (b:Book) RETURN b.title AS `LIMIT 5`, 'limit 3' AS x")).toMatch(/\nLIMIT 50$/);
    expect(ensureLimit('CALL db.labels()')).toBe('CALL db.labels()');
  });
});

describe('restoreNumbers', () => {
  it('puts back a number that lost its last digit', () => {
    expect(restoreNumbers('Which books were published before 2000?', 'MATCH (b:Book)\nWHERE b.first_publish_year < 200\nRETURN b.title')).toEqual({
      cypher: 'MATCH (b:Book)\nWHERE b.first_publish_year < 2000\nRETURN b.title',
      fixes: ['The question says 2000; the statement had 200.'],
    });
    const two = restoreNumbers('more than 400 pages and before 1950', 'MATCH (b:Book) WHERE b.pages_median > 40 AND b.first_publish_year < 195 RETURN b.title LIMIT 10');
    expect(two.cypher).toBe('MATCH (b:Book) WHERE b.pages_median > 400 AND b.first_publish_year < 1950 RETURN b.title LIMIT 10');
    expect(two.fixes).toHaveLength(2);
  });

  it('leaves numbers alone when they are plausibly meant', () => {
    const same = (question: string, cypher: string) => expect(restoreNumbers(question, cypher), cypher).toEqual({ cypher, fixes: [] });
    same('books after 2000', 'MATCH (b:Book) WHERE b.first_publish_year > 2000 RETURN b.title');
    // The question says both numbers.
    same('books after 2000 with at least 200 pages', 'MATCH (b:Book) WHERE b.first_publish_year > 2000 AND b.pages_median >= 200 RETURN b.title');
    // A LIMIT is the model's own number, as are decimals, parameters and names.
    same('the top 250 books', 'MATCH (b:Book) RETURN b.title LIMIT 25');
    same('rated above 4.25', 'MATCH (b:Book) WHERE b.ol_rating > 4.2 RETURN b.title');
    same('books from 1984', "MATCH (b:Book) WHERE b.title = '198' OR b.x198 = $p198 RETURN b.title");
    // Two-digit question numbers are too short to be sure about.
    same('under 15 dollars', 'MATCH (e:Edition) WHERE e.price < 1 RETURN e.title');
    // Ambiguous: two question numbers share the prefix.
    same('between 1980 and 1989', 'MATCH (b:Book) WHERE b.first_publish_year > 198 RETURN b.title');
  });
});

describe('dropExtraBraces', () => {
  it('removes a doubled closing brace when the braces do not balance', () => {
    expect(dropExtraBraces("MATCH (b:Book)-[:SET_IN]->(p:Place {name: 'Montana'}}) RETURN b.title")).toEqual({
      cypher: "MATCH (b:Book)-[:SET_IN]->(p:Place {name: 'Montana'}) RETURN b.title",
      fixes: ['Removed a doubled closing brace.'],
    });
    expect(dropExtraBraces('MATCH (a {x: 1}})-[:R]->(b {y: 2}}) RETURN a').cypher).toBe('MATCH (a {x: 1})-[:R]->(b {y: 2}) RETURN a');
  });

  it('leaves balanced statements alone, nested maps and braces in strings included', () => {
    for (const q of [
      "MATCH (p:Place {name: 'Montana'}) RETURN p",
      'RETURN {a: {b: 1}} AS m',
      "MATCH (b:Book) WHERE b.title = 'a}}b' RETURN b",
      'MATCH (b:Book) WHERE EXISTS { MATCH (b)-[:ABOUT]->(s {name: "x"}) } RETURN b',
      'MATCH (b:Book RETURN b }',
    ]) {
      expect(dropExtraBraces(q), q).toEqual({ cypher: q, fixes: [] });
    }
  });
});
