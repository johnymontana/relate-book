// A deterministic stand-in for the embedding model: a hashed bag of words,
// unit length. Texts that share words land near each other, which is enough
// for tests and for `?stub-ai` in the dev server. It is not a language model.

import { EMBEDDING_DIMENSIONS } from '../engine/schema';
import type { Embedder } from './embedder';
import { tokens } from './keywordQuery';

function fnv1a(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

export class StubEmbedder implements Embedder {
  readonly modelId: string;
  readonly dimensions = EMBEDDING_DIMENSIONS;
  calls = 0;

  constructor(modelId = 'stub/hashed-bag-of-words') {
    this.modelId = modelId;
  }

  async embed(texts: string[]): Promise<number[][]> {
    this.calls += 1;
    return texts.map((text) => {
      const v = new Array<number>(this.dimensions).fill(0);
      for (const token of tokens(text)) {
        const h = fnv1a(token);
        v[h % this.dimensions] += h & 0x100 ? 1 : -1;
      }
      const norm = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
      if (norm === 0) {
        v[0] = 1;
        return v;
      }
      return v.map((x) => x / norm);
    });
  }
}
