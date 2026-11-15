#!/usr/bin/env node
// Export a Relate store (.rl bundle or directory) as a dataset the web app can
// load into Relate WASM.
//
// The browser build of Relate cannot open a native store (no filesystem, no
// Parquet codec), so the graph crosses as JSON: every node and relationship,
// grouped by label set and type, plus the DDL for the store's constraints and
// indexes. `src/engine/dataset.ts` turns that back into Cypher.
//
//   node scripts/export-store.mjs ../books.rl                 -> local/books.json (git-ignored)
//   node scripts/export-store.mjs STORE --out FILE [--relate BIN] [--name TITLE]
//
// The store is copied to a temp directory and the copy is opened read-only;
// the original is never opened. Needs the `relate` CLI on PATH (or --relate).

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_OUT = resolve(HERE, '../local/books.json');

function usage(code) {
  const text = `Usage: node scripts/export-store.mjs STORE [--out FILE] [--relate BIN] [--name TITLE]

  STORE          a .rl bundle or a store directory (copied; never opened in place)
  --out FILE     where to write the dataset (default: web/local/books.json, git-ignored)
  --relate BIN   the relate CLI to use (default: "relate" on PATH)
  --name TITLE   dataset name shown in the app (default: the wishlist title)
`;
  (code === 0 ? process.stdout : process.stderr).write(text);
  process.exit(code);
}

function parseArgs(argv) {
  const args = { store: null, out: DEFAULT_OUT, relate: 'relate', name: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') usage(0);
    else if (a === '--out') args.out = resolve(argv[++i] ?? usage(2));
    else if (a === '--relate') args.relate = argv[++i] ?? usage(2);
    else if (a === '--name') args.name = argv[++i] ?? usage(2);
    else if (a.startsWith('-')) usage(2);
    else if (args.store === null) args.store = resolve(a);
    else usage(2);
  }
  if (!args.store) usage(2);
  return args;
}

/** Backtick-quote an identifier unless it is a plain one. */
export function ident(name) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : '`' + String(name).replace(/`/g, '``') + '`';
}

/**
 * How a non-JSON property type crosses: the exporter moves such values out of
 * the plain property map, and the loader rebuilds them with a Cypher function.
 * Returns null for types JSON carries as-is.
 */
export function typedKind(valueType) {
  const t = valueType.toUpperCase();
  if (t.startsWith('POINT')) return { kind: 'point' };
  if (t.startsWith('ZONED DATETIME')) return { kind: 'datetime' };
  if (t.startsWith('LOCAL DATETIME')) return { kind: 'localdatetime' };
  if (t.startsWith('DATE')) return { kind: 'date' };
  if (t.startsWith('ZONED TIME')) return { kind: 'time' };
  if (t.startsWith('LOCAL TIME')) return { kind: 'localtime' };
  if (t.startsWith('DURATION')) return { kind: 'duration' };
  const vector = /^VECTOR<(\w+)[^>]*>\((\d+)\)/.exec(t);
  if (vector) return { kind: 'vector', coordinateType: vector[1], dimensions: Number(vector[2]) };
  return null;
}

/** The wire form of a typed value, as the loader's Cypher expects it. */
function typedValue(spec, value) {
  if (value === null || value === undefined) return null;
  if (spec.kind === 'point') {
    if ('latitude' in value) {
      const p = { latitude: value.latitude, longitude: value.longitude };
      if (value.height !== undefined) p.height = value.height;
      return p;
    }
    const p = { x: value.x, y: value.y, crs: value.crs };
    if (value.z !== undefined) p.z = value.z;
    return p;
  }
  if (spec.kind === 'vector') return Array.isArray(value) ? value : value.values;
  return value; // temporal types serialize as ISO strings
}

