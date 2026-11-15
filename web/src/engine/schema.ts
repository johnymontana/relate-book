// What the web app adds to an imported store, and the graph model as the
// extension writes it (wishlist-to-graph/README.md, "Graph model").

/** The embedding model the app runs; stored beside each vector so a vector from another model is never searched. */
export const EMBEDDING_MODEL_ID = 'Xenova/all-MiniLM-L6-v2';
export const EMBEDDING_DIMENSIONS = 384;

export const BOOK_VECTOR_INDEX = 'book_embedding';
export const BOOK_TEXT_INDEX = 'book_text';
export const ITEM_TEXT_INDEX = 'item_text';
/** One fulltext index over the name of every "term" node; grounds names in questions (entity linking). */
export const TERM_TEXT_INDEX = 'term_text';

export const TERM_LABELS = ['Author', 'Subject', 'Genre', 'Series', 'Award', 'Place', 'Person', 'Publisher', 'Era', 'Country'] as const;

/**
 * Idempotent DDL applied after every load and every open. The first three are
 * declared by the extension too (a dataset normally brings them); repeating
 * them keeps the app working on a dataset exported without indexes.
 */
export const WEB_DDL: string[] = [
  `CREATE FULLTEXT INDEX ${BOOK_TEXT_INDEX} IF NOT EXISTS FOR (b:Book) ON EACH [b.title, b.description, b.first_sentence]`,
  `CREATE FULLTEXT INDEX ${ITEM_TEXT_INDEX} IF NOT EXISTS FOR (i:Item) ON EACH [i.title, i.byline]`,
  'CREATE POINT INDEX place_location IF NOT EXISTS FOR (p:Place) ON (p.location)',
  `CREATE FULLTEXT INDEX ${TERM_TEXT_INDEX} IF NOT EXISTS FOR (n:${TERM_LABELS.join('|')}) ON EACH [n.name]`,
  `CREATE VECTOR INDEX ${BOOK_VECTOR_INDEX} IF NOT EXISTS FOR (b:Book) ON (b.embedding) OPTIONS {indexConfig: {\`vector.dimensions\`: ${EMBEDDING_DIMENSIONS}, \`vector.similarity_function\`: 'cosine'}}`,
];

export interface LabelInfo {
  label: string;
  /** The property a caption or a lookup uses. */
  key: string;
  description: string;
  /** Properties worth telling a language model about (type, meaning). */
  properties: Array<{ name: string; type: string; note?: string }>;
}

export interface RelationshipInfo {
  from: string;
  type: string;
  to: string;
  properties?: Array<{ name: string; type: string; note?: string }>;
  description?: string;
}

