import { beforeAll, describe, expect, it } from 'vitest';
import { StubLlm } from '../src/ai/stubLlm';
import { EXAMPLES } from '../src/ai/text2cypher/examples';
import { buildMessages, linkNames, textToCypher, valueHints, type PipelineEvent } from '../src/ai/text2cypher/pipeline';
import { retrieveExamples } from '../src/ai/text2cypher/retrieve';
import { schemaText, systemPrompt, valuesText } from '../src/ai/text2cypher/schemaPrompt';
import { labelProperties, misplacedProperties, validateCypher } from '../src/ai/text2cypher/validate';
import { LABELS, RELATIONSHIPS } from '../src/engine/schema';
import { StubEmbedder } from '../src/search/stubEmbedder';
import { sampleDb, type TestDb } from './helpers/engine';

let db: TestDb;
beforeAll(async () => {
  db = await sampleDb();
});

describe('schema prompt', () => {
  it('describes the labels and relationships that exist in the store', async () => {
    const labels = new Set((await db.query<{ label: string }>('CALL db.labels()')).rows.map((r) => r.label));
    const types = new Set((await db.query<{ relationshipType: string }>('CALL db.relationshipTypes()')).rows.map((r) => r.relationshipType));
    // The model in schema.ts covers the store, and names nothing the store lacks.
    for (const label of labels) expect(LABELS.map((l) => l.label), label).toContain(label);
    for (const type of types) expect(RELATIONSHIPS.map((r) => r.type), type).toContain(type);
    const text = schemaText(labels, types);
    expect(text).toContain('(:Book {title, subtitle, description, first_publish_year: INTEGER');
    expect(text).toContain('(:Book)-[:WRITTEN_BY {role}]->(:Author)');
    expect(text).toContain("(:Author)-[:WON]->(:Award) - an author's own awards, a direct relationship");
    expect(schemaText(new Set(['Book', 'Author']), new Set(['WRITTEN_BY']))).not.toContain('Subject');
    // The whole system prompt has to fit a small context window with room for examples.
    expect(systemPrompt(text).length).toBeLessThan(7200);
  });

  it('names only properties that exist on that label in the sample or the full model', async () => {
    const rows = (await db.query<{ label: string; key: string }>('MATCH (n) UNWIND labels(n) AS label UNWIND keys(n) AS key RETURN DISTINCT label, key')).rows;
    const present = new Set(rows.map((r) => `${r.label}.${r.key}`));
    // Properties the six-book sample happens not to carry (they exist in larger exports).
    const absentInSample = new Set(['Author.occupations', 'Item.is_book', 'Edition.is_book']);
    for (const label of LABELS) {
      for (const prop of label.properties) {
        const id = `${label.label}.${prop.name}`;
        if (!present.has(id)) expect(absentInSample.has(id) || ['Author.death_date', 'Author.bio', 'Book.subtitle'].includes(id), id).toBe(true);
      }
    }
  });
});

describe('few-shot examples', () => {
  it('all validate and run on Relate', async () => {
    let withRows = 0;
    for (const example of EXAMPLES) {
      const validation = await validateCypher(db, example.cypher);
      expect(validation, example.question).toEqual({ ok: true, problems: [] });
      const result = await db.query(example.cypher);
      if (result.rows.length) withRows++;
    }
    expect(EXAMPLES.length).toBeGreaterThanOrEqual(30);
    // Most examples find something even in the six-book sample.
    expect(withRows).toBeGreaterThan(EXAMPLES.length * 0.6);
  });

  it('have distinct questions', () => {
    expect(new Set(EXAMPLES.map((e) => e.question.toLowerCase())).size).toBe(EXAMPLES.length);
  });

  it('are retrieved by similarity, with and without an embedder', async () => {
    const embedder = new StubEmbedder();
    const near = await retrieveExamples('which authors have the most books?', embedder, 3);
    expect(near[0].question).toBe('Which authors have the most books on my list?');
    expect(near[0].similarity).toBeGreaterThan(near[2].similarity);
    const calls = embedder.calls;
    await retrieveExamples('how many books per decade', embedder, 3);
    expect(embedder.calls).toBe(calls + 1); // the examples were embedded once
    const lexical = await retrieveExamples('how many books per decade', null, 2);
    expect(lexical[0].question).toBe('How many books per decade?');
  });
});

