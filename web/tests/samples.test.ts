import { describe, expect, it } from 'vitest';
import { checkReadOnly } from '../src/ai/text2cypher/guard';
import { SAMPLE_CYPHER, SAMPLE_QUESTIONS } from '../src/queries/samples';
import { sampleDb } from './helpers/engine';

describe('Query tab samples', () => {
  it('every sample statement is read-only and runs', async () => {
    const db = await sampleDb();
    for (const sample of SAMPLE_CYPHER) {
      expect(checkReadOnly(sample.cypher), sample.title).toEqual({ ok: true });
      const result = await db.query(sample.cypher);
      // The vector sample has nothing to find until books are embedded; a plan has no rows.
      if (!/Vector search|query plan/.test(sample.title)) expect(result.rows.length, sample.title).toBeGreaterThan(0);
    }
    expect(SAMPLE_QUESTIONS.length).toBeGreaterThan(5);
  });
});
