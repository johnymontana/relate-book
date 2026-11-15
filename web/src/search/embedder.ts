/** Anything that turns texts into unit-length vectors: the transformers.js worker, or a stub in tests. */
export interface Embedder {
  readonly modelId: string;
  readonly dimensions: number;
  embed(texts: string[]): Promise<number[][]>;
}

/** Throws unless the vector has the right length and only finite values (the engine would store a bad one). */
export function validateVector(vector: number[], dimensions: number): void {
  if (vector.length !== dimensions) throw new Error(`embedding has ${vector.length} dimensions, expected ${dimensions}`);
  for (const x of vector) if (!Number.isFinite(x)) throw new Error('embedding holds a non-finite value');
}

export function cosine(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na && nb ? dot / Math.sqrt(na * nb) : 0;
}
