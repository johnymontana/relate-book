// The sanitized fulltext query. A port of ios/RelateBooks/Search/KeywordQuery.swift.
//
// Relate's fulltext indexes tokenize the query into lowercase letter/digit
// runs, OR the terms and score by term frequency. Relate 1.0.1 reads
// upper-case AND / OR / NOT as operators, so `$text` must never carry raw
// user input: the terms here are lower-case and drop and/or/not.

const STOPWORDS = new Set(
  (
    'a an and are as at be been but by can could did do does for from had has have he her his how i if in into is it ' +
    'its me my no not of on or our she so than that the their them then there these they this those to too up us was we were ' +
    'what when where which who whom why will with would you your about after all also any because before being between both each few more ' +
    'most other out over same some such through under until very while just only own again once here should now book books'
  ).split(' '),
);

export function isStopword(token: string): boolean {
  return STOPWORDS.has(token);
}

/** Lowercased maximal runs of letters or digits, in order, not deduped (the engine's tokenizer). */
export function tokens(text: string): string[] {
  return text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
}

export class KeywordQuery {
  readonly terms: string[];

  private constructor(terms: string[]) {
    this.terms = terms;
  }

  /** null when no term is left (the fulltext queries are skipped). */
  static parse(raw: string, maxTerms = 8): KeywordQuery | null {
    const seen = new Set<string>();
    const terms: string[] = [];
    for (const token of tokens(raw)) {
      if ([...token].length < 2 || STOPWORDS.has(token) || seen.has(token)) continue;
      seen.add(token);
      terms.push(token);
      if (terms.length === maxTerms) break;
    }
    return terms.length ? new KeywordQuery(terms) : null;
  }

  /** The `$text` parameter: the terms joined with spaces. */
  get text(): string {
    return this.terms.join(' ');
  }

  /** True when every term is a token of the texts (tokens, not substrings: "earth" does not match "earthquake"). */
  isCoveredBy(texts: Array<string | null | undefined>): boolean {
    const available = new Set(texts.flatMap((t) => (t ? tokens(t) : [])));
    return this.terms.every((t) => available.has(t));
  }
}
