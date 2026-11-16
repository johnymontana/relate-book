# Relate Books — iOS app plan

An iPhone app over the reading-list graph that `wishlist-to-graph` builds. The
graph ships inside the app as a Relate store and the app embeds the Relate
engine in-process (no server). Everything the user does in the app — tags,
notes, reading status, added books — is written back into the same graph, so
the user's data and the enrichment data stay queryable together.

Status: **phases 0–5 implemented** (see Changelog); phase 6 pending. Written 2026-11-08 against relate
0.16.1 (local checkout at `../relatedb/relate`, commit `6a0c391`),
Xcode 27.2, iOS 26 simulators.

## 1. What was verified before planning

| Claim | How it was checked |
| --- | --- |
| Relate has a first-party Swift package (`Relate`, SwiftPM, iOS 16+/macOS 13+, Swift 6) wrapping the C ABI as a static XCFramework | `Package.swift` at the checkout root; `docs/api/swift/spec.md`; example app `examples/ios-snotel` |
| The XCFramework is already built locally with all three slices (`ios-arm64`, `ios-arm64_x86_64-simulator`, `macos-arm64_x86_64`) | `target/apple/RelateFFI.xcframework`, built 2026-11-07 |
| The released binary **cannot** be fetched: `github.com/relatedb/relate` and its `v0.16.1` asset return 404 | `curl -I` on both URLs |
| A `.rl` single-file bundle opens by path (`BundleVfs` when the path ends in `.rl`); it is exclusive to one process | `docs/guides/storage-engine.md` |
| Vector index (HNSW, cosine), `SEARCH … IN (VECTOR INDEX …) SCORE AS score`, and `db.index.vector.queryNodes` all work on a copy of `books.rl`, and the index survives reopening in a new process | ran against a scratch copy |
| `SEARCH` over the existing `book_text` fulltext index works; vector and fulltext results can be chained or fused | same scratch run |
| `POINT INDEX` + `point.withinBBox` + `point({latitude, longitude})` work on `Place` nodes | same scratch run |
| Apple's `NLContextualEmbedding` (iOS 17+) is available on this Mac: 512 dimensions, 256-token max, token-level output (needs mean pooling) | compiled a 10-line Swift probe |
| Store contents: 1,811 Books (982 with description, 1,579 with cover URL, 979 with an Open Library rating), 1,919 Authors, 8,380 Subjects, 693 Places (879 `SET_IN` + 433 `BORN_IN` edges), 2,002 Items | `relate query -d books.rl` |

Two gotchas found while verifying, to carry into implementation:

- The vector `SEARCH` form needs an explicit `SCORE AS score`; the bare
  `score` variable in the guide's example is undefined in 0.16.1.
- Vector `SEARCH … WHERE` may only filter on properties declared in the
  index's `WITH [...]`; anything else is filtered after the search in Cypher
  or Swift.

## 2. Product scope

Features the user asked for, each mapped to a phase in §8:

| Feature | Phase |
| --- | --- |
| Explore the list: browse, sort, filter, book / author / subject detail | 1 |
| Mark books as read (plus "reading", rating, dates) | 2 |
| Tags on books; browse the list by tag | 2 |
| Notes on each book | 2 |
| Semantic search with an on-device embedding model | 3 |
| Map view: find books by place | 4 |
| Add new books to the list | 5 |

Non-goals for v1: multi-device sync, sharing, re-scraping Amazon from the
phone, macOS build (possible later since the XCFramework has a macOS slice).

## 3. Key decisions

### 3.1 Platform and stack

- **iOS 18+**, SwiftUI, Swift 6 language mode, `@Observable` view models,
  Swift Testing. Xcode 27 is installed and the only simulators are iOS 26,
  so there is no cost to a modern floor.
- **Relate as a path dependency** on the local checkout with
  `RELATE_LOCAL_XCFRAMEWORK=1`, exactly like `examples/ios-snotel`. The GitHub
  release binary is not reachable, so the 160 MB+ static libraries are *not*
  committed; `scripts/build-xcframework.sh` in the checkout rebuilds them.
  (Dead-stripping removes most of that size from the final app; measure in
  phase 0.)
- **One actor owns the `Connection`** (`GraphStore`), the view models are
  `@MainActor` and `await` it. `Connection` is not `Sendable`, so Swift 6
  enforces this. A second actor owns the embedding model so embedding and
  querying can overlap.

### 3.2 Store provisioning

- `books.rl` (7 MB) is a bundled resource. First launch copies it to
  `Application Support/library.rl` with
  `FileProtectionType.completeUntilFirstUserAuthentication`; later launches
  open the copy. The bundled file is never opened in place (bundles are
  read-only and `.rl` needs a writable WAL).
- Every launch runs idempotent schema (`IF NOT EXISTS`) and a tiny migration
  table: `(:AppMeta {key:'schema_version', value})`.
- `checkpoint()` after every bulk step (first-launch embedding, imports).
- Refreshing from a newer wishlist export is phase 6: import a new `.rl` via
  the Files picker, open it with `Database(readOnlyPath:)` as a second
  database, and `MERGE` Items/Books/Authors by their unique keys. User data
  (tags, notes, status) lives on the user's store, so it is never lost.

### 3.3 Embedding model

Recommendation: **all-MiniLM-L6-v2 converted to Core ML** (384 dims, ~43 MB
fp16, Apache-2.0, trained for sentence similarity, L2-normalized output so
cosine = dot product). Conversion is a short `coremltools` script kept in the
repo (`ios/scripts/convert_embedding_model.py`); tokenization is a WordPiece
tokenizer written in Swift (~120 lines) over the bundled `vocab.txt`.
Pre-converted copies exist on Hugging Face as a cross-check.

Alternative kept behind the same `TextEmbedder` protocol: Apple's
`NLContextualEmbedding` (512 dims, nothing to bundle, Apple downloads the
asset on first use, needs mean pooling, multilingual). It is a BERT-style
token model, not a sentence-similarity model, so retrieval quality is
expected to be worse. Use it only if the Core ML conversion stalls.

Apple's Foundation Models framework (iOS 26) exposes no embeddings API, so it
is not an option for this.

Embedding happens **on device**: at first launch for the shipped books
(background, batched, resumable, search usable as soon as the first batch
lands), and incrementally for every book or note the user adds. The model
name is stored on each embedded node (`embedding_model`) so a model change
triggers a re-embed instead of mixing spaces.

As built (phase 3):

- `ios/scripts/convert_embedding_model.py`, with pinned
  `requirements-embedding.txt`, run by `uv`, converts
  sentence-transformers/all-MiniLM-L6-v2 @ `1110a243` to an fp16 ML Program
  with a fixed sequence length of 256.
- Mean pooling over the attention mask and L2 normalization are **in the
  graph**. The output is `embedding` [1, 384], so Swift does no pooling. It
  only rejects non-finite output and renormalizes.
- The wrapper uses its own additive mask, `(1 - mask) * -1e4`. BertModel's
  `finfo(float32).min` becomes -inf in fp16 and gave NaN on the CPU and GPU
  compute units, which includes the simulator.
- The compiled `.mlmodelc` is 45,228,025 bytes and ships pre-compiled: as a
  SwiftPM `.copy` resource for tests, and as a folder resource in the app.
- Vectors are stored as typed `VECTOR<FLOAT32>(384)`. The id in
  `embedding_model` is `all-MiniLM-L6-v2-coreml-fp16-256`.
- The Swift WordPiece tokenizer is about 300 lines, larger than estimated,
  because it covers BERT's control, CJK and punctuation rules. It matches
  Python on all 50 fixtures.

### 3.4 Search

Hybrid: vector `SEARCH` top-50 + fulltext `SEARCH` top-50 on `book_text`
and `item_text`, fused in Swift with reciprocal rank fusion, then filtered by
status/tag and joined to authors for display. (A format filter was planned
here; phase 3 shipped status and tag only and defers format, see the
phase 3 Changelog.) Relate's `COMBINE`
clause does this in-engine but is behind the `RELATE_PREVIEW=hybrid-search`
gate, so Swift-side fusion is the stable choice.

### 3.5 Map data

Open Library place strings are Library-of-Congress style headings
("Washington (State)", "Los Angeles (Calif.)", "États-Unis", "West (U.S.)",
"Mars"). Geocoding is done **once, on the Mac, by the extension**: a new
`--geocode` flag normalizes the heading (parenthetical → comma form, a small
synonym table for the French/duplicate headings), calls Nominatim at 1 req/s
with the `--contact` User-Agent, caches results in
`~/.cache/relate-book/geocode.json`, and writes `p.location = point(...)`,
`p.geocoded_label`, `p.geo_source`, plus a `POINT INDEX`. Unresolvable or
fictional places stay without `location` and are simply absent from the map.
About 700 places → roughly 12 minutes once. The app geocodes only places it
creates itself (phase 5), one at a time through `CLGeocoder`, cached on the
node.

## 4. Graph model additions

Existing model (unchanged): `(:Wishlist)-[:CONTAINS]->(:Item)`,
`(:Item:Edition)-[:EDITION_OF]->(:Book)`, `(:Book)-[:WRITTEN_BY]->(:Author)`,
`ABOUT→Subject`, `SET_IN→Place`, `FEATURES→Person`, `SET_DURING→Era`,
`IN_GENRE→Genre`, `PUBLISHED_BY→Publisher`, `PART_OF→Series`, `WON→Award`,
`(:Author)-[:BORN_IN]->(:Place)`, `CITIZEN_OF→Country`.

New, written by the app:

```
(:Book)   += reading_status: 'want' | 'reading' | 'read'   (missing = 'want'; never bulk-written)
             started_on, finished_on: date      (the user's local calendar day)
             status_changed_on: datetime        (UTC; "Recently updated" sort)
             my_rating: int 1..5
             added_on: datetime           (app-added books only)
             source: 'openlibrary' | 'amazon' | 'app'
             embedding: VECTOR<FLOAT32>(384), embedding_model: string, embedding_text_hash: string
(:Tag {name, color, created_on})                  name unique (case-insensitively, app-enforced)
(:Book)-[:TAGGED {on}]->(:Tag)
(:Note {id, text, created_on, updated_on, embedding, embedding_model, embedding_text_hash})   id unique (UUID string)
(:Book)-[:HAS_NOTE]->(:Note)
(:AppMeta {key, value})                           key unique
(:Place) += location: point, geocoded_label, geo_source   (extension --geocode)
```

Phase 4 details (as built):

- The extension's `--geocode` writes more than the planned three properties.
  On every located `Place`: `location` (WGS-84 `point`, srid 4326; the CLI
  prints `point({srid: 4326, x: lon, y: lat})`), `geocoded_label`,
  `geo_source` (`nominatim` | `manual`), `geo_status = 'ok'`, `geo_lat`,
  `geo_lon`, `geo_osm`, `geo_display_name`, `geo_place_type`, `geo_query`
  and `geo_region`. A heading that is not located keeps no `location` and
  gets `geo_status` `'skipped'` (fictional, non-terrestrial or not a place)
  or `'unresolved'`, plus `geo_query` and `geo_reason`.
- `geocoded_label` is the place a heading resolved to, shared by every
  heading that resolved to it (OSM identity plus a synonym table), and every
  node of a label carries the same point. The app shows one pin per label.
- Indexes: `POINT INDEX place_location` (planned) and a new range index
  `place_label` on `Place(geocoded_label)`. The app's `Schema.ddl` creates
  both idempotently; `Schema.currentVersion` stays **2** (no data step).
- The app writes none of these properties in phase 4.

Phase 5 details (as built):

- **Books the app adds** (`BookImporter`, one transaction of MERGE
  statements, never a DELETE) get the extension's Open Library property
  names (`enrich_from_open_library`) plus `source: 'app'`,
  `added_on: datetime($now)` and `match: 'isbn' | 'search' | 'manual'`.
  Only the ISBN flow writes edition facts as Book properties: `isbn13`,
  `isbn10`, `publisher`, `publish_date`, `publish_year`, `pages`,
  `physical_format`, `ol_edition_key`. Keys follow the extension:
  `/works/OL…W` when resolved, `manual:<lowercase uuid>` otherwise.
- **`added_on` on every node an import creates** (Book, Author, Subject,
  Place, Person, Era, Genre; `ON CREATE` only). Pre-existing nodes never
  get it. It is the provenance the DEBUG reset (and a future delete) uses.
- **No Item, Edition, Publisher or Series node** and no `PUBLISHED_BY`
  edge for app-added books. Every list and detail projection tolerates a
  Book without an Item (`coalesce(item.format, b.physical_format)`;
  "Added in app" where the price would be).
- **Authors**: `MERGE (au:Author {key}) ON CREATE SET …`; an existing
  author is never fetched or modified and only gains the `WRITTEN_BY` edge.
  Manual authors are `name:<slug>` with `source: 'app'` (the byline rule,
  so they link to existing `amazon-byline` authors).
- **Places**: only places an import creates are geocoded (CLGeocoder, one
  at a time, at most 10 per import). They get the extension's properties:
  `location`, `geocoded_label`, `geo_source` (`clgeocoder`, or `stub` in
  DEBUG `--stub-network`), `geo_status` (ok | unresolved | skipped),
  `geo_lat`, `geo_lon`, `geo_display_name`, `geo_place_type`, `geo_query`,
  `geo_region`, and `geo_reason` when not located. US and Canadian state
  abbreviations from CLGeocoder are spelled out first ("MA" →
  "Massachusetts"). Label rule (as `assign_labels`, labels compared by
  `fold`): reuse the label **and the point** of a located Place within
  1 km (so one label keeps one point); else the placemark's locality /
  administrative area / country that equals the heading's base name, else
  the base name; if a located Place already has that label (or its
  ", <qualifier/region>" form) within 50 km — 3,000 km for a country,
  1,000 km for a first-level division, since Apple's and Nominatim's region
  centres differ — reuse its label and point; only a same-named place
  elsewhere gets ", <qualifier or region>", then " (lat, lon)", appended.
- **No schema change**: no new DDL; `Schema.currentVersion` stays **2**.
- **Reset**: the DEBUG `--reset-user-data` transaction also deletes
  `Book {source:'app'}` and the importer-created nodes (`added_on` set),
  before the property REMOVEs, restoring the bundled counts exactly.