/** The graph model, in the order a reader meets it. Drives the schema prompt, the lint and the UI legend. */
export const LABELS: LabelInfo[] = [
  {
    label: 'Book',
    key: 'title',
    description: 'a work (one per book, whatever the edition)',
    properties: [
      { name: 'title', type: 'STRING' },
      { name: 'subtitle', type: 'STRING' },
      { name: 'description', type: 'STRING' },
      { name: 'first_publish_year', type: 'INTEGER' },
      { name: 'ol_rating', type: 'FLOAT', note: 'Open Library average rating, 1 to 5' },
      { name: 'ol_rating_count', type: 'INTEGER' },
      { name: 'ol_want_to_read', type: 'INTEGER', note: 'Open Library readers who want to read it' },
      { name: 'ol_already_read', type: 'INTEGER' },
      { name: 'pages_median', type: 'INTEGER', note: 'page count' },
      { name: 'edition_count', type: 'INTEGER' },
      { name: 'key', type: 'STRING', note: 'unique id' },
    ],
  },
  {
    label: 'Author',
    key: 'name',
    description: 'a person who wrote a book',
    properties: [
      { name: 'name', type: 'STRING' },
      { name: 'birth_date', type: 'STRING' },
      { name: 'death_date', type: 'STRING' },
      { name: 'bio', type: 'STRING' },
      { name: 'occupations', type: 'LIST<STRING>' },
    ],
  },
  { label: 'Subject', key: 'name', description: 'a topic (many, free-form, mixed case)', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Genre', key: 'name', description: 'a literary genre, lower case (few)', properties: [{ name: 'name', type: 'STRING' }] },
  {
    label: 'Place',
    key: 'name',
    description: 'a place a book is set in, or an author was born in',
    properties: [
      { name: 'name', type: 'STRING' },
      { name: 'geocoded_label', type: 'STRING', note: 'canonical map name' },
      { name: 'location', type: 'POINT' },
    ],
  },
  { label: 'Person', key: 'name', description: 'a real or fictional person a book features', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Era', key: 'name', description: 'a time period a book is set during', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Series', key: 'name', description: 'a book series', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Award', key: 'name', description: 'an award', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Country', key: 'name', description: 'a country an author is a citizen of', properties: [{ name: 'name', type: 'STRING' }] },
  { label: 'Publisher', key: 'name', description: 'a publisher of an edition', properties: [{ name: 'name', type: 'STRING' }] },
  {
    label: 'Edition',
    key: 'title',
    description: 'the edition on the wishlist (every Edition is also an Item)',
    properties: [
      { name: 'title', type: 'STRING' },
      { name: 'format', type: 'STRING', note: "'Paperback', 'Hardcover', 'Kindle Edition', ..." },
      { name: 'price', type: 'FLOAT' },
      { name: 'currency', type: 'STRING' },
      { name: 'amazon_rating', type: 'FLOAT', note: '1 to 5' },
      { name: 'amazon_review_count', type: 'INTEGER' },
      { name: 'publish_year', type: 'INTEGER' },
      { name: 'language', type: 'STRING' },
      { name: 'isbn13', type: 'STRING' },
      { name: 'asin', type: 'STRING', note: 'unique id' },
    ],
  },
  {
    label: 'Item',
    key: 'title',
    description: 'a wishlist row (books are also Edition; other rows are plain Item)',
    properties: [
      { name: 'title', type: 'STRING' },
      { name: 'is_book', type: 'BOOLEAN' },
      { name: 'price', type: 'FLOAT' },
    ],
  },
  {
    label: 'Wishlist',
    key: 'title',
    description: 'the wishlist itself (one node)',
    properties: [
      { name: 'title', type: 'STRING' },
      { name: 'item_count', type: 'INTEGER' },
      { name: 'book_count', type: 'INTEGER' },
    ],
  },
];

export const RELATIONSHIPS: RelationshipInfo[] = [
  { from: 'Book', type: 'WRITTEN_BY', to: 'Author', properties: [{ name: 'role', type: 'STRING' }] },
  { from: 'Book', type: 'ABOUT', to: 'Subject' },
  { from: 'Book', type: 'IN_GENRE', to: 'Genre' },
  { from: 'Book', type: 'SET_IN', to: 'Place' },
  { from: 'Book', type: 'SET_DURING', to: 'Era' },
  { from: 'Book', type: 'FEATURES', to: 'Person' },
  { from: 'Book', type: 'PART_OF', to: 'Series', properties: [{ name: 'position', type: 'STRING' }] },
  { from: 'Book', type: 'WON', to: 'Award', properties: [{ name: 'year', type: 'INTEGER' }], description: "a book's own awards" },
  { from: 'Author', type: 'WON', to: 'Award', description: "an author's own awards, a direct relationship" },
  { from: 'Author', type: 'BORN_IN', to: 'Place' },
  { from: 'Author', type: 'CITIZEN_OF', to: 'Country' },
  { from: 'Edition', type: 'EDITION_OF', to: 'Book' },
  { from: 'Edition', type: 'PUBLISHED_BY', to: 'Publisher' },
  {
    from: 'Wishlist',
    type: 'CONTAINS',
    to: 'Item',
    properties: [
      { name: 'position', type: 'INTEGER' },
      { name: 'priority_label', type: 'STRING' },
      { name: 'comment', type: 'STRING' },
    ],
  },
];

/** The property that names a node of this label set, for captions and lists. */
export function captionKey(labels: string[]): string {
  for (const label of labels) {
    const info = LABELS.find((l) => l.label === label);
    if (info) return info.key;
  }
  return 'name';
}