describe('validateCypher', () => {
  it('accepts a good read and explains each kind of problem', async () => {
    expect(await validateCypher(db, 'MATCH (b:Book) RETURN b.title AS title LIMIT 5')).toEqual({ ok: true, problems: [] });
    const syntax = await validateCypher(db, 'MATCH (b:Book RETURN b');
    expect(syntax.ok).toBe(false);
    expect(syntax.problems[0]).toMatch(/syntax error/i);
    const unknown = await validateCypher(db, 'MATCH (b:Bok) RETURN b.titel');
    expect(unknown.ok).toBe(false);
    expect(unknown.problems.join(' ')).toMatch(/label `Bok`/);
    expect(unknown.problems.join(' ')).toMatch(/property key `titel`/);
    // The hint names the valid labels, and the properties of nothing irrelevant.
    expect(unknown.problems.join(' ')).toMatch(/Labels in this graph: Book, Author/);
    expect(unknown.problems.join(' ')).toMatch(/Properties: Book\(title, subtitle/);
    const relationship = await validateCypher(db, 'MATCH (b:Book)-[:WON1]->(a:Award) RETURN a.name');
    expect(relationship.problems.join(' ')).toMatch(/relationship type `WON1`/);
    expect(relationship.problems.join(' ')).toMatch(/Relationship types in this graph: WRITTEN_BY, ABOUT/);
    expect(relationship.problems.join(' ')).not.toMatch(/Properties:/);
    // A node mistaken for a property gets the pattern that reaches it.
    const author = await validateCypher(db, 'MATCH (b:Book) RETURN b.title AS title, b.author AS author');
    expect(author.problems.join(' ')).toContain('`author` is not a property. It is a node: MATCH (b:Book)-[:WRITTEN_BY]->(a:Author) and use a.name.');
    const publisher = await validateCypher(db, 'MATCH (e:Edition) RETURN e.publisher_name AS p');
    expect(publisher.problems.join(' ')).toContain('MATCH (e:Edition)-[:PUBLISHED_BY]->(p:Publisher) and use p.name.');
    const pattern = await validateCypher(db, 'MATCH (a:Author)-[:WON OR :WRITTEN_BY]->(w:Award) RETURN a.name');
    expect(pattern.syntaxError).toBe(true);
    expect(pattern.problems.join(' ')).toMatch(/Alternatives use a bar/);
    const write = await validateCypher(db, 'MATCH (b:Book) SET b.title = 1');
    expect(write.refused).toMatch(/SET/);
  });
});

describe('misplacedProperties', () => {
  it('catches a property read from the wrong label, which the engine cannot', async () => {
    const properties = await labelProperties(db);
    expect(properties.get('Book')!.has('title')).toBe(true);
    expect(properties.get('Book')!.has('price')).toBe(false);
    // `price` exists in the database, so EXPLAIN is silent; the statement would return 0.
    const wrong = 'MATCH (b:Book) RETURN count(b) AS books, sum(b.price) AS total';
    expect((await db.query(`EXPLAIN ${wrong}`)).notifications).toEqual([]);
    expect(misplacedProperties(wrong, properties)).toEqual([
      'Book has no property `price` (b.price is always null). `price` is a property of Item, Edition: (:Edition)-[:EDITION_OF]->(:Book).',
    ]);
    const validation = await validateCypher(db, wrong);
    expect(validation.ok).toBe(false);
    expect(validation.problems.join(' ')).toContain('Book has no property `price`');

    for (const fine of [
      'MATCH (e:Edition)-[:EDITION_OF]->(b:Book) RETURN b.title, e.price',
      'MATCH (i:Item) RETURN i.price, i.title',
      'MATCH (b:Book) WITH b.title AS t RETURN t',
      "MATCH (b:Book) WHERE b.title = 'x.price' RETURN point.distance(point({latitude: 1, longitude: 2}), point({latitude: 1, longitude: 2})) AS d",
      'MATCH (b:Book)-[w:WON]->(a:Award) RETURN w.year, a.name',
      'MATCH (x) RETURN x.price',
    ]) {
      expect(misplacedProperties(fine, properties), fine).toEqual([]);
    }
    // Every statement the app ships reads properties from the right labels.
    for (const example of EXAMPLES) expect(misplacedProperties(example.cypher, properties), example.question).toEqual([]);
  });
});

describe('linkNames', () => {
  const link = async (question: string) => (await linkNames(db, question)).map((n) => `${n.label}:${n.name}`);

  it('links a name only when the question spells it out', async () => {
    // The middle initial is not required; every other word of the name is.
    expect(await link('What did Ursula Le Guin write?')).toEqual(['Author:Ursula K. Le Guin']);
    expect(await link('Which books are set in San Francisco?')).toContain('Place:San Francisco');
    // "American" alone does not link "American literature"; "awards" alone links no award.
    expect(await link('Which authors are American?')).toEqual([]);
    expect(await link('How many awards has each author won?')).toEqual([]);
    expect(await link('the of and')).toEqual([]);
  });

  it('links book titles, and drops a name that sits inside a longer one', async () => {
    // "Hail Mary" is also a Place and "Mars" a Place and a Subject; the titles win.
    expect(await link('Where is Project Hail Mary set?')).toEqual(['Book:Project Hail Mary']);
    expect(await link('Who wrote Red Mars?')).toEqual(['Book:Red Mars']);
    // A leading article may be left out; any other word of the title may not.
    expect(await link('what awards did left hand of darkness win')).toEqual(['Book:The Left Hand of Darkness']);
    expect(await link('books about a left hand')).toEqual([]);
    const both = await link('What subjects do Red Mars and Project Hail Mary have in common?');
    expect(both.sort()).toEqual(['Book:Project Hail Mary', 'Book:Red Mars']);
    // Without the title around it, the place links.
    expect(await link('Which books are set on Mars?')).toContain('Place:Mars');
  });

  it('never links a number or a one-word book title', async () => {
    await db.query("CREATE (:Era {name: '2015'}), (:Award {name: 'About You Awards'}), (:Book {key: 'test:prize', title: 'The Prize'})");
    try {
      expect(await link('Which books about climate change were published after 2015?')).not.toContain('Era:2015');
      expect(await link('How many awards has each author won?')).toEqual([]);
      expect(await link('Which books won the Pulitzer Prize?')).toEqual([]);
    } finally {
      // Nodes that existed before this statement began: deleting them is safe.
      await db.query("MATCH (n) WHERE (n:Era AND n.name = '2015') OR (n:Award AND n.name = 'About You Awards') OR (n:Book AND n.key = 'test:prize') DETACH DELETE n");
    }
  });

  it('never links a one-word subject, and keeps at most two names per label', async () => {
    const names = await link('science fiction about Mars and England');
    expect(names.filter((n) => n.startsWith('Subject:')).every((n) => n.split(' ').length >= 2)).toBe(true);
    // One subject at most, and the spelling the question uses when the graph has it.
    expect(names.filter((n) => n.startsWith('Subject:')).length).toBeLessThanOrEqual(1);
    expect((await link('What are the highest rated science fiction books?')).filter((n) => n.startsWith('Subject:')).map((n) => n.toLowerCase())).toEqual(['subject:science fiction']);
    expect(names.filter((n) => n.startsWith('Place:')).length).toBeLessThanOrEqual(2);
  });
});

describe('valueHints', () => {
  it('lists the commonest countries, genres and formats of the loaded graph', async () => {
    const values = await valueHints(db);
    expect(values['Country.name']).toEqual(['United States', 'United Kingdom']);
    expect(values['Genre.name'][0]).toBe('science fiction');
    expect(values['Edition.format']).toEqual(['Kindle Edition', 'Hardcover', 'Paperback']);
    expect(valuesText(values)).toContain("Country.name: 'United States', 'United Kingdom'");
    expect(valuesText({ 'Genre.name': [] })).toBe('');
    expect(systemPrompt('SCHEMA', values)).toContain("Edition.format: 'Kindle Edition'");
  });
});

describe('textToCypher', () => {
  const embedder = new StubEmbedder();

  it('builds a prompt with schema, nearest example last, and grounded names', async () => {
    const examples = await retrieveExamples('Which authors have the most books?', embedder, 2);
    const messages = buildMessages('Q?', examples, [{ label: 'Author', name: 'Andy Weir', score: 1 }], 'SCHEMA');
    expect(messages[0].role).toBe('system');
    expect(messages[0].content).toContain('SCHEMA');
    expect(messages).toHaveLength(6);
    expect(messages[3].content).toBe(examples[0].question);
    expect(messages[5].content).toBe('Q?\n\nNames in the graph:\n- Author.name = "Andy Weir"');
    const titled = buildMessages('Q?', [], [{ label: 'Book', name: 'Red Mars', score: 1 }], 'SCHEMA', { 'Genre.name': ['essay'] });
    expect(titled[0].content).toContain("Genre.name: 'essay'");
    expect(titled[1].content).toBe('Q?\n\nNames in the graph:\n- Book.title = "Red Mars"');
    const subject = buildMessages('Q?', [], [{ label: 'Subject', name: "Climate Change's effects", score: 1 }], 'SCHEMA');
    expect(subject[1].content).toBe("Q?\n\nNames in the graph:\n- Subject: toLower(s.name) CONTAINS 'climate change\\'s effects'");
  });

  it('generates, validates and runs', async () => {
    const llm = new StubLlm(['```cypher\nMATCH (b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE a.name = "Andy Weir"\nRETURN b.title AS title;\n```']);
    const events: PipelineEvent[] = [];
    const out = await textToCypher({ db, llm, embedder, question: 'What did Andy Weir write?', onEvent: (e) => events.push(e) });
    expect(out.error).toBeNull();
    expect(out.cypher).toBe('MATCH (b:Book)-[:WRITTEN_BY]->(a:Author)\nWHERE a.name = "Andy Weir"\nRETURN b.title AS title\nLIMIT 50');
    expect(out.result!.rows).toEqual([{ title: 'Project Hail Mary' }]);
    expect(out.attempts).toEqual([{ cypher: out.cypher, problem: null }]);
    expect(out.names).toContainEqual(expect.objectContaining({ name: 'Andy Weir' }));
    expect(events.map((e) => e.type).filter((t) => t !== 'token')).toEqual(['examples', 'names', 'generating', 'running', 'attempt']);
    expect(llm.calls[0].options).toMatchObject({ temperature: 0 });
  });

  it('feeds a syntax error back and takes the fix', async () => {
    const llm = new StubLlm(['MATCH (b:Book RETURN b.title', 'MATCH (b:Book) RETURN count(b) AS books']);
    const out = await textToCypher({ db, llm, embedder, question: 'How many books?' });
    expect(out.result!.rows).toEqual([{ books: 6 }]);
    expect(out.attempts).toHaveLength(2);
    expect(out.attempts[0].problem).toMatch(/syntax error/i);
    const repair = llm.calls[1].messages;
    expect(repair[repair.length - 1].content).toMatch(/cannot run:[\s\S]*syntax error/i);
    expect(repair[repair.length - 2]).toEqual({ role: 'assistant', content: 'MATCH (b:Book RETURN b.title\nLIMIT 50' });
  });

  it('feeds unknown names back with the valid properties', async () => {
    const llm = new StubLlm(['MATCH (b:Book) RETURN b.name AS name, b.titel AS t', 'MATCH (b:Book) RETURN b.title AS title ORDER BY title LIMIT 2']);
    const out = await textToCypher({ db, llm, embedder, question: 'titles' });
    expect(out.attempts[0].problem).toMatch(/titel/);
    expect(out.result!.rows).toHaveLength(2);
  });

  it('flips a backwards relationship without another model call', async () => {
    const llm = new StubLlm(["MATCH (a:Author)-[:WRITTEN_BY]->(b:Book)\nWHERE a.name = 'Andy Weir'\nRETURN b.title AS title"]);
    const out = await textToCypher({ db, llm, embedder, question: 'What did Andy Weir write?' });
    expect(llm.calls).toHaveLength(1);
    expect(out.cypher).toContain('(a:Author)<-[:WRITTEN_BY]-(b:Book)');
    expect(out.result!.rows).toEqual([{ title: 'Project Hail Mary' }]);
    expect(out.attempts).toHaveLength(1);
    expect(out.attempts[0].fixes).toEqual(['WRITTEN_BY runs (:Book)-[:WRITTEN_BY]->(:Author); the arrow was reversed.']);
  });

  it('restores a number that lost its last digit, and reports a syntax error on its own', async () => {
    const fixed = await textToCypher({ db, llm: new StubLlm(['MATCH (b:Book)\nWHERE b.first_publish_year < 200\nRETURN b.title AS title\nORDER BY title']), embedder, question: 'Which books were published before 2000?' });
    expect(fixed.attempts[0].fixes).toEqual(['The question says 2000; the statement had 200.']);
    expect(fixed.result!.rows).toEqual([{ title: 'Red Mars' }, { title: 'The Left Hand of Darkness' }]);

    const llm = new StubLlm(['MATCH (a:Author)-[:WON OR :WRITTEN_BY]->(w:Award) RETURN a.name', 'MATCH (a:Author)-[:WON]->(w:Award) RETURN count(w) AS n']);
    const out = await textToCypher({ db, llm, embedder, question: 'awards per author' });
    expect(out.attempts[0].problem).toMatch(/^syntax error/);
    expect(out.attempts[0].problem).not.toMatch(/does not connect/);
    expect(out.error).toBeNull();
  });

  it('sends back a relationship between labels the graph does not connect', async () => {
    const llm = new StubLlm(['MATCH (a:Author)-[:ABOUT]->(s:Subject) RETURN s.name AS subject', 'MATCH (b:Book)-[:ABOUT]->(s:Subject) RETURN DISTINCT s.name AS subject LIMIT 3']);
    const out = await textToCypher({ db, llm, embedder, question: 'What do my authors write about?' });
    expect(out.attempts[0].problem).toMatch(/\[:ABOUT\] does not connect Author to Subject/);
    expect(llm.calls[1].messages[llm.calls[1].messages.length - 1].content).toContain('(:Book)-[:ABOUT]->(:Subject)');
    expect(out.result!.rows).toHaveLength(3);
  });

  it('feeds an execution error back', async () => {
    const llm = new StubLlm(["MATCH (b:Book) RETURN apoc.text.join([b.title], ',') AS t", 'MATCH (b:Book) RETURN b.title AS t LIMIT 1']);
    const out = await textToCypher({ db, llm, embedder, question: 'titles joined' });
    expect(out.attempts[0].problem).toMatch(/unknown function/i);
    expect(out.error).toBeNull();
  });

  it('never runs a write, and does not ask for a repair of one', async () => {
    const llm = new StubLlm(["MATCH (b:Book) SET b.title = 'pwned' RETURN b.title", 'MATCH (b:Book) RETURN b.title']);
    const out = await textToCypher({ db, llm, embedder, question: 'rename every book' });
    expect(out.cypher).toBeNull();
    expect(out.error).toMatch(/SET is not allowed/);
    expect(llm.calls).toHaveLength(1);
    expect((await db.query("MATCH (b:Book) WHERE b.title = 'pwned' RETURN count(b) AS n")).rows[0]).toEqual({ n: 0 });
  });

  it('gives up after the repair budget with the last problem', async () => {
    const llm = new StubLlm(['MATCH (', 'MATCH ((', 'I cannot help with that.']);
    const out = await textToCypher({ db, llm, embedder, question: '?', maxRepairs: 2 });
    expect(out.cypher).toBeNull();
    expect(out.attempts).toHaveLength(3);
    expect(out.error).toMatch(/No runnable query after 3 attempts/);
  });

  it('answers end to end with the stub model replaying the nearest example', async () => {
    const out = await textToCypher({ db, llm: new StubLlm(), embedder, question: 'Which authors have the most books on my list?' });
    expect(out.error).toBeNull();
    expect(out.result!.columns).toEqual(['author', 'books']);
    expect(out.result!.rows.length).toBe(6);
  });

  it('stops when aborted', async () => {
    const controller = new AbortController();
    controller.abort();
    await expect(textToCypher({ db, llm: new StubLlm(), embedder, question: 'x', signal: controller.signal })).rejects.toThrow();
  });
});