Phase 2 details (as built):

- `reading_status` is written only on a book the user touched. Choosing
  Want explicitly writes `'want'` on that one book. No code path writes to
  more than one `Book`, except the DEBUG-only `--reset-user-data`, which
  only `REMOVE`s.
- `started_on` and `finished_on` are Cypher DATE values for the user's local
  day. `status_changed_on`, `Tag.created_on`, `TAGGED.on`, `Note.created_on`
  and `Note.updated_on` are DATETIME values in UTC. Swift passes every time
  as an ISO-8601 string parameter (`date($today)`, `datetime($now)`), and app
  statements never call argument-less `date()` or `datetime()`.
- `Tag.color` holds a palette name: red, orange, yellow, green, teal, blue,
  purple or pink. A new tag gets a stable colour from an FNV-1a hash of its
  lowercased name. A missing or unknown value displays as gray.
- Tag names are trimmed and 1–40 characters. The `tag_name` constraint is
  exact-match, and the app also refuses a second tag whose name differs only
  in case.
- No schema change: `Schema.currentVersion` stays 1, because `tag_name`,
  `note_id` and `book_status` were created in phase 0.

Phase 3 details (as built):

- `embedding` is a typed `VECTOR<FLOAT32 NOT NULL>(384)` on Book and Note.
  `embedding_model` is `all-MiniLM-L6-v2-coreml-fp16-256`.
  `embedding_text_hash` is the lowercase hex SHA-256 of
  `"<model id>\n<text>"`.
- The indexer writes only these three properties, in batches of 32 with one
  `UNWIND` each. It never removes them. The DEBUG `--reset-embeddings` is
  the only exception, and it only `REMOVE`s.
- A note's write is guarded by `WHERE n.text = row.text`, so a vector
  computed from old text never lands on edited text.
- `Schema.currentVersion` is **2**. Migration 2 has no data step, because
  the vector DDL is idempotent. Both indexes appear below as built (`SHOW
  INDEXES` reports quantization BINARY, but 0.16.1 vector SEARCH is an
  exact flat scan).

App-added books reuse the extension's key scheme: `key = '/works/OL…W'`
when resolved in Open Library (so a later wishlist refresh merges onto the
same node), `manual:<uuid>` otherwise. They have no `Item`; the UI shows
"added in app" where it would show the Amazon price.

Schema the app creates on launch:

```cypher
CREATE CONSTRAINT tag_name  IF NOT EXISTS FOR (t:Tag)  REQUIRE t.name IS UNIQUE;
CREATE CONSTRAINT note_id   IF NOT EXISTS FOR (n:Note) REQUIRE n.id IS UNIQUE;
CREATE CONSTRAINT meta_key  IF NOT EXISTS FOR (m:AppMeta) REQUIRE m.key IS UNIQUE;
CREATE INDEX book_status    IF NOT EXISTS FOR (b:Book) ON (b.reading_status);
CREATE VECTOR INDEX book_embedding IF NOT EXISTS FOR (b:Book) ON (b.embedding)
  OPTIONS {indexConfig: {'vector.dimensions': 384, 'vector.similarity_function': 'cosine'}};
CREATE VECTOR INDEX note_embedding IF NOT EXISTS FOR (n:Note) ON (n.embedding)
  OPTIONS {indexConfig: {'vector.dimensions': 384, 'vector.similarity_function': 'cosine'}};
CREATE POINT INDEX place_location IF NOT EXISTS FOR (p:Place) ON (p.location);
CREATE INDEX place_label IF NOT EXISTS FOR (p:Place) ON (p.geocoded_label);
```

## 5. App architecture

```
ios/
  RelateBooks.xcodeproj            app target: compiles all of RelateBooks/ directly (module RelateBooks),
                                   links only the Relate package product (decided in phase 0, see below)
  Package.swift                    RelateBooksCore library + tests (runs on the Mac, like ios-snotel):
                                   path "RelateBooks", exclude ["App", "Resources", <every UI folder>]
  RelateBooks/
    App/            RelateBooksApp.swift, AppEnvironment (wires actors, bootstraps store)
    Resources/      books.rl, MiniLM.mlpackage, vocab.txt
    Graph/
      GraphStore.swift             actor: owns Connection; open/copy/migrate/checkpoint; query(_:_:)
      Schema.swift                 DDL + migrations
      Queries/                     one file per feature: LibraryQueries, BookQueries, TagQueries,
                                   NoteQueries, SearchQueries, MapQueries, ImportQueries
      Models/                      Book, BookSummary, Author, Subject, Place, Tag, Note, Item …
      Decoding/                    CypherValue → model helpers (node → Book, date/datetime bridges)
    Embeddings/
      TextEmbedder.swift           protocol: embed([String]) async throws -> [[Float]]; dimensions; modelID
      MiniLMEmbedder.swift         Core ML + WordPieceTokenizer
      AppleContextualEmbedder.swift NLContextualEmbedding + mean pooling (fallback)
      EmbeddingIndexer.swift       actor: finds un-embedded Books/Notes, batches, writes, reports progress
      BookEmbeddingText.swift      builds the text to embed from a Book + authors + subjects
    Search/         SearchService (hybrid RRF), SearchFilters
    OpenLibrary/    OpenLibraryClient (search, work, author, covers), BookImporter (port of the
                    extension's resolve/enrich logic)
                    As built (phase 5): HTTPTransport (+ URLSessionTransport), RequestGate, OpenLibraryClient,
                    OpenLibraryModels, ISBN, ImportDraft, BookImporter; DEBUG StubOpenLibraryTransport + fixtures
    Geo/            PlaceGeocoder (CLGeocoder, cached), MapRegionQuery
                    As built (phase 5): HeadingNormalizer, PlaceGeocoder protocol, CLPlaceGeocoder, PlaceLocator,
                    DEBUG StubPlaceGeocoder (the map queries stayed in Graph/Queries/PlaceQueries, phase 4)
    Features/
      Library/      LibraryView, filters/sort, BookRow
      BookDetail/   BookDetailView, StatusControl, RatingControl, TagPicker, NotesSection
      Authors/      AuthorView (books, birthplace, awards)
      Tags/         TagsView, TagBooksView
      Search/       SearchView (semantic + keyword, result explanations)
      Map/          MapView (MKMapView representable for clustering), PlaceSheet, PlaceSearch
      AddBook/      AddBookView (search OL, scan ISBN, manual), ImportProgress
      Settings/     store info, embedding progress, re-embed, import .rl
  Tests/            RelateBooksCoreTests (Swift Testing, in-memory + copied-store fixtures)
  scripts/
    convert_embedding_model.py     sentence-transformers → Core ML (coremltools), writes vocab.txt
    refresh_store.sh               copies the root books.rl into Resources (phase 4 ran the extension's --geocode pass on the root store first; --wikidata was not run)
```

Build graphs (decided in phase 0): the app target does **not** depend on the
`RelateBooksCore` package product. It compiles the same sources directly, so
core types stay `internal` (tests use `@testable import RelateBooksCore`) and
there is no public API surface to maintain. The cost is a rule every later
phase must follow: each new UI-only folder under `RelateBooks/` (`Features/`,
and `Embeddings/` if it bundles Core ML resources) is added to `exclude` in
`ios/Package.swift`; everything not excluded must compile on macOS and is
covered by `swift test`. Code that only the app compiles is not exercised by
`swift test`, so keep logic out of `App/` and `Features/`.

Concurrency rules: `GraphStore` and `EmbeddingIndexer` are actors; the UI
never calls Relate directly. Reads are small parameterized Cypher statements
returning scalar columns (not whole nodes) wherever a list is rendered;
detail screens may return nodes. Writes that touch several entities run in
`conn.transaction { }`.

## 6. Feature specs

### 6.1 Library (phase 1)

- Home tab lists books (cover, title, authors, format, status badge, price).
  Sort: title, author, date added (wishlist order via `Item.position`? not
  captured — fall back to title), OL rating, publish year. Filter chips:
  status, format (`Item.format`), tag, genre, "unresolved" (Amazon-only).
- Book detail: cover, title/subtitle, authors (tap → author), description,
  first publish year, pages, OL rating and want-to-read counts, Amazon rating
  and price with a "Open on Amazon" link (`Item.url`), subjects, places (tap →
  map centered there), people, eras, series, awards, publisher, editions on
  the wishlist (several Items can point at one Book).
- Author page: bio, dates, birthplace, citizenship, awards, books on the list.
- Subject / Genre / Series pages: books in that set.

Sample query (library list, one page):

```cypher
MATCH (b:Book)
WHERE ($status IS NULL OR b.reading_status = $status)
OPTIONAL MATCH (b)-[:WRITTEN_BY]->(a:Author)
OPTIONAL MATCH (i:Item)-[:EDITION_OF]->(b)
WITH b, collect(DISTINCT a.name) AS authors, collect(i)[0] AS item
RETURN b.key AS key, b.title AS title, authors, b.cover_url AS cover,
       coalesce(b.reading_status, 'want') AS status, item.format AS format,
       item.price AS price, item.currency AS currency
ORDER BY b.title SKIP $skip LIMIT $limit
```

### 6.2 Reading status, tags, notes (phase 2)

- Status segmented control on detail and swipe actions on rows. "Read" sets
  `finished_on = date($today)`, the local day passed from Swift (see §4 and
  Changelog D3: statements never call argument-less `date()`); optional star
  rating.
- Tags: look up the case-insensitive existing name first, then
  `MERGE (t:Tag {name})` with `MERGE (b)-[:TAGGED]->(t) SET r.on = …`
  (Changelog D4). Tags tab lists tags with counts; tapping shows that tag's
  books; tags can be renamed (one `SET`) and deleted (`DETACH DELETE`).
- Notes: a note list per book, create/edit/delete, Markdown-ish plain text.
  Notes are embedded too (phase 3) so "that book where I wrote about
  trains" works.

### 6.3 Semantic search (phase 3)

- Embedding text per book: `title · authors · top 15 subjects · description
  (first ~800 chars)`, truncated to 256 tokens. As built, the subjects are
  filtered (no `nyt:` or `collection:` tags, no call numbers, a short
  stoplist of catalogue headings), deduped and sorted alphabetically before
  the first 15 are kept. This rule won a real-model experiment: Project Hail
  Mary scored cosine 0.587 against 0.452 for the runner-up. 829 books have no
  description and fall back to title + authors + subjects, which still carries
  meaning (subjects average 11 per book).
- Indexer runs after launch when the store has un-embedded books: batches of
  32, one `UNWIND $rows … SET b.embedding = row.v, b.embedding_model = $m`
  per batch, progress published to Settings and as a thin banner on Search.
  As built, progress shows only on Search; the Settings screen moves to
  phase 6. Notes are embedded first, and a new or edited note is embedded
  within about a second.
- Search tab: one field. Results show the match reason (semantic score,
  keyword hit, or both). Query:

```cypher
MATCH (b:Book)
SEARCH b IN (VECTOR INDEX book_embedding FOR $q LIMIT 50) SCORE AS score
OPTIONAL MATCH (b)-[:WRITTEN_BY]->(a:Author)
RETURN b.key AS key, b.title AS title, collect(a.name) AS authors, b.cover_url AS cover, score
ORDER BY score DESC
```

  plus `SEARCH b IN (FULLTEXT INDEX book_text FOR $text LIMIT 50) SCORE AS s`,
  fused with RRF (k = 60) in `SearchService`, then status/tag filters applied.
  As built:
  - The keyword list is `book_text` plus `item_text` (item title and
    byline), each top-50, mapped to Book.
  - The keyword list is **gated**: a book enters fusion only if it contains
    every sanitized query term. Relate 0.16.1 fulltext ORs terms and ranks
    by raw term frequency, so ungated "Earth" titles pushed Project Hail
    Mary out of the top 5.
  - Notes add a third list: top-20 on `note_embedding`, mapped to the owning
    Book, kept when the note's cosine is at least 0.30.
  - Reasons: note, else both, else semantic or keyword.
  - Semantic scores are shown as cosine (`2·score − 1`).
- "More like this" on Book detail: the same vector query seeded with the
  book's own embedding, excluding itself.

### 6.4 Map (phase 4)

- Prerequisite: extension `--geocode` (see §3.5), re-export `books.rl`.
- `MKMapView` via `UIViewRepresentable` for native clustering of ~700
  annotations. On region change (debounced 300 ms):

```cypher
MATCH (p:Place)
WHERE p.location IS NOT NULL
  AND point.withinBBox(p.location, point({latitude: $s, longitude: $w}), point({latitude: $n, longitude: $e}))
OPTIONAL MATCH (b:Book)-[:SET_IN]->(p)
OPTIONAL MATCH (a:Author)-[:BORN_IN]->(p)
RETURN p.name AS name, p.location AS location, count(DISTINCT b) AS books, count(DISTINCT a) AS authors
```

- Pin color/size by book count; a toggle shows author birthplaces as a
  second layer. Tapping a pin opens a sheet with the books set there (and
  authors born there), each tappable.
- Place search field: `MATCH (p:Place) WHERE toLower(p.name) CONTAINS toLower($q)`
  (plus a fulltext index on Place.name if it feels slow), fly to the result.
- "Near me": `point.distance(p.location, $here) < $radius` with location
  permission, optional.
- As built (phase 4): pins group by `geocoded_label` and count **distinct**
  books and authors across the label's nodes (`collect(DISTINCT p)`, then
  `count(DISTINCT b)` / `count(DISTINCT a)`); summing per heading
  double-counts. The app fetches the visible box padded by 50 % per side.
  `point.withinBBox` does not wrap the antimeridian in relate 0.16.1, so a
  crossing box is split in two and merged by label. Place search matches
  headings and labels (with the `place_label` index). Near me is core-only
  (statement and test, no UI, no location permission); see the phase 4
  changelog entry.

### 6.5 Add books (phase 5)

Three entry points, one importer:

1. **Search Open Library** (`search.json?q=…&fields=key,title,author_name,author_key,cover_i,first_publish_year,isbn,subject,place`), tap a result.
2. **Scan an ISBN barcode** with VisionKit `DataScannerViewController`, then `search.json?q=isbn:…`.
3. **Manual** title + author (creates `manual:<uuid>`, no enrichment).

`BookImporter` ports the extension's work/author enrichment: `/works/{key}.json`
for description, subjects, places, people, times; `/authors/{key}.json` for
names and remote ids; covers from `covers.openlibrary.org`. It writes with
the same `MERGE` statements the extension uses, marks `source: 'app'`,
`added_on: datetime()`, geocodes any new place through `PlaceGeocoder`, and
asks `EmbeddingIndexer` to embed the new book. Network is only used here and
for cover images; everything else is offline.

As built (phase 5; details in the Changelog and `ios/README.md` "Add books"):

- A Library **+** pushes Add Book (Search / Scan / Manual); the flow ends
  by replacing itself with the book's detail ("Added to your library" or
  "Already in your library").
- Search uses a short field list (D1) and marks works already in the
  store "In your library". The ISBN flow checks the store first, then
  `q=isbn:<13>`, `q=isbn:<10>`, `/isbn/<13>.json` → `q=key:` (D5).
- `added_on` is `datetime($now)` from Swift (no argument-less
  `datetime()`); places are geocoded with CLGeocoder only when the import
  created them; the incremental embed runs on the note chain.
- Anonymous Open Library at one request per 1.05 s; no contact string yet
  (phase 6, with Settings). No delete-a-book (phase 6 candidate).

### 6.6 Polish and refresh (phase 6)

- Cover image cache on disk for offline browsing (URLCache with a large disk
  capacity is probably enough).
- Import a newer `books.rl` from Files (see §3.2) with a summary of what
  changed (new items, price changes, newly resolved books).
- Export notes and tags as Markdown or JSON.
- Share sheet for a book (title, authors, Amazon link).

## 7. Extension changes needed

Small, additive changes to `wishlist-to-graph.py`:

- `--geocode` flag (default off): Nominatim lookups for every `Place` without
  `location`, heading normalization, on-disk cache, `POINT INDEX`, and a
  `geocoded` count in the summary line. Honors `--contact` for the
  User-Agent, which Nominatim requires.
- Default `reading_status: 'want'` is **not** set by the extension; the app
  treats a missing status as "want" so a re-export never resets user state.
- Nothing else: embedding stays on device by design.

## 8. Phases and acceptance criteria

| Phase | Deliverable | Done when |
| --- | --- | --- |
| 0 Scaffold | Xcode project + `RelateBooksCore` package linking Relate via the local XCFramework; bundled `books.rl` copied and opened; schema migration | App launches on an iOS 26 simulator and shows 20 book titles; `swift test` passes on the Mac with an in-memory store; app binary size recorded |
| 1 Browse | Library list, filters/sort, Book/Author/Subject detail | Every facet in the store is reachable from a book; paging stays under 50 ms per query (`result.elapsedMs`) |
| 2 User data | Status, rating, tags, notes, Tags tab | Changes survive relaunch; tag rename/delete and note edit covered by tests |
| 3 Semantic search | Core ML model + tokenizer, indexer, hybrid search, "more like this" | All 1,811 books embedded on a simulator in under 5 minutes; "lonely astronaut saves earth" returns Project Hail Mary in the top 3; tokenizer tests match the Python tokenizer on 50 fixtures |
| 4 Map | `--geocode` in the extension, re-exported store, map tab | ≥ 85 % of places with ≥ 2 books have coordinates; Montana shows its 29 books; region query under 30 ms |
| 5 Add books | OL search, ISBN scan, manual, importer, incremental embed + geocode | A scanned ISBN appears in Library, Search and (if it has places) Map within one flow |
| 6 Polish | Offline covers, `.rl` import, export, share | Importing a re-run export keeps every tag/note/status and reports the diff |

Each phase ends with the core tests green and a short note appended to this
file's changelog section.

## 9. Risks and mitigations

- **Relate binary distribution.** The repo is private/404, so only the local
  XCFramework works. Mitigation: path dependency + `RELATE_LOCAL_XCFRAMEWORK=1`
  documented; `scripts/build-xcframework.sh` rebuilds it; re-check the public
  release when it exists and switch to the URL binary target.
- **Static library size.** `librelate_ffi.a` is 163 MB for `ios-arm64`.
  Dead-stripping should cut the shipped size drastically; measure in phase 0
  and decide whether App Thinning is enough.
- **Core ML conversion friction.** sentence-transformers → coremltools needs
  the right PyTorch version. Mitigation: pinned `requirements.txt` for the
  script, pre-converted Hugging Face models as a cross-check, Apple's
  `NLContextualEmbedding` behind the same protocol as a fallback.
- **Embedding quality on description-less books.** 829 books embed from
  title + authors + subjects only. Acceptable; the keyword half of hybrid search
  covers exact titles.
- **Place heading ambiguity.** "West (U.S.)", duplicated headings
  (`United States` / `USA` / `États-Unis`), fictional places. Mitigation:
  synonym table merges known duplicates at geocode time by sharing a
  `geocoded_label`; the map groups by label; fictional places simply lack a
  location.
- **Open Library rate limits in-app.** 1 req/s anonymous. Mitigation: one
  book at a time, visible progress, a `contact` string in the User-Agent set
  from Settings.
- **Non-English Open Library titles** on a few books ("L'étranger"). The
  Item title is English; the UI prefers the Item title when the Book title's
  language differs, or shows both.
- **Single-process store.** Never open the store from an app extension or
  widget while the app runs; widgets (if ever) read a JSON snapshot instead.
- **No cloud sync.** Syncing a `.rl` WAL through iCloud would corrupt it.
  v1 is single-device; the export in phase 6 is the backup path.

## 10. Assumptions made

- iPhone first; iPad adapts via SwiftUI layouts but is not designed for.
- Single user, English UI.
- The shipped store is the one already exported to `./books.rl`; re-export
  with `--geocode` before phase 4.
- The embedding model is English-only (MiniLM); the handful of non-English
  descriptions will search poorly, which is acceptable.

## Changelog

- 2026-11-08 — plan written; Relate Swift SDK, vector/point indexes and
  Apple embedding availability verified on this machine.
- 2026-11-08 — phase 0 done. `swift test` green on the Mac (11 tests in 3
  suites). The iPhone 17 simulator (iOS 26.2) shows the first 20 of 1,811
  titles and logs `RelateBooks: opened store with 1811 books`. Release
  arm64 binary `RelateBooks.app/RelateBooks` is 21,699,800 bytes (20.7 MiB;
  details in `ios/README.md`). Deviations: Relate is a relative path
  dependency (`../../../relatedb/relate`) and needs
  `RELATE_LOCAL_XCFRAMEWORK=1`; `scripts/refresh_store.sh` only copies
  `books.rl` (the `--geocode --wikidata` run moves to phase 4); the app target
  compiles sources directly instead of depending on `RelateBooksCore` (§5);
  `GraphStore` has no transaction passthrough yet; it replaces its connection
  after a stage `.internal` engine error.
- 2026-11-08 — phase 1 ("Browse") done.
  - **Tests.** `swift test` is green on the Mac: 28 tests in 6 suites. The fixtures are an in-memory graph covering every facet, including a book with two items, a book with no author, an unresolved `amazon:` book, and a non-English title. They test each sort, filter and paging, plus the detail, author and term queries, launch-argument parsing and the view models.
  - **Perf suite.** It bootstraps a temp copy of the bundled `books.rl` and times 98 queries by engine-reported `elapsedMs` (median of 5 warm runs, debug build, this Mac). All are under 50 ms; the slowest is 26.3 ms. The worst median per query family:
    - `libraryPage`: author sort 26.3 ms and wishlist sort 25.7 ms (both with search "an"); title 21.0, rating 20.6 and year 20.6 ms (with all filters). An unfiltered page is 7–20 ms, deep pages (SKIP 1760) take the same time, and the unresolved filter takes 1.4–1.7 ms.
    - `libraryCount`: up to 20.8 ms.
    - `formatFacets`: 1.1 ms. `genreFacets`: 0.1 ms.
    - `bookDetail`: 5.4–5.7 ms. `authorDetail`: 0.1 ms. `authorBooks`: 0.4 ms or less.
    - `termBooks`: up to 3.7 ms (country=United States). `termSummary`: up to 2.7 ms. `termAuthors`: up to 2.8 ms.
  - **Simulator.** On the iPhone 17 (iOS 26.2), screenshots in `ios/docs/phase1-*.png` show:
    - the Library list with covers, authors, formats, badges and prices;
    - `--open-book /works/OL17876078W`: author, subjects and the $12.99 Amazon price;
    - `--open-book /works/OL59800W` (The Left Hand of Darkness): series Hainish Cycle #4, and awards Otherwise 1995, Hugo 1970 and Nebula 1970;
    - `--open-author /authors/OL31353A`: Le Guin's two books, dates and bio;
    - `--open-term "place=United States"`.
  - **Decisions.**
    - Wishlist order is `min(CONTAINS.position)`. The §6.1 note about `Item.position` "not captured" is outdated, because the position is on the relationship.
    - The author sort uses the surname: the part before a comma, otherwise the last word before any parenthetical.
    - Search is a lowercase `CONTAINS` match against book titles, author names and item titles, run as a UNION of label scans; that measured about 3x faster than per-book `EXISTS`. The fulltext indexes were not used, because they are token-based, not substring-based. Search starts at 2 characters, because "a" matches 1,792 of 1,811 books and was the slowest query shape (about 40–48 ms).
    - Only active filters are spliced into the WHERE clause, as fixed fragments; every value is a parameter.
    - Detail screens use pattern comprehensions, which return collected lists of maps. In a WHERE clause they were very slow (seconds), so list filters use `EXISTS`.
    - The rule for non-English titles: show `Book.title`, plus the first item's title as a subtitle when it differs after case and diacritic folding and is not just the book title with a subtitle added.
    - The "Tag" filter chip moves to phase 2, along with tags.
    - Places open a term page (books set there plus authors born there) marked "Map in phase 4". Countries reach their citizens' books.
    - Core view models (`ViewModels/`), routes and `LaunchOptions` (`Navigation/`) compile in `RelateBooksCore` and are tested. `Features/` is UI-only and excluded from SwiftPM.
    - Launch arguments: `--open-book`, `--open-author`, and `--open-term kind=name`.
- 2026-11-08 — phase 1 review fixes.
  - **Duplicate authors.** The store has separate Author nodes with the same name on one book (29 books; for example Getting Things Done has three "David Allen" nodes). List rows now use `collect(DISTINCT a.name)`. Book detail keeps one `AuthorRef` per folded name: the node with the most data (image 4, bio 2, birth date 1; ties go to the smaller key). Tapping the author opens the page that has content.
  - **Format filter.** While a format filter is on, the row shows the first item in that format, with its price and thumbnail (`ORDER BY CASE WHEN i.format = $format …, c.position`). `itemCount` and the wishlist position still cover every item. CLI check with Hardcover: 654 books match and 0 show another format (it was 33).
  - **Images.** Every `Author.image_url` (414) is `http://commons.wikimedia.org/…`, which ATS blocks. `Row.imageURL` upgrades it to https and adds `?width=400` to Wikimedia `Special:FilePath` originals. No ATS exception was added.
  - **Search.** `setSearchText` cancels the pending debounce before comparing text. Typing a letter and deleting it now leaves the applied search alone.
  - **Author sort.** Surnames skip the suffixes Jr., Sr., II, III, IV, PhD and MD, and "King, Jr." sorts as king. The suffix-aware form runs only for names ending in '.', r, R, I, V or D. Unguarded, it added about 10 ms to every author-sorted page; with the guard it adds about 3–4 ms. Documented: with co-authors, the alphabetically smallest surname counts.
  - **Lifespan.** Birth and death dates come from one source. When only Wikidata has the death date, Wikidata's birth date is used with it, and ISO dates display like Open Library dates ("10 January 2024").
  - **UI fixes.**
    - `CoverImage` no longer treats a cancelled load as a failure, and it resets when the URLs change.
    - `PagedBooks` leaves `hasLoaded` unset after a cancelled load, and prefetch checks only the last 10 rows.
    - Term pages get "Show all N" for author lists longer than 50.
    - `openRoute` is now an `Equatable` `OpenRouteAction` struct instead of a bare closure, which clears the `@Entry` closure warning.
  - **Chip navigation evidence.** A new XCUITest target, `RelateBooksUITests`, taps the "science fiction" genre chip and the "Gethen" place chip on The Left Hand of Darkness and checks each term page. Screenshots: `ios/docs/phase1-chip-genre.png` and `ios/docs/phase1-chip-place.png`.
  - **Tests and perf.** `swift test` is green: 35 tests in 7 suites, with new regression tests for each fix. The perf suite still times 98 queries, all under 50 ms; the slowest median is 30.4 ms. Worst median per family:
    - `libraryPage`: author 30.4 ms (search "an"), wishlist 26.2 ms (search "an"), rating 21.3 ms, title 20.0 ms, year 19.9 ms (all three with every filter on). An unfiltered author-sorted page takes about 25 ms, up from 21 ms.
    - `libraryCount`: 19.8 ms.
    - `formatFacets`: 1.1 ms. `genreFacets`: 0.1 ms.
    - `bookDetail`: 6.4 ms. `authorDetail`: 0.2 ms. `authorBooks`: 0.4 ms.
    - `termBooks`: 3.9 ms. `termSummary`: 2.2 ms. `termAuthors`: 2.4 ms.
