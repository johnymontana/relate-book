// The text a Book is embedded from, and its staleness hash. A port of
// ios/RelateBooks/Embedding/BookEmbeddingText.swift, so the web app and the
// iPhone app embed a book from the same string.
//
// `title · authors · up to 15 subjects · description (first 800 code points)`,
// joined with " · " and with empty parts dropped.

export const SEPARATOR = ' · ';
export const MAX_SUBJECTS = 15;
export const DESCRIPTION_CODE_POINTS = 800;

/** Catalogue subjects that say nothing about the book (lowercased). */
export const SUBJECT_STOPLIST = new Set([
  'fiction', 'nonfiction', 'general', 'new york times bestseller', 'new york times reviewed',
  'large type books', 'accessible book', 'protected daisy', 'in library', 'lending library',
  'long now manual for civilization', 'open library staff picks', 'popular print disabled books',
  'overdrive',
]);

export interface BookEmbeddingInput {
  key: string;
  title: string | null;
  /** May hold nulls: an author or subject node without a name still yields a list entry. */
  authors: Array<string | null>;
  subjects: Array<string | null>;
  description: string | null;
}

const strings = (xs: Array<string | null>): string[] => xs.filter((x): x is string => typeof x === 'string');

/** Dedupe by lowercase keeping the first spelling, then sort by (lowercased, raw). */
function sortedUnique(names: string[]): string[] {
  const seen = new Set<string>();
  const unique: string[] = [];
  for (const name of names) {
    const lower = name.toLowerCase();
    if (seen.has(lower)) continue;
    seen.add(lower);
    unique.push(name);
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return unique.sort((a, b) => cmp(a.toLowerCase(), b.toLowerCase()) || cmp(a, b));
}

export function normalizedAuthors(names: Array<string | null>): string[] {
  return sortedUnique(strings(names).map((n) => n.trim()).filter(Boolean));
}

/** Trimmed and filtered (no `nyt:` style tags, no call numbers, no boilerplate), deduped, sorted, at most 15. */
export function normalizedSubjects(names: Array<string | null>): string[] {
  const kept = strings(names)
    .map((n) => n.trim())
    .filter((n) => n && !n.includes(':') && !n.includes('=') && /\p{L}/u.test(n) && !SUBJECT_STOPLIST.has(n.toLowerCase()));
  return sortedUnique(kept).slice(0, MAX_SUBJECTS);
}

export function embeddingText(input: BookEmbeddingInput): string {
  const title = input.title?.trim() || input.key;
  const raw = input.description?.trim() ?? '';
  const description = raw ? [...raw].slice(0, DESCRIPTION_CODE_POINTS).join('') : '';
  return [title, normalizedAuthors(input.authors).join(', '), normalizedSubjects(input.subjects).join(', '), description]
    .filter(Boolean)
    .join(SEPARATOR);
}

/** Lowercase hex SHA-256 of UTF-8 "<modelId>\n<text>". */
export async function embeddingHash(text: string, modelId: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${modelId}\n${text}`));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