/** DDL that recreates a store's constraints and indexes (LOOKUP indexes are implicit). */
export function schemaDDL(constraints, indexes) {
  const out = { constraints: [], indexes: [] };
  const owned = new Set();
  for (const c of constraints) {
    if (c.ownedIndex) owned.add(c.ownedIndex);
    const label = c.labelsOrTypes?.[0];
    const props = c.properties ?? [];
    if (c.entityType !== 'NODE' || !label || props.length === 0) continue;
    const target = props.length === 1 ? `n.${ident(props[0])}` : `(${props.map((p) => `n.${ident(p)}`).join(', ')})`;
    if (c.type === 'NODE_PROPERTY_UNIQUENESS' || c.type === 'UNIQUENESS') {
      out.constraints.push(`CREATE CONSTRAINT ${ident(c.name)} IF NOT EXISTS FOR (n:${ident(label)}) REQUIRE ${target} IS UNIQUE`);
    } else if (c.type === 'NODE_KEY') {
      out.constraints.push(`CREATE CONSTRAINT ${ident(c.name)} IF NOT EXISTS FOR (n:${ident(label)}) REQUIRE ${target} IS NODE KEY`);
    }
  }
  for (const i of indexes) {
    if (owned.has(i.name) || i.owningConstraint || i.type === 'LOOKUP') continue;
    const label = i.labelsOrTypes?.[0];
    const props = i.properties ?? [];
    if (i.entityType !== 'NODE' || !label || props.length === 0) continue;
    const name = ident(i.name);
    const on = props.map((p) => `n.${ident(p)}`).join(', ');
    if (i.type === 'RANGE') out.indexes.push(`CREATE INDEX ${name} IF NOT EXISTS FOR (n:${ident(label)}) ON (${on})`);
    else if (i.type === 'POINT') out.indexes.push(`CREATE POINT INDEX ${name} IF NOT EXISTS FOR (n:${ident(label)}) ON (${on})`);
    else if (i.type === 'FULLTEXT') {
      const labels = i.labelsOrTypes.map(ident).join('|');
      out.indexes.push(`CREATE FULLTEXT INDEX ${name} IF NOT EXISTS FOR (n:${labels}) ON EACH [${on}]`);
    }
    // VECTOR indexes are not exported: the web app declares its own for the
    // embedding model it runs, and a vector written by another model is
    // re-embedded anyway.
  }
  return out;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!existsSync(args.store)) {
    console.error(`error: no store at ${args.store}`);
    process.exit(1);
  }

  let version;
  try {
    version = execFileSync(args.relate, ['--version'], { encoding: 'utf8' }).split('\n')[0].trim();
  } catch {
    console.error(`error: cannot run "${args.relate}". Install the relate CLI (https://relatedb.ai) or pass --relate BIN.`);
    process.exit(1);
  }

  const scratch = mkdtempSync(join(tmpdir(), 'relate-books-export-'));
  try {
    const copy = join(scratch, basename(args.store));
    cpSync(args.store, copy, { recursive: true });
    const query = (cypher) => {
      const out = execFileSync(args.relate, ['query', '--read-only', '--json', '--max-rows', '0', '-d', copy, cypher], {
        encoding: 'utf8',
        maxBuffer: 1 << 30,
      });
      return JSON.parse(out).data;
    };

    // Which properties hold a type JSON cannot carry (points, temporals, vectors).
    const typedByLabels = new Map();
    for (const row of query(
      'MATCH (n) UNWIND keys(n) AS k WITH labels(n) AS labels, k, valueType(n[k]) AS t RETURN DISTINCT labels, k, t',
    )) {
      const spec = typedKind(row.t);
      if (!spec) continue;
      const key = JSON.stringify(row.labels);
      if (!typedByLabels.has(key)) typedByLabels.set(key, {});
      typedByLabels.get(key)[row.k] = spec;
    }
    const typedByType = new Map();
    for (const row of query(
      'MATCH ()-[r]->() UNWIND keys(r) AS k WITH type(r) AS type, k, valueType(r[k]) AS t RETURN DISTINCT type, k, t',
    )) {
      const spec = typedKind(row.t);
      if (!spec) continue;
      if (!typedByType.has(row.type)) typedByType.set(row.type, {});
      typedByType.get(row.type)[row.k] = spec;
    }

    const split = (props, typed) => {
      const plain = {};
      const special = {};
      for (const [k, v] of Object.entries(props)) {
        if (typed && typed[k]) special[k] = typedValue(typed[k], v);
        else plain[k] = v;
      }
      return [plain, special];
    };

    const nodeGroups = new Map();
    for (const row of query('MATCH (n) RETURN id(n) AS id, labels(n) AS labels, properties(n) AS props ORDER BY id')) {
      const key = JSON.stringify(row.labels);
      if (!nodeGroups.has(key)) nodeGroups.set(key, { labels: row.labels, typed: typedByLabels.get(key) ?? {}, rows: [] });
      const group = nodeGroups.get(key);
      const [plain, special] = split(row.props, group.typed);
      group.rows.push(Object.keys(group.typed).length ? [row.id, plain, special] : [row.id, plain]);
    }

    const relGroups = new Map();
    for (const row of query(
      'MATCH (a)-[r]->(b) RETURN id(a) AS s, id(b) AS t, type(r) AS type, properties(r) AS props ORDER BY id(r)',
    )) {
      if (!relGroups.has(row.type)) relGroups.set(row.type, { type: row.type, typed: typedByType.get(row.type) ?? {}, rows: [] });
      const group = relGroups.get(row.type);
      const [plain, special] = split(row.props, group.typed);
      const hasPlain = Object.keys(plain).length > 0;
      if (Object.keys(group.typed).length) group.rows.push([row.s, row.t, plain, special]);
      else group.rows.push(hasPlain ? [row.s, row.t, plain] : [row.s, row.t]);
    }

    const schema = schemaDDL(query('SHOW CONSTRAINTS'), query('SHOW INDEXES'));
    const wishlist = query('MATCH (w:Wishlist) RETURN w.title AS title ORDER BY w.imported_at DESC LIMIT 1')[0];

    const nodes = [...nodeGroups.values()];
    const rels = [...relGroups.values()];
    const dataset = {
      format: 'relate-books-dataset',
      version: 1,
      name: args.name ?? wishlist?.title ?? basename(args.store),
      exportedAt: new Date().toISOString(),
      exportedWith: version,
      counts: {
        nodes: nodes.reduce((n, g) => n + g.rows.length, 0),
        relationships: rels.reduce((n, g) => n + g.rows.length, 0),
      },
      schema,
      nodes,
      relationships: rels,
    };

    mkdirSync(dirname(args.out), { recursive: true });
    writeFileSync(args.out, JSON.stringify(dataset) + '\n');
    const mb = (statSync(args.out).size / (1024 * 1024)).toFixed(2);
    console.log(`${dataset.name}: ${dataset.counts.nodes} nodes, ${dataset.counts.relationships} relationships`);
    console.log(`  ${nodes.length} node groups, ${rels.length} relationship types, ${schema.constraints.length} constraints, ${schema.indexes.length} indexes`);
    console.log(`  wrote ${args.out} (${mb} MB) with ${version}`);
    if (args.out !== resolve(HERE, '../public/data/sample.json')) {
      console.log('  This file records the list id and URL. Keep a personal export out of git and off public hosts.');
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