- 2026-11-08 — phase 2 ("User data") done.
  - **Features.**
    - Book detail has a "Your Reading" section, with a Want / Reading / Read segmented control, the dates for the current status, and a 1–5 star rating. It also has a Tags section (chips, plus a picker sheet that adds an existing tag or creates a new one) and a Notes section (plain multi-line text, newest first, with add, edit and delete).
    - Library rows have status swipe actions and show your rating.
    - The Library has a Tag filter chip and a "Recently updated" sort.
    - A new Tags tab lists tags by count, then name. Tapping a tag opens its books. Tags can be renamed, recoloured and deleted.
    - Launch arguments: `--reset-user-data` (DEBUG only) and `--open-tab tags|library`.
  - **Decisions.**
    - D1. **Status transitions.** One statement sets `reading_status` and `status_changed_on`.
      - Reading sets `started_on` only if it is unset.
      - Read sets `finished_on` and keeps `started_on`. It does not back-fill a start date.
      - Want keeps both dates as history.
      - The UI shows only the dates for the current status.
      - Re-reading (Read -> Reading) keeps the old `started_on`, and the next Read overwrites `finished_on`. There is no per-read history.
      - Setting the same status again is a no-op.
    - D2. **No defaults are written.** A missing `reading_status` means want. No code path writes to more than one `Book`; the only exception is the DEBUG reset, which only removes properties.
    - D3. **Timestamps.** Swift passes ISO-8601 strings. `$now` is UTC with milliseconds and is stored with `datetime($now)`. `$today` is the user's local day and is stored with `date($today)`. Statements never call argument-less `date()` or `datetime()`, because the engine clock is UTC and `date()` would give tomorrow's date on a US evening. The clock and calendar are injectable, so tests are deterministic.
    - D4. **Tag names.** Names are trimmed, Unicode NFC-normalised, and 1–40 characters.
      - Uniqueness is case-insensitive: add and create reuse the case-insensitive match, and rename refuses a name another tag already has (a case-only rename of the same tag is allowed).
      - Removing a tag from its last book keeps the tag, with count 0.
      - Tags list order: count desc, then name.
    - D5. **Tag colours.** A fixed palette of 8, stored as the colour's name. A new tag's colour is a stable FNV-1a hash of its name. The colour can be changed from the Tags tab context menu.
    - D6. **Notes.** Plain text, trimmed; an empty note is refused. The id is a UUID generated in Swift. Order is `updated_on` desc, so an edited note moves to the top. Deleting a missing note is a no-op; updating one throws.
    - D7. **"Recently updated".** Sorts by `status_changed_on` desc, with untouched books last. Only status changes count; rating, tag and note edits do not move a book.
  - **Review leftovers (low, not fixed).** A library page fetched while a swipe or detail write is in flight can show that one row's previous status until the next reload. A pushed tag-books list does not pop when its tag is renamed or deleted from elsewhere.
    - D8. **Optimistic updates.** Status, rating, tag add/remove, note delete and tag delete update the screen immediately. After the write, the screen takes the re-read value. On error it restores its snapshot and shows an alert, and a mutation counter drops stale results. Note save and tag create/rename are not optimistic: the sheet or alert waits for the write and stays open on error, so typed text is not lost.
    - D9. **Cross-screen consistency.** A main-actor `UserDataController` performs every write and publishes a `UserDataChange` to subscribers, which it holds weakly.
      - List models patch rows in place, so the scroll position is kept.
      - A list reloads on appear when a change could move rows: a status filter, the recently-updated sort, or a tag filter.
      - The tag models reload immediately.
    - D10. **Transactions.** `GraphStore.transaction([Statement])` is used only by the reset. Every other write is a single statement.
    - D11. **Checkpoint.** The store checkpoints when the scene goes to the background and after the DEBUG reset, never per write. Writes are durable through the WAL: the UI test relaunch reads them back without a checkpoint.
    - D12. **Status filter.** Want uses `coalesce(b.reading_status,'want') = $status`. Reading and Read use plain equality, which can use the index.
    - D13. **No schema change.** §4 is updated with `status_changed_on`, the date and datetime types, the colour palette and case-insensitive tag uniqueness.
  - **Relate 0.16.1 issue.** In one explicit transaction, deleting a node that was created earlier in the same transaction panics the engine with "update counters are non-negative: TryFromIntError" (binding.rs:62) and poisons the handle (stage `.internal`). Not affected: deleting nodes that already existed, auto-commit create-then-delete, and rollback. Rule: no transaction may create and then delete the same entity. Nothing in the app or tests does this. Filed upstream as LABS-1188 (2026-11-08) with a four-case Swift repro.
  - **Measured while designing** (CLI and Swift harness on a seeded copy, median `elapsedMs`):
    - Tag-filtered page, starting at the Tag: 1.9 ms (200-book tag), 2.2 ms (same tag at skip 160), 0.25 ms (3-book tag). The rejected per-book `EXISTS` form took 10.3 / 6.8 ms.
    - Tag count: 0.05 ms (the `EXISTS` form took 8.7 ms).
    - Recently-updated page: 7.6 ms (also at skip 1760), 1.7 ms with status=read, 17.7 ms with search "an", 19.8 ms with a tag plus search "an", 26.3 ms with every filter plus a tag.
    - `tags()`: 0.11 ms. `bookUserData`: 0.05 ms. `bookDetail` with the user columns: 5.4–5.5 ms (unchanged).
  - **Tests.** `swift test` is green: 58 tests in 10 suites. New suites: user data queries (13), persistence across reopen (2), user data view models (7), and a launch-flag test.
    - The persistence test writes a status, a tag and a note to a temp-directory store, releases it, reopens it and reads them back.
    - Also covered: tag rename and delete, note edit, filter by tag, and the recently-updated sort.
  - **Perf.** The perf suite now times 153 queries. "PERF summary: 153 queries; slowest median 27.65 ms (libraryPage author [text=an] p0); slowest cold 28.05 ms". Worst median in each new family:
    - Recently updated: 25.2 ms (every filter plus a tag), 19.3 ms (every filter), 18.0 ms (tag "Big" plus search "an"), 7.0 ms unfiltered, 7.3 ms at skip 1760.
    - Tag filter: 25.4 ms (title sort, every filter plus a tag), 3.7 ms for the 200-book tag alone, 0.3 ms or less for a 3-book tag.
    - `libraryCount` with a tag: 23.2 ms (every filter plus a tag), 0.05 ms for the tag alone.
    - `bookUserData`: 0.05 ms. `addTag` on an existing tag: 0.09 ms.
  - **UI tests.** `RelateBooksUITests` has 4 tests, all passing on the iPhone 17 (iOS 26.2):
    - `testLibrarySwipeSetsStatus`: a leading swipe sets Reading from the Library.
    - `testUserDataSurvivesRelaunch`: launches with `--reset-user-data`, sets Read, gives 4 stars, adds the tag "Favorites" and adds a note. It relaunches without the reset flag and checks that all of it is still there. It then launches with `--open-tab tags`, finds "Favorites (1)", and filters the Library by the tag.
    - After the run, the simulator's `library.rl` has `reading_status` on exactly one book (`/works/OL59800W`: read, 4 stars, finished 2026-11-08). It has one Tag ("Favorites", yellow) and one Note.
  - **UI deviations from the spec.**
    - The tag picker and note editor sheets are presented from `BookDetailView`, not from their List sections; a `.sheet` on a List `Section` did not present.
    - "Add Tag" is an icon-and-text HStack in the chip row, not a `Label`; inside a List row, a `Label` measured wrongly in `FlowLayout`. Its accessibility frame spans the row, but its hit area is the text, so the UI test taps the text.
    - "Add Note" is the last row of the Notes section, so the newest note sits right under the section header and fits in the detail screenshot.
  - **Screenshots** (`ios/docs/`):
    - `phase2-book-detail.png`: Read, "Finished Nov 8, 2026", 4 stars, the Favorites chip and the note.
    - `phase2-tags.png`: the Tags tab with Favorites and count 1.
    - `phase2-library-tag.png`: the Library filtered by Favorites, showing "1 book" and the Read ★4 row.
    - `phase2-swipe.png`: a swipe set Reading.
