// Reciprocal rank fusion over the semantic and keyword candidate lists, pure.
// A port of ios/RelateBooks/Search/RankFusion.swift without the notes list.

export interface SemanticCandidate {
  key: string;
  /** Cosine in [-1, 1]: 2 * score - 1 (Relate's vector SCORE is (1 + cosine) / 2). */
  cosine: number;
}

export interface KeywordCandidate {
  key: string;
  score: number;
  titleMatch: boolean;
}

export type MatchReason = 'both' | 'semantic' | 'keyword';

export interface SearchHit {
  key: string;
  reason: MatchReason;
  semanticRank: number | null;
  keywordRank: number | null;
  semanticCosine: number | null;
  keywordScore: number | null;
  titleMatch: boolean;
  fusedScore: number;
}

/**
 * Each list is already ordered best first; a key repeated within a list keeps
 * its first position (rank is the 1-based position).
 *
 * fused = sum of 1 / (k + rank) over the lists containing the key. Order:
 * fused desc, then the smallest rank, then a title keyword match first, then
 * semantic cosine desc (none last), then key.
 */
export function fuse(semantic: SemanticCandidate[], keyword: KeywordCandidate[], k = 60): SearchHit[] {
  const hits = new Map<string, SearchHit>();
  const entry = (key: string): SearchHit => {
    let hit = hits.get(key);
    if (!hit) {
      hit = { key, reason: 'keyword', semanticRank: null, keywordRank: null, semanticCosine: null, keywordScore: null, titleMatch: false, fusedScore: 0 };
      hits.set(key, hit);
    }
    return hit;
  };
  let rank = 0;
  for (const c of semantic) {
    const hit = entry(c.key);
    if (hit.semanticRank !== null) continue;
    hit.semanticRank = ++rank;
    hit.semanticCosine = c.cosine;
  }
  rank = 0;
  for (const c of keyword) {
    const hit = entry(c.key);
    if (hit.keywordRank !== null) continue;
    hit.keywordRank = ++rank;
    hit.keywordScore = c.score;
    hit.titleMatch = c.titleMatch;
  }
  for (const hit of hits.values()) {
    if (hit.semanticRank !== null) hit.fusedScore += 1 / (k + hit.semanticRank);
    if (hit.keywordRank !== null) hit.fusedScore += 1 / (k + hit.keywordRank);
    hit.reason = hit.semanticRank !== null && hit.keywordRank !== null ? 'both' : hit.semanticRank !== null ? 'semantic' : 'keyword';
  }
  const best = (h: SearchHit) => Math.min(h.semanticRank ?? Infinity, h.keywordRank ?? Infinity);
  return [...hits.values()].sort((a, b) => {
    if (a.fusedScore !== b.fusedScore) return b.fusedScore - a.fusedScore;
    if (best(a) !== best(b)) return best(a) - best(b);
    if (a.titleMatch !== b.titleMatch) return a.titleMatch ? -1 : 1;
    if (a.semanticCosine !== null && b.semanticCosine !== null && a.semanticCosine !== b.semanticCosine) return b.semanticCosine - a.semanticCosine;
    if ((a.semanticCosine === null) !== (b.semanticCosine === null)) return a.semanticCosine !== null ? -1 : 1;
    return a.key < b.key ? -1 : a.key > b.key ? 1 : 0;
  });
}
