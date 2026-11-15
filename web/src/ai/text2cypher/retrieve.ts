// Picks the few-shot examples nearest to a question. With an embedding model
// the choice is by cosine similarity; without one, by shared words.

import { cosine, type Embedder } from '../../search/embedder';
import { tokens } from '../../search/keywordQuery';
import { EXAMPLES, type Example } from './examples';

const cache = new Map<string, Promise<number[][]>>();

/** The example questions embedded once per model. */
function exampleVectors(embedder: Embedder, examples: Example[]): Promise<number[][]> {
  const key = `${embedder.modelId}:${examples.length}`;
  let vectors = cache.get(key);
  if (!vectors) {
    vectors = embedder.embed(examples.map((e) => e.question));
    vectors.catch(() => cache.delete(key));
    cache.set(key, vectors);
  }
  return vectors;
}

export interface RetrievedExample extends Example {
  similarity: number;
}

function lexicalSimilarity(a: string, b: string): number {
  const ta = new Set(tokens(a));
  const tb = new Set(tokens(b));
  let shared = 0;
  for (const t of ta) if (tb.has(t)) shared++;
  return shared / Math.max(1, ta.size + tb.size - shared);
}

export async function retrieveExamples(question: string, embedder: Embedder | null, k = 5, examples: Example[] = EXAMPLES): Promise<RetrievedExample[]> {
  let scored: RetrievedExample[];
  if (embedder) {
    const [vectors, [query]] = await Promise.all([exampleVectors(embedder, examples), embedder.embed([question])]);
    scored = examples.map((e, i) => ({ ...e, similarity: cosine(query, vectors[i]) }));
  } else {
    scored = examples.map((e) => ({ ...e, similarity: lexicalSimilarity(question, e.question) }));
  }
  return scored.sort((a, b) => b.similarity - a.similarity).slice(0, k);
}