- 2026-11-08 — phase 3 ("Semantic search") done.
  - **Features.**
    - A third tab, **Search**, has one field (search on submit, plus typing debounced at 350 ms), an empty state with five example queries, and Status and Tag filters in the toolbar.
    - Result rows reuse `BookRow`, plus a reason line: "Semantic 0.59", "Keyword (title or author)", "Semantic 0.52 + keyword" or "Your note: “…”".
    - While the first index runs, a thin banner reads "Indexing 412 of 1,811 books…", and the results header adds "Semantic results cover N of 1,811 books so far".
    - Book detail has **More like this**: a horizontal strip of the 10 nearest books, between Description and Details.
    - New launch arguments: `--open-tab search`, `--search "<text>"`, `--wait-for-index`, and `--reset-embeddings` (DEBUG only).
  - **Model.**
    - all-MiniLM-L6-v2 @ `1110a243`, Apache-2.0, converted by `ios/scripts/convert_embedding_model.py` (pinned with uv: torch 2.7.0, coremltools 9.0, transformers 4.56.2, sentence-transformers 5.1.1, numpy 2.2.6, Python 3.12.12). The script also writes the 50 tokenizer fixtures and the 20 reference embeddings.
    - fp16 ML Program with sequence length 256; pooling and L2 norm are in the graph.
    - `.mlmodelc` is 45,228,025 bytes. Min cosine against sentence-transformers is 0.999972 (`.all`) and 0.999975 (`.cpuOnly`).
    - The fp16 attention-mask fix is in §3.3.
  - **Decisions.**
    - D1. **Model output.** The graph outputs the pooled and normalized embedding. Swift rejects non-finite output and renormalizes.
    - D2. **Storage.** Book and Note `embedding` are `VECTOR<FLOAT32>(384)`, with `embedding_model` and `embedding_text_hash` (SHA-256 of `"<model>\n<text>"`). Notes gain the hash (§4).
    - D3. **Indexer.** It starts once the session is ready, at utility priority.
      - It scans 200 books per page plus all notes, without the model. If nothing is stale, the pass completes without loading the model.
      - Otherwise it embeds notes first, then books in batches of 32 with one UNWIND write each. The embedder is called in chunks of 8, so a search query waits for at most one chunk.
      - It checkpoints once at the end.
    - D4. **Background.** On `.background` the app pauses indexing and checkpoints. On `.active` it resumes, and the store holds the progress. There is no BGProcessingTask.
    - D5. **Memory warning.** The app pauses indexing and keeps the model. `IndexingModel.pauseForMemoryWarning()` resumes by itself after 10 s (a warning does not change scenePhase); going to the background in between cancels that resume, and `.active` resumes as in D4.
    - D6. **Notes.** Embedding is asynchronous, through a `UserDataController` subscription. The write is guarded by `WHERE n.text = row.text`. The UI run shows the note that UserDataUITests added was embedded.
    - D7. **Search while indexing** uses what is embedded so far, and the banner and header say so. When indexing completes, `SearchModel.indexingDidComplete()` runs the current query again (typed or launch `--search`), so partial results never stay on screen without the caveat.
    - D8. **No model.** Search is keyword only, with the notice "Semantic search unavailable — showing keyword matches."
    - D9. **Hybrid search.** Three lists:
      - vector top-50;
      - keyword: `book_text` top-50 plus `item_text` top-50, **gated** to books that contain every term;
      - notes: top-20 with cosine ≥ 0.30.

      They are fused with RRF (k = 60, equal weights), and an exact tie goes to a keyword title or author match. Reasons are note, else both, else semantic or keyword. Filters apply after fusion in the hydrate query. Up to 50 results.
    - D10. **Fulltext sanitizer.** Lowercase runs of letters and digits; drop 1-character tokens and stopwords; dedupe; keep at most 8 terms; with none left, skip fulltext.
    - D11. **More like this** is one statement with the stored vector as `FOR q`. It returns the top 10 and excludes the seed. An un-embedded book shows "Similar books appear once indexing finishes."
    - D12. **Embedding text** is `title · authors · ≤15 filtered alphabetical subjects · first 800 scalars of the description` (§6.3).
    - D13. **`--reset-embeddings`** (DEBUG) lets SearchUITests time a full rebuild even after earlier tests indexed the store.
    - D14. **No Settings progress screen** (moved to phase 6). Progress shows only on Search.
    - D15. **Schema version 2.** Two vector indexes were added, and the migration has no data step.
  - **Relate 0.16.1 findings.**
    - V2. Vector SEARCH `SCORE` for cosine is rebounded to `(1 + cos) / 2`, so Swift reports `2·score − 1`.
    - V3. A typed `.vector(.floats(dtype: .float32, …))` parameter is stored as `VECTOR<FLOAT32 NOT NULL>(384)`.
      - Every value must be exactly representable as Float32, otherwise the engine raises "not exactly representable as FLOAT32".
      - `vector(x, 384, FLOAT32)` rejects a VECTOR input ("requires a numeric list").
    - V4. A query vector of the wrong dimension throws `VectorIndexDimensionalityMismatch`. A **stored** vector of the wrong dimension is accepted and then silently skipped by search, so Swift validates before writing. A null `$q` returns 0 rows.
    - V6. Fulltext tokenizes into lowercase alphanumeric terms, ORs them and scores by raw term frequency.
      - There is no stemming, no accent folding and no operator syntax, and every input is accepted.
      - A query costs about 16 ms (`book_text`) or 12 ms (`item_text`) whatever the query is.
      - A pattern comprehension in the RETURN right after a fulltext SEARCH costs about 4 ms per row, so the fulltext statements (`SearchQueries.bookText` / `itemText`) return scalar columns only. Authors and covers are joined afterwards in the separate hydrate statement over the fused keys (`LibraryQueries.summaryProjection()`).
    - V7. **Store growth.** A full index grows the store from 7.3 MB to about 46–48 MB, mostly WAL and checkpoint overhead. A full re-embed reaches about 62 MB, and a clone is 16 MB. This is accepted for phase 3; compaction by clone moves to phase 6.
  - **Measurements.**
    - Engine, real store copy, Swift SDK, median `elapsedMs`:

      | Statement | Median |
      | --- | --- |
      | Vector top-50, 400 embedded | 2.7 ms |
      | Vector top-50, 1,811 embedded | 3.9 ms |
      | `book_text` | 15.6–16.7 ms |
      | `item_text` → Book | 11.0–11.6 ms |
      | Notes top-20 | 0.31 ms |
      | More like this | 2.9 ms (400) / 4.2 ms (1,811) |
      | Hydrate with a filter | 1.1–2.0 ms |
      | Batch write of 32 vectors | 5.9–6.3 ms |
      | Scan page of 200 | 4–6 ms |

    - PerfTests, pre-review run (the review-fixes run below supersedes it), 402 fake-embedded books:

      | Query | Median |
      | --- | --- |
      | semantic top50 | 2.96 ms |
      | bookText "lonely astronaut saves earth" | 18.07 ms |
      | itemText | 12.69 ms |
      | notes top20 | 0.31 ms |
      | moreLikeThis Project Hail Mary | 3.34 ms |
      | hydrate 150 keys, status=want | 2.37 ms |
      | writeBooks 32 rows | 6.19 ms |

      "PERF summary: 170 queries; slowest median 30.28 ms (libraryPage author [text=an] p0)". Every query is under 50 ms.
    - One hybrid search with the real model, including embedding the query, takes 37–51 ms on the Mac.
    - Real MiniLM per text on the Mac (EmbedderTests): median 2.30 ms, p90 3.15 ms with `.all`; median 3.76 ms, p90 4.41 ms with `.cpuOnly`. Model load is 37–93 ms on the Mac and 130–230 ms on the simulator.
    - **Indexing on the simulator** (iPhone 17, iOS 26.2, fresh install, final UI run, Mac load average about 14):
      - `PHASE3_INDEX_ELAPSED_SECONDS=164.7` from launch.
      - The app's own clock: "1811 embedded this launch in 161.2 seconds". The os_log line is `RelateBooks: index complete: 1811/1811 books, 1811 embedded this launch in 161.2 s`.
      - An earlier SearchUITests-only run took 166.3 s (163.3 s by the app). The budget is 300 s.
      - The relaunch reported "0 embedded this launch in 0.2 seconds" with no banner.
    - **Store size.** 7,315,456 bytes before; 45,838,336 bytes for `library.rl` on the simulator after the UI run.
    - **App size** (Release, arm64): the executable grew from 21,699,800 to 25,082,640 bytes (20,339,072 stripped). The `.app` grew from 28 MB to 74 MB, of which the model is 45.2 MB.
  - **Results.**
    - "lonely astronaut saves earth" gives Project Hail Mary (semantic 0.59), then The Martian (0.45), We Who Are About To… (0.44) and Dead Astronauts (0.40).
    - More like this for Project Hail Mary: We Who Are About To…, Dead Astronauts, The Book of M, Theft of Fire, Armada, ….
    - Keyword queries ("le guin", "weir", "sapiens", "getting things done", "kim stanley robinson") put the expected book first.
  - **Deviations.**
    - There is no Settings progress screen (D14).
    - `--reset-embeddings` is a new DEBUG flag (D13).
    - Keyword gating replaces plain RRF (D9). Ungated, Project Hail Mary fell out of the top 5.
    - `item_text` is included in the keyword list.
    - A keyword title or author match wins exact RRF ties. Without that, "weir" put a semantic-only hit ahead of The Martian.
    - The reason icons come from core `MatchReason.systemImage`: sparkles, textformat, sparkle.magnifyingglass and note.text.
    - The search field is a plain `TextField`, not `.searchable`, because the Library tab already owns one.
    - The tokenizer is about 300 lines (planned: about 120).
    - No **format filter** in search: §3.4 listed status/tag/format, phase 3 ships status and tag. Format (`Item.format`, which the Library tab already filters by) is deferred to phase 6 polish: it needs the format facets in the search filter menu and an Item join in the hydrate statement, and it was not needed for the phase 3 acceptance. §3.4 is updated.
  - **Tests.**
    - `swift test` is green: "Test run with 124 tests in 18 suites passed" (was 58 in 10; 119 before the review fixes below). It covers:
      - the tokenizer on 50 of 50 fixtures and the embedder on 20 of 20 references (cosine ≥ 0.99, unit length);
      - the embedding-text builder and its hash;
      - the indexer: embeds all, no-op on a second run, re-embeds on a hash change, resumes after cancellation, writes only the three properties;
      - search: vector neighbours, RRF and reasons, filters, the sanitizer with quotes, colons, parens and asterisks, more-like-this excluding the seed, and the view models.
    - UI tests: 5 of 5 pass on the iPhone 17 (`SearchUITests.testSemanticSearchIndexAndRelaunch`, 190 s).
    - After the run, `library.rl` has `count(b.embedding) = 1811` and `count(b.embedding_model) = 1811`. `reading_status` is set on 1 book (`/works/OL59800W`), and there is 1 note, which is embedded. `schema_version` is 2.
  - **Screenshots** (`ios/docs/`):
    - `phase3-indexing.png`: the banner at "Indexing 32 of 1,811 books…", the empty state and the status line.
    - `phase3-search.png`: Project Hail Mary first, with "Semantic 0.59".
    - `phase3-more-like-this.png`: Project Hail Mary's More like this strip.
  - **Review fixes** (after the phase 3 review; all re-verified, screenshots refreshed from this run):
    - Tokenizer, Greek capital sigma: Swift applied Python's context-sensitive Final_Sigma rule (word-final Σ → ς, `##ς` 19579). transformers lowercases one character at a time before BasicTokenizer runs (`PreTrainedTokenizer.tokenize`), and the fast BertNormalizer does the same, so the reference ids use σ (`##σ` 29733). Swift now lowercases per scalar with no context rule.
    - Tokenizer, special tokens: the five special-token literals are now cut out of the raw text wherever they occur, even inside a word, like the added-token trie (`"hello[SEP]world"` → hello, [SEP], world). A lowercase `[mask]`, or a special broken by a format character, is ordinary text.
    - Both tokenizer cases are pinned by new script fixtures `greek_uppercase_sigma` and `special_tokens_inline`. They replace the redundant `titlecase` and `accent_ete` cases, so there are still 50. The script gained `--fixtures-only`, which was used to rewrite the fixtures; `embedding_fixtures.json` came out byte-identical and the model was not rebuilt.
    - `SearchModel.setText` compared new text against the last search *started*. Editing back to an in-flight query inside the debounce window cancelled the newer scheduled search and scheduled nothing, so the in-flight answer was dropped as stale and the screen stayed on `.loading` or on old results. It now compares against the latest *scheduled* search, and it no longer cancels when the trimmed text is unchanged (a trailing space). Regression tests use a gated embedder.
    - D5: a memory warning now resumes indexing by itself after 10 s (`IndexingModel.pauseForMemoryWarning`).
    - D7: results produced while indexing are run again when indexing completes (`SearchModel.indexingDidComplete`, called from `SearchRoot`), for any query, not only a launch `--search`.
    - §3.4 now records that format filtering is deferred, and V6 describes the shipped fulltext statements (scalar columns only, joined in the hydrate statement).
    - Re-verification:
      - `swift test`: 124 tests in 18 suites passed. Tokenizer 50/50; embedder min cosine 0.999972 (`.all`) and 0.999975 (`.cpuOnly`).
      - PerfTests slowest median: 32.96 ms (libraryPage author [text=an] p0). Phase 3 medians: semantic top50 3.18 ms, bookText 18.38 ms, itemText 12.79 ms, notes top20 0.32 ms, moreLikeThis PHM 3.57 ms, hydrate status=want 2.53 ms, writeBooks 32 rows 6.66 ms.
      - Real MiniLM per text on the Mac: median 2.23 ms with `.all`, 3.84 ms with `.cpuOnly`.
      - Builds: `xcodegen generate` and the iPhone 17 simulator build succeed with 0 errors.
      - UI tests, after a `simctl uninstall`: 5 of 5 pass. `PHASE3_INDEX_ELAPSED_SECONDS=162.4` (159.5 s by the app's own clock), Project Hail Mary is row 0 at Semantic 0.59, and More like this shows 4 or more covers. The relaunch reported "0 embedded this launch in 0.2 seconds".
      - Simulator `library.rl` afterwards is 45,838,336 bytes. It has embedding, embedding_model and embedding_text_hash on 1811 books each, `reading_status` only on `/works/OL59800W` (read, my_rating 4), 1 note (embedded), and schema_version 2.
  - **Review leftovers (low, not fixed).** A stale search is not cancelled inside SearchService, so it still runs its queries on the GraphStore actor. A note saved while indexing is paused for a memory warning is still embedded at once. The Swift tokenizer uses the OS Unicode tables, while the Python reference uses Unicode 15.0, so characters assigned after 15.0 become an extra [UNK] in Swift instead of being dropped.
- 2026-11-08 — phase 4 ("Map") done.
  - **Features.**
    - A fourth tab, **Map** (icon `map`), after Library, Tags and Search: an `MKMapView` (`UIViewRepresentable`) of every geocoded place, one pin per `geocoded_label`, opening on the continental US (centre 40, −100; span 45° × 70°).
    - Pins are tinted and prioritised by book count (`PinTier`). Book pins and birthplace pins cluster separately; a cluster shows the summed books (or authors) and zooms to its members on tap.
    - A **Birthplaces** toggle adds the places where authors were born as a second layer. It filters locally and does not re-query.
    - Tapping a pin opens the **place sheet** (detents medium and large; the map stays usable at medium). It shows the label, the book count, "N authors born here", "Also filed as: …" headings, the books set there (title order, paged; a row pushes Book detail inside the sheet) and the authors born there (pushing Author pages).
    - **Place search** at the top of the map (2+ characters, debounced 250 ms, up to 20 labels; a label that starts with the text ranks first). Choosing a result flies there and opens its sheet.
    - "N places in view" capsule, a loading spinner, an empty state ("No places here") that does not block gestures, and a 3 s banner for a place that is not on the map.
    - The place term page replaces the "Map in phase 4" placeholder with **Show on map** (switches to the Map tab, flies there, opens the sheet), or says "Not on the map: fictional or not a real place" (`geo_status = 'skipped'`) or "Not on the map: location unknown". Place chips on Book detail still open the term page.
    - New launch arguments: `--open-tab map` and `--map-place "<label or heading>"`.
  - **Geocoding** (the extension's `--geocode`; details in `wishlist-to-graph/README.md`).
    - One run over the exported store took 8 min 48 s. Of 693 places, 600 are located (550 by Nominatim, 50 by manual region centroids), 81 skipped and 12 unresolved, under 482 distinct labels.
    - Acceptance: of the 91 places with at least 2 books, **83 are located (91.2 %, bar 85 %)**. The 8 missing ones are skipped by policy (Mars and its variants, Earth, Moon, Solar system, Epsilon Eridani, Developing countries).
    - Montana (`Montana` heading, label Montana, point 47.3752671, −109.638757) has **29 books**; the sheet says "29 books" and lists 29 distinct rows.
    - The extension deviated from the spec in small ways that leave the property names unchanged: citizenship context for birthplaces, a county never stands for a town, boundary/ceremonial results allowed, a hand-placed Lower Elwha pin, and 50 manual region centroids (25 planned).
    - The geocoded store is 7,315,456 bytes, the same size as before geocoding, so checks compare sha256 (`c1e6dee9…fd3d`), not sizes.
  - **Decisions.**
    - D1. **One pin per label, always.** No zoom level switches to raw headings. The sheet lists the headings behind a pin.
    - D2. **Distinct counts.** A pin counts DISTINCT books and authors across all nodes of its label (United States: 182 books, 7 authors).
    - D3. **Montana** is only the heading `Montana`. `(Mont.)` headings and the Blackfeet reservation are their own nearby pins, clustering with it when zoomed out.
    - D4. **Pin styling** (`MKMarkerAnnotationView` has a fixed size, so emphasis comes from colour, glyph and priority, not size):

      | Tier | Colour | Glyph | Display priority |
      | --- | --- | --- | --- |
      | birthplace only | purple | person | defaultLow |
      | 1 book | teal | book | defaultLow |
      | 2–4 | blue | count | defaultHigh |
      | 5–14 | orange | count | required |
      | 15+ | red | count | required |

      `zPriority` follows the tier.
    - D5. **Clustering.** `clusteringIdentifier` "places" for book pins and "birthplaces" for birthplace-only pins. The cluster glyph is the summed books (or authors); its title is "N places". The subtitle is set but hidden on the map, to keep it readable. The **selected place leaves its cluster**: it is re-added without a clustering identifier, so the flown-to pin is always visible and highlighted.
    - D6. **Fly-to with the sheet open** frames the place in the part of the map above the medium detent (`setVisibleMapRect` with a bottom inset of half the map height), not behind the sheet.
    - D7. **Fetching.** `MapModel` fetches the visible box padded by 50 % per side, debounced 300 ms. A newer region cancels the pending fetch and a generation counter drops late results. A region inside the fetched (or pending) box makes no query.
    - D8. **Antimeridian.** `GeoBox.split()` queries a crossing box as two boxes, because `point.withinBBox` does not wrap.
    - D9. **`place_label` index** in `Schema.ddl` with no `schema_version` bump.
    - D10. **Sheet book order** is title, case-insensitive (`TermQueries.order`), as on term pages. Authors are ordered by book count, then name.
    - D11. **Show on map** is an environment action (`ShowOnMapAction`, comparable like `OpenRouteAction`) provided by `MainTabs`. The term page stays on its own tab's stack.
    - D12. **No location permission and no Info.plist key.** MapKit is a system framework, so no project setting changed.
  - **Relate 0.16.1 findings.**
    - `point.withinBBox` returns 0 rows for a box with west > east, even with places inside it. The app splits such boxes.
    - The POINT INDEX serves both `point.withinBBox(p.location, …)` and `point.distance(p.location, c) < r`. A Montana box reads 8 nodes instead of 693.
    - A point comes back to Swift as `CypherValue.point` with srid 4326, x = longitude and y = latitude (`Row.point`).
  - **Measurements.**
    - PerfTests on a temp copy of the geocoded bundled store, median of 5 warm runs, with a 30 ms budget for place queries:

      | Query | Median | Rows |
      | --- | --- | --- |
      | region world | 10.60 ms | 482 |
      | region US | 5.49 ms | 269 |
      | region Europe | 1.90 ms | 98 |
      | region Montana | 0.44 ms | 18 |
      | region Seattle | 0.12 ms | 2 |
      | region antimeridian halves | 0.10 / 0.07 ms | 1 / 0 |
      | search "mont" / "new york" / "an" | 1.24 / 0.98 / 3.48 ms | 20 / 6 / 20 |
      | summary Montana | 0.16 ms | 1 |
      | books Montana p0 / United States p0 | 0.99 / 1.81 ms | 29 / 40 |
      | authors London | 0.12 ms | 14 |
      | resolve Montana / location Montana | 0.60 / 0.03 ms | 1 / 1 |
      | near Missoula 500 km (core only) | 0.22 ms | 20 |

      "PERF summary: 187 queries; slowest median 28.10 ms (libraryPage author [text=an] p0)". Every other query stays under 50 ms.
    - **App size** (Release, arm64): the executable grew from 25,082,640 to 25,853,200 bytes (+770,560; 20,616,688 after `strip -x`, +277,616). The `.app` is 78,634,348 bytes of files (75 MB on disk). MapKit is a system framework. The geocoded `books.rl` is still 7,315,456 bytes.
  - **Tests.**
    - `swift test` is green: "Test run with 156 tests in 21 suites passed" (was 124 in 18). The new `PlaceTests.swift` has 3 suites: "Place queries" (13 tests), "Geo types" (6) and "Map model" (13). SchemaTests expects `place_label`, and PerfTests has the 16 place queries plus sanity checks on the real store (Montana 29, at least 300 world pins unique by label, United States at least 173 books, "mont" puts Montana first, Mars is not on the map, "USA" resolves to United States).
    - UI tests: 7 of 7 pass on the iPhone 17 (iOS 26.5) after a `simctl uninstall`, in 252 s. `MapUITests.testMapShowsPinsAndMontanaSheet` (40.6 s) saw "136 places in view" on the initial region, with 183 marker and cluster elements exposed to XCUITest. The Birthplaces toggle raised the count. `--map-place Montana` showed "Montana" / "29 books" / "Books set here (29)", the first row pushed Book detail (A river runs through it) inside the sheet, and the "olympic" search opened Olympic National Park. `testShowOnMapFromTermPage` (13.0 s) went from the Montana term page to the Montana sheet on the map, and Gethen showed `term.notOnMap`. The phase 3 search test passed unchanged (`PHASE3_INDEX_ELAPSED_SECONDS=84.5`, 80.9 s by the app; relaunch "0 embedded this launch in 0.2 seconds").
    - `ChipNavigationUITests.testPlaceChipOpensPlacePage` now expects `term.notOnMap` ("Not on the map: fictional or not a real place") on the Gethen page instead of the phase 1 placeholder.
    - After the run, the simulator's `library.rl` has 1811 books (all 1811 embedded) and 693 places with 600 located under 482 labels, the same as the bundle. `reading_status` is on 1 book, `schema_version` is 2, and `place_label` and `place_location` are ONLINE. The file is 46,026,752 bytes.
  - **Screenshots** (`ios/docs/`):
    - `phase4-map.png`: the Map tab on first open. It shows tier-coloured pins and clusters over the US (the Midwest cluster 188, "28 places" 55), the search field, "136 places in view" and the Birthplaces toggle.
    - `phase4-place-montana.png`: `--map-place Montana`. The red "29" Montana pin is selected and framed above the sheet, which reads PLACE / Montana / 29 books / "Books set here (29)" with the first rows.
  - **Deviations.**
    - **Near me is skipped** in the UI. The core statement (`PlaceQueries.nearMe`, `GraphStore.placesNear`) and its test exist; there is no location permission.
    - **`--wikidata` was not run** in phase 4: it needs a full re-import (main-session decision). Unqualified Wikidata birthplace headings ("Portland", "Cambridge") take Nominatim's most prominent match.
    - The sheet does **not grow to the large detent on push**. Book detail opens inside the sheet at whatever detent the user chose, and dragging up gives large. On the iOS 26.5 simulator, changing the detent programmatically had no effect: a selection binding (set at once or after the push), detents that become `[.large]` while the path is non-empty, and detents on the pushed screen were all tried.
    - There is no `Geo/` folder (§5). The geo types are in `Graph/Models/Place.swift`, the statements in `Graph/Queries/PlaceQueries.swift`, the model in `ViewModels/MapModel.swift`, and the UI in `Features/Map/`. `PlaceGeocoder` (CLGeocoder) belongs to phase 5, when the app first creates places.
    - The pins are tinted by book count but not sized by it, as planned in §6.4. `MKMarkerAnnotationView` has a fixed size (D4).
    - Search result rows and the "No places match" text use explicit UIKit label colours. Hierarchical `.secondary`/`.tertiary` styles became vibrant and nearly invisible on the material card.
    - Additions beyond the spec, from the core implementer: `MapModel.isSearching`, `showsNoSearchMatches`, `clearSearch()`, `reload()` and `settle()`; `PlaceSheetModel.hasLoadedSummary` and `error`; `PlacePin.countsText`; `PlaceSummary.otherNames`; `GraphStore.locatedPlaceCount()`. `--map-place` wins the tab over `--search`. Region rows without a label or a valid point are skipped, not thrown.
  - **Leftovers.** Cluster glyphs sum per-label counts, so a book set in two places of one cluster counts twice there (pins themselves are distinct). A place sheet open on the Map tab covers the tab bar until it is dismissed.
  - **Review leftovers (low, not fixed).** The visible box is built as centre ± span/2 from `MKMapView.region`, but MapKit's region centre is the Mercator midpoint, so at high latitudes the fetched box is slightly off the true visible latitudes (the 0.5° fetch padding hides it). "Show on map" passes the heading name to `MapModel.focus(on:)`, which re-resolves it through `PlaceQueries.resolve` instead of using the label the term page already has. A selected pin can lose its highlight when a fetch removes it and a later fetch brings it back.
  - **Store swap.** The main session ran `relate run wishlist-to-graph --geocode -d ./books.rl` on a scratch copy, measured 83 of 91 (91.2 %) two-plus-book places located, then replaced the root `books.rl` and `ios/RelateBooks/Resources/books.rl` with it (sha256 `c1e6dee9…0fd3d`; the byte size 7,315,456 did not change, so compare checksums). The pre-geocode export is kept at `backups/books-2026-11-08-pre-geocode.rl`. The extension is now version 0.2.0 and reinstalled from `./wishlist-to-graph`; its Nominatim cache lives in `~/.cache/relate-book/geocode.json` (548 entries), so a re-run makes no requests.
- 2026-11-08 — phase 5 ("Add books") done.
  - **Features.**
    - A **+** button on the Library (`library.add`) pushes **Add Book** with a Search / Scan / Manual segmented control. When the flow ends the screen replaces itself with the book's detail, so Back returns to the Library.
    - **Search**: Open Library as you type (debounced 400 ms, 3+ characters, a newer query cancels the older), rows with cover, title, authors and first year; works already in the store are badged "In your library" and open without a request; any other row asks "Add “…”?" → **Add to Library**.
    - **Scan**: VisionKit `DataScannerViewController` (EAN-13, EAN-8, UPC-E) when supported and permitted, scanning only while idle; always a typed ISBN field with check-digit validation and ISBN-10 → 13 conversion. `NSCameraUsageDescription` added to `project.yml`.
    - **Manual**: title and comma-separated authors, no lookup (`manual:<uuid>`, authors `name:<slug>`).
    - Progress card ("Checking your library…", "Looking up…", "Saving…", "Locating places… N of M", "Indexing…") and an error card with Retry and Dismiss.
    - Book detail: a notice ("Added to your library" / "Already in your library"), and for app-added books an **Added in app** section ("Added Nov 8, 2026 · ISBN scan", ISBN, publisher · year, pages, format). List rows show "Added in app" where the price would be. Manual books show "Added manually" next to the status badge.
    - New places an import creates are geocoded on device (CLGeocoder) and appear on the Map; the new book is embedded within seconds (semantic search, More like this); Library, Search and Map refresh through `UserDataChange.bookAdded` / `.placesLocated`.
    - DEBUG launch flags `--stub-network` (canned Open Library responses for The Perfect Storm plus a stub geocoder) and `--simulate-scan <isbn>` (feeds one payload through the Scan section's camera handler). `--reset-user-data` now also deletes app-added books and the nodes their imports created.
  - **Decisions** (main session D-A–D-K; architect D1–D40, numbering kept; full text in the phase 5 spec).
    - D-A anonymous Open Library, UA `RelateBooks/<version> (+https://github.com/johnymontana/relate-book)`, no contact or e-mail anywhere, about 1 request/s. D-B network only in the add flow and for covers; `OpenLibraryClient` on an `HTTPTransport` protocol, fake transport plus recorded JSON in core tests. D-C deterministic UI tests through `--stub-network`; one live run by hand. D-D VisionKit scanner plus a typed field; ISBN-10 → 13, both tried. D-E one transaction of MERGEs, no DELETE, no Item/Edition, `source: 'app'`, `added_on`, `match`, never overwrite an existing Book. D-F geocode only created places, one at a time, normaliser subset, denylist, extension properties, label rule, failures never fail the import. D-G incremental embed. D-H change propagation. D-I UI as built above, no delete. D-J no store swap, extension change, schema bump or DDL. D-K no phase 6, no dependencies.
    - D1 two search field lists (doc fields = the extension's minus `isbn` and `editions.id_amazon`; a short list for rows). D2 `RequestGate`: FIFO, one in flight, starts ≥ 1.05 s apart; queued callers cancel without sending. D3 error mapping; 404 = no record; 429/503 retried once only when `Retry-After` is absent or ≤ 5 s, otherwise `.rateLimited(N)` and the gate pauses for N s; 15 s timeout. D4 any transport error fails before writing. D5 ISBN flow local first (Item.isbn13/isbn10, Book.isbn13), then isbn13 → isbn10 → `/isbn/` → `key:`. D6 existing authors never fetched or modified (≤ 8 authors). D7 author name fallback by index.
    - D8 search imports write no edition facts. D9 `added_on` on every created node. D10 int/float/list typing, `drop_none`. D11 not-overwrite guard on every statement after the Book MERGE. D12 places to geocode found by a `missingPlaces` pre-read.
    - D13 ≤ 10 places per import, 10 s per geocode, one fallback, one shared `PlaceLocator` (serial across imports), screen waits ≤ 20 s. D14 normaliser without SYNONYMS / MANUAL_REGIONS / QUERY_OVERRIDES / country hints. D15 candidate acceptance (a field covers the significant tokens) and the label rule (1 km reuse of label and point; locality/admin/country equal to the base name; collision suffixes). D16 no series. D17 `ol_edition_key`, `geo_region`, `geo_source` = geocoder name.
    - D18 manual entry limits and slug rule (`name:h-<sha>` for an empty slug). D19 `physical_format` normalisation. D20 format via `coalesce(item.format, b.physical_format)`; filter and facets include app books. D21 wishlist sort unchanged (app books last).
    - D22 search results filtered to `/works/OL…W`; in-library rows open without confirmation. D23 AddBook pushed, replaced by `Route.addedBook`. D24 leaving (including a tab switch) cancels only before saving. D25 progress labels; indexing step skipped without a model; 15 s embed wait. D26 `.bookAdded` / `.placesLocated`. D27 index counters bumped after an incremental embed. D28 `--stub-network` / `--simulate-scan`, DEBUG only; covers still from the network. D29 stub routes. D30 the reset deletes app data. D31 no new DDL. D32 error copy. D33 "Added in app" text. D34 fixture The Perfect Storm, live book The Old Man and the Sea. D35 every add UI test uses `--reset-user-data --stub-network`; the typed test runs last and proves the reset. D36 `ImportRealStoreTests`. D37 client, transport, geocoders and stubs in core; only VisionKit is UI-only. D38 docs owned by the UI implementer. D39 phase 6 candidates (below). D40 ownership split; `Package.swift` unchanged.
  - **Open Library findings** (live, 2026-11-08). With `q=isbn:` the search doc's `editions` sub-doc is filtered to the matching edition; with `q=key:` it holds OL's "best" edition. `number_of_pages` and `physical_format` are requested but never returned in search editions (0 of 1,869 extension Items carry them), so `pages`/`physical_format` are nearly always absent. Free-text search can return non-work keys (`/works/OL8151445M`) and docs without authors; they are filtered. `GET /isbn/<isbn>.json` answers 302 to `/books/OL…M.json` (URLSession follows it); unknown ISBNs 404. Sparse author records (name only, `last_modified` with a space) decode tolerantly. `first_sentence` is a list; `description` is a string or `{type, value}`. `9780000000002` is not an unknown ISBN (it returns a pamphlet).
  - **Relate findings (0.16.1).** `MERGE … ON CREATE SET b += $props, b.added_on = datetime($now)` works with a map parameter; `b.added_on = datetime($now)` is true only on the creating run, so it serves as the not-overwrite guard. One transaction creating a Book, an Author, 22 Subjects and 2 Places with no DELETE commits (LABS-1188 does not apply). The reset deletes nodes from earlier transactions and restores 1811 / 1919 / 8380 / 693 exactly. `point.distance(p.location, point(…)) < r` uses the POINT index (0.8 ms). `book_text` sees the new book as soon as the transaction commits.
  - **Measurements.**
    - Engine timings (spec §0.8): `bookByISBN` 1.5 ms (CLI) / 0.73 ms (Swift), import transaction 3.1–3.8 ms, replay 1.2 ms, guarded no-op 0.38 ms, `nearestLabel` 0.04–0.8 ms, detail with the new columns 4.8–6.6 ms, Library page with the new projection 6.6–7.7 ms, format filter with the OR 12.5–14.9 ms.
    - PerfTests unchanged and within budget: "PERF summary: 187 queries; slowest median 25.98 ms (libraryPage author [text=an] p0)" (25.01 ms in the core implementer's run; phase 4 28.10 ms). `ImportRealStoreTests` (real store plus the imported fixture): "PERF import summary: 19 queries; slowest median 15.63 ms (import bookText [perfect storm])" (14.82 ms in the core run). A book without an Item does not slow the library or search queries (title page 6.67 ms, wishlist SKIP 1800 14.56 ms, Hardcover filter 12.50 ms).
    - UI flow on the simulator (stub network, real 1.05 s gate): `PHASE5_IMPORT_SECONDS=3.3` (3.4 in an earlier run) from Look Up to the detail (3 requests, save, 2 stub geocodes, embed). Live: 4.0 s (below).
    - **App size** (Release, arm64, re-measured by the main session after both review rounds): the executable grew from 25,853,200 to 27,135,776 bytes (+1,282,576; 21,157,656 after `strip -x`, +540,968; before the review fixes it was 27,006,624 / 21,123,472). The `.app` is 79,917,008 bytes of files (76 MB on disk). VisionKit and CoreLocation are system frameworks; the stubs are DEBUG-only and absent from Release.
  - **Tests.**
    - `swift test`: "Test run with 266 tests in 35 suites passed" after both review rounds (259 before the first, 262 after it; was 156 in 21). New suites cover the client (fake transport and recorded fixtures, UA, gate, Retry-After, cancellation, ephemeral session), the models (tolerant decoding), ISBN and heading-normaliser tables (generated from the extension's own code), the import draft, the importer and the save on an in-memory store (fields, idempotence, already-in-library, manual entry, existing author untouched), place location through the stub geocoder (label rule, 1 km reuse, collision, serial `maxInFlight == 1`), the AddBookModel state machine (debounce, scan loop guard, budgets, step labels), change propagation, the stub fixtures and the real-store pipeline.
    - UI tests: **12 of 12** pass on the iPhone 17 (iOS 26.5) after `simctl uninstall`, in 426.6 s. `AddBookUITests` (5 tests, 183.1 s): already in library 21.9 s, manual 29.6 s, search import 26.3 s, simulated scan (plus the same book again by scan and from the badged search row) 38.2 s, typed ISBN → Library → Search → Map → `--map-place Gloucester` → reset proof 67.1 s. `PHASE5_SEARCH_REASON` "… Semantic 0.57 + keyword" (keyword, and semantic after the incremental embed); the Gloucester sheet read "Gloucester / 1 book / The Perfect Storm". Phase 1–4 tests unchanged and passing (`PHASE3_INDEX_ELAPSED_SECONDS=74.4`, 70.5 s by the app; `PHASE4_MAP_COUNT=136 places in view`).
    - After the UI run the simulator's `library.rl` had 1811 books, none with `source: 'app'`, no node with `added_on`, 2002 Items (the bundle's count), 693 Places (600 located), 1919 Authors and 8380 Subjects. Hashes of every Place's geo properties, every Author and every Book (with relationship counts) equal the bundle's. After the live check and its reset relaunch, the same.
  - **Screenshots** (`ios/docs/`): `phase5-add-search.png`, `phase5-add-scan.png`, `phase5-importing.png` ("Looking up…"), `phase5-added-detail.png`, `phase5-library.png`, `phase5-search.png`, `phase5-map-gloucester.png`, `phase5-manual.png`, `phase5-already.png`, and the live `phase5-live-old-man.png` and `phase5-live-cuba.png`. Descriptions in `ios/README.md`.
  - **Live check** (real Open Library and CLGeocoder, Debug build on the iPhone 17 simulator, no stub flags; driven once by a temporary XCUITest that is not part of the suite, then removed).
    - *The Old Man and the Sea*, ISBN 9780684801223 typed in Scan → Look Up → detail in **4.0 s**. Steps seen: "Looking up…", "Locating places… 1 of 4", "Locating places… 3 of 4", "Indexing…". **3 Open Library requests** for the import (`/search.json` with `q=isbn:…`, `/works/OL63073W.json`, `/authors/OL13640A.json`; Hemingway was not in the store), 1.07–1.09 s apart; then **1 request** for the Search-mode query "old man and the sea" (first results 1.7 s after typing began; 7 rows on screen, the first "The Old Man and the Sea, Ernest Hemingway, 1952, In your library").
    - Book written: `/works/OL63073W`, `match: 'isbn'`, `isbn13` 9780684801223, `isbn10` 0684801221, publisher Simon & Schuster (1995), `added_on` 2026-11-09T05:02:44.471Z, embedded (vector written). Created: 1 Book, 1 Author, 39 Subjects, 1 Person, 4 Places (60 ABOUT, 4 SET_IN, 1 FEATURES, 1 SET_DURING, 1 WRITTEN_BY). Added in app read "Added Nov 8, 2026 · ISBN scan / ISBN 9780684801223 / Simon & Schuster · 1995".
    - **4 places created, geocoded one at a time in 0.6 s** (no throttling): **Cuba** → ok, label "Cuba", country, 21.327, −77.823 (correct; a new pin, and `--map-place Cuba` showed "Cuba / 1 book / The Old Man and the Sea", `phase5-live-cuba.png`). **Gulf Stream** → ok, label "Gulf Stream", but "Gulf Stream, FL, United States" (the town in Palm Beach County, 26.500, −80.054), not the ocean current. **Straits of Florida** → ok, label "Straits of Florida", "Straits of Florida, Miami, FL" (25.732, −80.233), a point in Miami rather than the strait. **Swahili** → `unresolved`, "no matching result" (as expected; not a place). Labels came from the placemark name matching the heading (no located place within 1 km of any of them). The two water bodies show that CLGeocoder prefers a same-named locality; the token-cover acceptance rule cannot tell them apart (phase 6: water-body hints or `MKGeocodingRequest`).
    - Cleanup: relaunched with `--reset-user-data`; the store is back to the bundle's counts and hashes.
  - **Deviations.**
    - D8: search imports write no edition facts (the extension's `pick_edition` would). D14: the synonym table is not ported. D6: existing authors are not refreshed. D30: `--reset-user-data` now deletes app-added books and their created nodes.
    - `OpenLibrary/` and `Geo/` are top-level core folders as planned (§5); the map queries stayed in `Graph/Queries/PlaceQueries.swift`.
    - CLGeocoder is deprecated in the iOS 26 SDK (no warning at the iOS 18 target); kept per D-F.
    - `pages` and `physical_format` are nearly always absent (Open Library search does not return them).
    - The **Added in app** section sits directly under the header for app-added books, not after Your Reading where the Amazon section sits, so the add flow's landing screen shows the notice and the provenance together. Wishlist books are unchanged.
    - Author rows in Book detail expose their names to XCUITest as static texts, so the manual test matches static texts or buttons.
    - The Library's active `.searchable` field hides the toolbar **+** and its keyboard covers the tab bar, so `AddBookUITests.endLibrarySearch` taps the search field's Close before every move away from the Library (a test-side workaround, not an app change). The live check's temporary driver failed its Map step for the same reason (the keyboard covered the tab bar); Cuba was confirmed on the Map with a separate `--map-place Cuba` launch instead.
    - Additions beyond the spec: the simulated-scan test also re-adds the fixture (by scan and from the badged search row) to cover the already-in-library path for an app-added book; the typed test relaunches with `--map-place Gloucester` before the reset to show the pin persists; `ReplaceRouteAction` is also provided on the Tags, Search and place-sheet stacks (a plain push there).
  - **Review fixes** (after the phase 5 review; re-verified with `swift test` 262/262 — "PERF summary: 187 queries; slowest median 25.47 ms", "PERF import summary: 19 queries; slowest median 14.87 ms" — a zero-error simulator build, and the UI suite 12 of 12 from a fresh install in 427.9 s, AddBookUITests 5 of 5 in 185.3 s, `PHASE5_IMPORT_SECONDS=3.3`, `PHASE5_SEARCH_REASON` "… Semantic 0.57 + keyword"; screenshots refreshed from that run).
    - `AddBookModel.startImport` now sets the first step (`.checkingLibrary`, or `.saving` for a manual entry) synchronously and cancels a stale task (never one that is saving), so a double tap or a scan in the same turn is refused by the `isBusy` guards instead of starting a second run that could send a gated Open Library request. Tests: "a double submit in one turn starts one import", "manual entry goes straight to saving, recorded once".
    - Search re-runs an active query when the new book's vector lands (`IndexingModel.onBookEmbedded` → `SearchModel.bookDidEmbed`, wired in `AppSession`), not only on `.bookAdded` at save; before, an embed that finished after the add screen's 15 s wait never reached visible results semantically. Test: "an embed landing after the add re-runs the active query (session wiring)".
    - `ISBNScannerView` records a start only when `startScanning()` succeeds and retries a failed start up to 4 times, 0.4 s apart. The Scan section distinguishes "Allow Camera" (permission not asked yet; requests it) and "Camera access is off" (denied/restricted; Open Settings) from "Camera scanning unavailable" (no DataScanner), re-checked when the app becomes active. Not exercisable on the simulator.
    - `URLSessionTransport` sets a 30 s resource (overall) timeout next to the 15 s idle timeout, so a trickling server cannot keep "Looking up…" spinning; the session-configuration test asserts it.
    - `wishlist-to-graph/__pycache__/wishlist-to-graph.cpython-315.pyc` (created 20:24 on 2026-11-08 when the architect imported the extension with `python3 -I` to derive the normaliser tables) is the only change under `wishlist-to-graph/`; `wishlist-to-graph.py` (17:45), `README.md` and `extension.json` are untouched. Agents may delete only inside the scratchpad; the main session removed the directory after the verification run (it was the only entry, regenerable bytecode), so `wishlist-to-graph/` is back to its pre-phase state. Later runs that import the extension should use `python3 -I -B` (or `PYTHONDONTWRITEBYTECODE=1`).
    - After the re-run the simulator's `library.rl` again had 1811 books, none with `source: 'app'`, no node with `added_on`, 2002 Items (the bundle's), 693 Places (600 located), 1919 Authors, 8380 Subjects; Place geo properties hash equal to the bundle's, and Book properties are unchanged (only the phase 2 user-data note and tag on The Left Hand of Darkness differ, as expected).
  - **Review fixes, round 2** (a second four-lens review found 2 medium and 3 low findings; the fixer's UI run was cut short, so the independent verifier re-ran everything: `swift test` **266 of 266** in 35 suites — "PERF summary: 187 queries; slowest median 26.19 ms (libraryPage author [text=an] p0)", "PERF import summary: 19 queries; slowest median 16.23 ms (import bookText [perfect storm])" — a zero-error simulator build, and the UI suite **12 of 12** from a fresh install in 426.5 s, AddBookUITests 5 of 5; both `books.rl` still `c1e6dee9…0fd3d`; the simulator store back at 1811 books / 2002 Items / 693 Places with 600 located).
    - **Label rule brought in line with the extension's `assign_labels`.** Behind the 1 km reuse, `PlaceMatch.resolveLabel` (a pure function over `GraphStore.locatedLabels()`, a new 0.9 ms query that replaced `labelLocation`/`labelCoordinate`) compares labels through `HeadingNormalizer.fold` (case- and accent-insensitive). A located label equal to the preferred label, or to its ", qualifier/region" form, is reused (label and point) within 50 km, the extension's same-base radius; when the candidate is itself the region (placeType country or administrativeArea folding to the base), the radius widens to 3,000 km for a country and 1,000 km for a first-level division, standing in for the OSM-id merge that cannot be ported. Georgia the country and Georgia the US state stay separate (about 10,000 km apart). Suffixes (", qualifier/region", then " (lat, lon)") are added only when a same-named place really is elsewhere. Regression tests on in-memory stores seeded with the store's own Nominatim points (California (U.S.) ~80 km away merges into "California"; Russia ~470 km away merges into "Russia"; Georgia (Republic) gets its own label; "new england" ~30 km away merges into "New England"; Springfield (Mass.) becomes "Springfield, Massachusetts"), a pure `resolveLabel` table, and on a copy of the real store ("California (U.S.)", "england" and "Cuba" → California, England, and a new Cuba label).
    - **US and Canadian region abbreviations are spelled out.** CLGeocoder with the en_US locale returns `administrativeArea` as "FL"/"MA"; new `RegionNames` tables (50 states, DC, territories; Canadian provinces) and `GeocodeCandidate.expandingRegionAbbreviation()` give `geo_region`, `geo_display_name` and the label suffix full names, matching the extension and the bundled store. The stub's Gloucester candidate now carries "MA", the shape the real geocoder returns, and the Gloucester test still reads "Massachusetts". The live check's recorded `geo_region` "FL" would now be "Florida"; the live run was not repeated.
    - Not fixed from this round: the stray `__pycache__` (removed by the main session, above) and the stale app-size figures (re-measured by the main session, see **App size**).
  - **Leftovers / phase 6 candidates.** No delete-a-book (delete it and its orphans, found by `added_on`); retry `unresolved` or untried app places (geocoding is not retried in this phase); a contact string in the User-Agent from Settings; fetching the edition record for pages and format; porting the synonym table and better handling of water bodies (see the live check); `MKGeocodingRequest` on iOS 26; a "Recently added" sort; keep the Library's **+** reachable while its search is active (show it during search, or dismiss the keyboard on scroll so the tab bar comes back). Live camera scanning (and the new camera-permission cards) was **not** run on a device: the simulator has no DataScanner, so the scanned path was exercised through `--simulate-scan` (the Scan section's camera handler) and the core model tests.
- 2026-11-12 — **Relate upgraded from 0.16.1 to 1.0.1.** `github.com/relatedb/relate` is now public and its v1.0.1 release assets download, so `ios/Package.swift` (`exact: "1.0.1"`) and `ios/project.yml` (`exactVersion: 1.0.1`) now depend on the published Swift package instead of the `../../../relatedb/relate` path. `RELATE_LOCAL_XCFRAMEWORK=1` is no longer needed. The local checkout's prebuilt XCFramework was stale (built 2026-11-07 from 0.16.1). SwiftPM fetches the checksum-pinned `RelateFFI.xcframework.zip` (312,503,014 bytes). Both `Package.resolved` files pin revision `ef436ce` and should be committed. The pin is exact on purpose: the tests and notes record engine behaviour. Relate's version history was reset at the public release (0.1.0 → 1.0.1), so there is no source diff from 0.16.1, and every finding below was checked empirically. The Swift client on the checkout's `main` (1.0.2-dev) is identical to v1.0.1.
  - **No API breaks.** Core and app compile unchanged against 1.0.1 with no new warnings. The 0.16.1-written `books.rl` (sha256 `c1e6dee9…0fd3d`) opens as-is: 1811 books, and all 23 indexes are ONLINE.
  - **One behaviour change broke a test.** `point.withinBBox` now wraps the antimeridian. A west 170 / east -160 box returns Suva, Apia and a point on 180°, with or without the POINT index, and excludes an in-band decoy at 0° and Lima. `PlaceTests.antimeridian` asserted that one unsplit statement finds nothing; it now asserts that the statement agrees with the split, {Suva, Apia}. `GeoBox.split()` is kept, because it is cheap and independent of the engine version. Comments in `Place.swift` and `PlaceQueries.swift` were corrected.
  - **Fulltext.** Upper-case `AND`/`OR`/`NOT` are now operators (`hail AND mary` 1 book, `hail mary` 4). Lower-case forms are still words. `*` is still not a wildcard, and there is still no stemming or accent folding (`gödel`/`godel` both 0). `SCORE AS` after SEARCH is now optional. The app is unaffected: `KeywordQuery` lower-cases and drops and/or/not. `SearchTests.hostileStrings` now pins both the raw-operator behaviour and the sanitizer's escape from it. CLI on a store copy: 17.5–18.2 ms per `book_text` query.
  - **LABS-1188 is still present in 1.0.1.** A standalone Swift repro (create, then delete, in one `transaction`) panics at `binding.rs:62` ("update counters are non-negative") and poisons the handle. The rule stays. Comments now say "0.16.1 and 1.0.1".
  - **Measured.** `swift test`: 266 tests in 35 suites passed. The perf summary's slowest median is 24.8–26.2 ms over three runs (`libraryPage author [text=an]`); the import summary's slowest median is 17.3–33.7 ms. All are within the 50 ms budget. Places: world 482 pins 8.2 ms, US 269 4.9 ms, Montana 18 0.40 ms. One run hit a timing flake in `OpenLibraryClientTests.rate` (start gap under 58 ms under full-suite load). The test does not touch Relate and passed in 6 of 6 isolated reruns and in the next full run. UI tests (fresh install, iPhone 17): 12 of 12 passed in 522.7 s. Full index 165.5 s (161.5 s in-app), relaunch "0 embedded this launch", `PHASE5_IMPORT_SECONDS=4.3` (3.3–3.4 on 0.16.1), and the search reason "Semantic 0.57 + keyword" is unchanged. Release arm64 executable: 28,406,872 bytes (+1,271,096); `strip -x` 22,289,184; `.app` 81,188,104 bytes of files.
  - **CLI.** Running a downloaded release binary was not possible in this session. A 1.0.1 CLI was built from `git archive v1.0.1` of the local checkout into a scratch directory (`cargo build --release --locked -p relate-cli`, 1 min 48 s). The checkout's own `target/release/relate` is stale (`--version` prints v0.1.0). The extension was not re-run on 1.0.1.
- 2026-11-12 — **Prepared for open source; the bundled store is now a public sample.**
  - **Sample store.** `ios/RelateBooks/Resources/books.rl` was the maintainer's personal export: its Wishlist node carried the real list id and URL, plus 2,002 Amazon items. It is replaced by an import of the public sample list `https://www.amazon.com/hz/wishlist/ls/9N4X43GP6SVK` (relate 1.0.1 CLI, `--wikidata --geocode`, no `--contact`; about 30 s). The sample has 6 books, 8 authors (Open Library's three "David Allen" records on Getting Things Done, as in the old store), 173 subjects, 58 awards, 3 genres, 1 series (Hainish Cycle) and 34 places, 19 of them located. sha256 `b798db09…5aee3c`, 212,992 bytes. A first import without `--wikidata` lacked awards, series and genres. The old store had them (all 1,027 awards carry Wikidata QIDs), so the earlier note that `--wikidata` was not run on the shipped store was wrong: it was not re-run in phase 4. The old store is kept outside git as `backups/books-2026-11-12-bundled-personal-geocoded.rl` (`c1e6dee9…0fd3d`). Earlier commits still contain it; the maintainer rewrites history before publishing.
  - **Perf on a scaled store.** Six books would make the budgets meaningless, so the new test helper `ScaledLibrary` grows a temp copy to 1,800 books. It makes 300 copies of every Book, Author and Item under `<key>~<k>` keys; clones carry no ISBNs, and wishlist positions continue after the originals. Terms are shared ("Fiction" has 1,200 books). The first 30 copies also clone the places at deterministically shifted coordinates. Result: 2,400 authors, 1,020 places, 570 located, 510 map labels (the original export had about 600 located and 482 pins), 56,100 ABOUT edges. It was verified with the CLI on a copy first; 20 auto-committed CREATE/SET statements take about 3 s of engine time and include no DELETE. PerfTests and ImportRealStoreTests now run on it. 187 queries: slowest median 22.31 ms (`libraryPage author [none] skip 1760`). Import: 19 queries, slowest median 21.28 ms. Places: world 510 pins 12.5 ms. All are within budget.
  - **Retargeted tests.** Montana → San Francisco (271 books on the scaled store, 1 in the sample); London authors → New York City; Discworld → Hainish Cycle; Steve Jobs → Rocky; "20th century" → "20th Century"; Simon & Schuster → Random House; Guggenheim → Locus Award for Best Novella. The unresolved book is now a clone key and the unresolved count is 0. `resolvePlace("USA")` → `("UK")`. Project Hail Mary's ISBN is 9780593135211 (the sample's Kindle edition). The import test seeds a located "New England" so The Perfect Storm still brings exactly two new places. It now makes 4 requests (neither author is in the sample), and the variant heading "California (U.S.)" → "Hawaii (U.S.)". UI: "olympic" → "sahara", "1811 of 1811" → "6 of 6", and the genre page lists Project Hail Mary. `swift test`: 266 tests in 35 suites passed. UI: 12 of 12 passed in 412.9 s; index 65.4 s from launch (6 embeds in 0.5 s); `PHASE4_MAP_COUNT=3 places in view`; `PHASE5_IMPORT_SECONDS=4.3`; "Semantic 0.57 + keyword" unchanged.
  - **Screenshots.** 19 PNGs in `ios/docs/` were regenerated by the UI tests on the sample. `phase4-place-montana.png` became `phase4-place-san-francisco.png`. Removed, because no test produces them and they showed the personal export: `phase0-screenshot.png`, `phase1-library.png`, `phase1-book-{truck,left-hand,gtd}.png`, `phase1-author-{le-guin,david-allen}.png`, `phase1-term-place.png`, `phase3-indexing.png` (six books embed before the banner can be captured) and `phase5-live-{old-man,cuba}.png`. Mentions of them in earlier changelog entries are history.
  - **Repository.** Added `LICENSE` (Apache-2.0, byte-identical to apache.org's LICENSE-2.0.txt) and `NOTICE` (MiniLM model; Amazon, Open Library, Wikidata and OpenStreetMap/Nominatim data in the sample; cover and map imagery in the screenshots; Relate). The `.gitignore` covers `*.rl.tmp`, editor state and personal exports. `refresh_store.sh` finds `relate` on `PATH` (or `$RELATE_BIN`) instead of a sibling checkout. The READMEs and `AGENTS.md` describe the sample, the public CLI installer, an Amazon note, Contributing and License.
- 2026-11-15 — **Moved to Relate's new Swift API, ahead of a release.** The Swift package on Relate's `main` gained an idiomatic layer after 1.0.1 (ADR-0596, pull requests #333 to #436: managed asynchronous access, `Statement`, `Record`, conversions for Swift and platform types, `Migrator`, provisioning, tracing, live queries). The latest release is still 1.0.1 and `main`'s manifest names a 1.0.2 binary that was never published, so the app cannot depend on it by URL. The app code is rewritten onto the new API anyway; the dependency is temporary plumbing.
  - **Dependency.** `ios/scripts/setup_relate.sh` downloads a source snapshot of `relatedb/relate` at a pinned commit (`af8c2e4`, `main` on 2026-11-15) into `ios/Vendor/relate` (git-ignored) and builds `RelateFFI.xcframework` there with Relate's own script and pinned Rust toolchain (1.88.0). `Package.swift` and `project.yml` depend on that directory by path, and every `swift` and `xcodebuild` command needs `RELATE_LOCAL_XCFRAMEWORK=1`. A first build ran from the wrong directory, which made rustup ignore the snapshot's `rust-toolchain.toml` and use the default toolchain; the script now changes into the snapshot first. `ios/Package.resolved` is gone (a path dependency has no pins). The Swift sources at the pin are identical to the head of the last pull request (#436). The engine is `main`, not 1.0.1; the extension, the bundled store and the web app stay on 1.0.1.
  - **`GraphStore`** is no longer an actor holding a `Connection` with two hand-written reconnect blocks. It is a `Sendable` struct around the `Database`, whose pool owns one writer and up to two readers and replaces a poisoned connection itself. Each query method runs its statement with `read` (rolled back, on a reader) or `write` (one transaction on the writer). Its own provisioning code (temp copy, permissions, stale-copy cleanup) is replaced by `Database.provision` and `Database.defaultStoreURL`.
  - **Atomicity that the actor used to give for free.** An actor method ran to completion; an `async` method made of two awaited calls does not. Three places are now one transaction or one snapshot: `saveImport` (the existence check, the missing-places read and the W1 to W3 writes share one `database.write`), `formatFacets` and `placePins` (two statements in one `database.read`).
  - **`Statement`.** The app's own `Statement` struct is deleted; `Relate.Statement` has the same shape. Builders pass Swift values (`["key": key, "rating": rating, "now": now]`) instead of wrapping each one: the query files go from 143 `.string(…)`, `CypherValue(…)`, `.list(…)` and `?? .null` wraps to 17, all of them inside nested maps. That makes the builders `throws`. The library filter builds a statement and appends the sort and page to it. The statements keep named `$parameters` rather than interpolated literals: the Cypher text is unchanged, several statements use one parameter more than once, and tests read parameters by name.
  - **A trap found on the way.** `Statement("…\(x)…")` with one argument is a statement literal, so `\(x)` binds as a parameter instead of being spliced. One static statement (`TagQueries.list`) interpolated a column list that way; it now uses `\(raw:)`. The compiler caught it only because a global initializer cannot throw; inside a `try` it would have compiled and bound the text as a value.
  - **Values.** Instants are bound as `Foundation.Date` (UTC DATETIME, microseconds) instead of ISO-8601 strings wrapped in `datetime($now)`; the local day is `CypherValue.Date(now, in: calendar.timeZone)` instead of a string wrapped in `date($today)` (which also stops a non-Gregorian user calendar from writing its own year). `Timestamps` is deleted. Embeddings are bound with `CypherValue(vector:)` and read with `float32Values`. Coordinates and box corners are bound as points (`CypherValue.Point(latitude:longitude:)`) instead of pairs of floats built into `point({…})`; the perf suite shows the POINT index still serves them. `Row` stays as the tolerant layer over `Record` (empty string as nil, an integer from a string), and reads instants and points through the package's bridges.
  - **Schema.** `Schema` is a `Migrator` with the version on `(:AppMeta {key: 'schema_version'}).version`. Earlier builds kept it in `.value`, which the migrator would report as a broken record, so `Schema.migrate` first moves it across; an installed store upgrades in place (tested from versions 1 and 2). A store written by a newer build is now refused.
  - **Logging.** The per-call `label:` arguments and `Log.query` timing lines are replaced by the database's trace handler, which covers every statement including the migrator's and a transaction's.
  - **Engine finding 1: `CALL { }` is always read-write.** Relate reports the query type of any statement that contains a `CALL { }` subquery as read-write, even when the subquery only matches, and a managed read refuses a statement that is not a read. The library's text search and the ISBN lookup are `CALL { … UNION … }` statements. Rewriting the search with per-book `EXISTS` conditions would give up the measured 3x advantage of the UNION form, so both run through `GraphStore.readWithSubquery`: a transaction on the writer that commits nothing. They wait behind a write in progress; everything else reads on the pool.
  - **LABS-1188 is still present at the pin.** Creating and then deleting a node in one `Database.write` throws an internal error (`Neo.DatabaseError.General.UnknownError`); the pool replaced the connection and the next read worked. The rule stays.
  - **Engine finding 2: fulltext.** On `main` a raw fulltext query string that ends in a backslash is a syntax error; 1.0.1 accepted every input. `KeywordQuery` never sends one. `SearchTests.hostileStrings` now pins the refusal.
  - **Verified.** `swift test`: 270 tests in 35 suites pass (266 before; the stale-temp-copy test went with the code it tested, and five were added: the provisioned copy, reads refuse writes, a read during an open write transaction, the legacy version record, a newer store). UI tests: 12 of 12 pass from a fresh install (iPhone 17 simulator, iOS 26.4, 419 s; first index of the six books "in 0.8 seconds"). Perf suite: all 187 queries inside their budgets, slowest median 22.48 ms (`bookText [lonely astronaut saves earth]`; 22.31 ms on 1.0.1), `placeRegion world` 10.26 ms with point parameters (12.50 ms before). The app was built and tested from the command line; the Xcode GUI path (`open -a Xcode --env …`) was not exercised, and the binary size was not re-measured.
  - **List latency during indexing** (the one behaviour change the Swift plan asked to measure). Wall-clock time of the first library page on the 1,800-book scaled store, on the Mac, three runs each, with the instant test embedder so that writes are as dense as they can be. Before (actor, one connection, Relate 1.0.1): 5.0 ms median idle; during indexing 11 ms median, 15 ms at the 95th percentile, 463 to 481 ms worst case. After (reader pool, pinned `main`): 4.1 to 4.2 ms median idle; during indexing 4.3 to 4.6 ms median, 7.5 ms at the 95th percentile, 8 to 9 ms worst case. The engines differ between the two, so the idle figures are not a like-for-like comparison of the Swift layer; the disappearance of the stall is.
  - **Not adopted.** `@LiveQuery` and `Database.values`: the app's views hold no Cypher by rule, and its view models patch rows in place from `UserDataController`'s change events, which a re-run of the whole statement would replace with a reload. `Codable` decoding: the store's values need the tolerant rules in `Row`.

