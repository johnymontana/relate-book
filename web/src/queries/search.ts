// Cypher for hybrid search, "more like this", the embedding indexer and
// entity linking. Follows the rules the iOS app found (SearchQueries.swift):
// filters go after SEARCH, the vector SCORE is (1 + cosine) / 2, and fusion
// happens outside Cypher.
//
// Parameters cross into WASM as JSON, so a vector is a plain list wrapped in
// vector(..., 384, FLOAT32) inside the statement.

import { BOOK_TEXT_INDEX, BOOK_VECTOR_INDEX, EMBEDDING_DIMENSIONS, ITEM_TEXT_INDEX, TERM_TEXT_INDEX } from '../engine/schema';
import { cypher, type Statement } from './statement';

const VECTOR = (param: string) => `vector($${param}, ${EMBEDDING_DIMENSIONS}, FLOAT32)`;

export function semantic(vector: number[], limit: number, modelId: string): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book)
      SEARCH b IN (VECTOR INDEX ${BOOK_VECTOR_INDEX} FOR ${VECTOR('q')} LIMIT $limit) SCORE AS score
      WHERE b.embedding_model = $model
      RETURN b.key AS key, score
      ORDER BY score DESC, key`,
    params: { q: vector, limit: Math.max(1, limit), model: modelId },
  };
}

export function bookText(text: string, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book)
      SEARCH b IN (FULLTEXT INDEX ${BOOK_TEXT_INDEX} FOR $text LIMIT $limit) SCORE AS score
      RETURN b.key AS key, score, b.title AS title, b.description AS description, b.first_sentence AS firstSentence
      ORDER BY score DESC, key`,
    params: { text, limit: Math.max(1, limit) },
  };
}

export function itemText(text: string, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (i:Item)
      SEARCH i IN (FULLTEXT INDEX ${ITEM_TEXT_INDEX} FOR $text LIMIT $limit) SCORE AS score
      MATCH (i)-[:EDITION_OF]->(b:Book)
      RETURN b.key AS key, score, b.title AS bookTitle, i.title AS itemTitle, i.byline AS byline
      ORDER BY score DESC, key`,
    params: { text, limit: Math.max(1, limit) },
  };
}

/** The nearest books to a book's own stored vector, excluding it; 0 rows when it is not embedded. */
export function moreLikeThis(key: string, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (s:Book {key: $key})
      WITH s, s.embedding AS q
      MATCH (b:Book)
      SEARCH b IN (VECTOR INDEX ${BOOK_VECTOR_INDEX} FOR q LIMIT $probe) SCORE AS score
      WHERE b <> s
      RETURN b.key AS key, score
      ORDER BY score DESC, key
      LIMIT $limit`,
    params: { key, probe: Math.max(1, limit) + 1, limit: Math.max(1, limit) },
  };
}

/** Names in the graph that a piece of text mentions (authors, subjects, places, ...), best first. */
export function terms(text: string, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (n)
      SEARCH n IN (FULLTEXT INDEX ${TERM_TEXT_INDEX} FOR $text LIMIT $limit) SCORE AS score
      RETURN labels(n)[0] AS label, n.name AS name, score
      ORDER BY score DESC, label, name`,
    params: { text, limit: Math.max(1, limit) },
  };
}

// --- the embedding indexer -------------------------------------------------

/** One page of books in key order with what the embedding text needs. Start with `after: ''`. */
export function scanBooks(after: string, limit: number): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book)
      WHERE b.key > $after
      WITH b ORDER BY b.key LIMIT $limit
      RETURN b.key AS key, b.title AS title, b.description AS description,
             b.embedding_model AS model, b.embedding_text_hash AS hash, b.embedding IS NOT NULL AS hasEmbedding,
             [(b)-[:WRITTEN_BY]->(a:Author) | a.name] AS authors,
             [(b)-[:ABOUT]->(s:Subject) | s.name] AS subjects`,
    params: { after, limit },
  };
}

export interface EmbeddingRow {
  key: string;
  vector: number[];
  hash: string;
}

/** One batch in one statement: it commits whole or not at all. */
export function writeEmbeddings(rows: EmbeddingRow[], modelId: string): Statement {
  return {
    cypher: cypher`
      UNWIND $rows AS row
      MATCH (b:Book {key: row.key})
      SET b.embedding = vector(row.vector, ${EMBEDDING_DIMENSIONS}, FLOAT32), b.embedding_model = $model, b.embedding_text_hash = row.hash
      RETURN count(b) AS written`,
    params: { rows, model: modelId },
  };
}

export function embeddingCoverage(modelId: string): Statement {
  return {
    cypher: cypher`
      MATCH (b:Book)
      RETURN count(b) AS books, count(CASE WHEN b.embedding IS NOT NULL AND b.embedding_model = $model THEN 1 END) AS embedded`,
    params: { model: modelId },
  };
}
