# Research notes — Amazon wishlist import and book enrichment

Written 2026-11-07 while building the `wishlist-to-graph` Relate extension.
Everything below was verified against live endpoints on that date unless
marked otherwise.

## 1. Relate extensions — how a package plugs in

Source: `docs/api/extensions/{spec,authoring,quickstart,install}.md` and the
`relate extension init --lang py` scaffold in the relate checkout.

- A package is one directory: `extension.json` + one executable. Installed
  under `~/.config/relate/extensions/<name>/`, mounted as `relate run <name>`.
- The executable is an **MCP client over its own stdio**. The host writes one
  JSON envelope line (resolved flag values; the positional under its declared
  name, e.g. `{"WISHLIST": "...", "domain": "amazon.com"}`), then answers
  JSON-RPC 2.0 requests: `initialize` (protocol `2025-06-18`),
  `notifications/initialized`, `tools/call`.
- Five tools: `write_cypher {statement, parameters}` (rows via `$rows`),
  `read_cypher`, `update_schema` (DDL only), `batch_cypher {statements}` (one
  transaction), `report_output {text, starters}`.
- Caps: 8 MiB per statement/response line, 1000 rows per writing call, 4096
  statements per batch, 128 MiB per session; published in the `initialize`
  result so the child can size chunks.
- `commit: per-batch` commits each writing call (progress survives a failure);
  `whole-import` wraps the session in one transaction.
- The child never sees the store path; `-d/--database` is host property.
- Flag kinds: `string`, `integer`, `boolean` (bare, sets true), `repeatable`.
  No flag may be named `database`/`db`.
- `relate extension check <dir>` runs the manifest/spawn/handshake probe
  without touching a store.

Cypher dialect checks that passed on relate 0.16.1 (used in the extension):
`MERGE … ON CREATE SET`, `SET n += $map`, `SET n:Label` / `REMOVE n:Label`,
`FOREACH`, list properties, `date()`/`datetime()`, `CASE`, `COUNT { … }`,
`WHERE NOT EXISTS { pattern }`, `OPTIONAL MATCH … DETACH DELETE`,
`CREATE CONSTRAINT … IF NOT EXISTS`, `CREATE INDEX … IF NOT EXISTS`,
`CREATE FULLTEXT INDEX … ON EACH […]`, `CALL db.index.fulltext.queryNodes`.
Not supported: setting a label inside `FOREACH`.

## 2. Amazon wishlists — getting the items out

There is no API. Amazon retired the wishlist web service years ago, and the
Product Advertising API needs an Associates account and does not expose
lists. Every working tool scrapes the public list page.

### The page

- URL: `https://www.amazon.<tld>/hz/wishlist/ls/<LIST_ID>` (share links add
  `?ref_=wl_share`; `/registry/wishlist/<ID>` redirects there). Adding
  `?viewType=list&filter=unpurchased&language=en_US` pins the layout.
- A plain `GET` with a desktop browser User-Agent returns the full page
  (HTTP 200, ~600 KB) — no JavaScript needed. Verified on amazon.ca and
  amazon.co.jp; the amazon.com list in the fixture set is now empty.
- Private lists redirect to `/ap/signin`. Heavy traffic gets a
  `validateCaptcha` page (HTTP 200) — detectable by that form action.
- List metadata: `span#profile-list-name` (title), `span#wlDesc`
  (description), `input#listId`.

### Items

Each item is `li.g-item-sortable` with attributes
`data-itemId`, `data-price` (float; `-Infinity` when unavailable) and
`data-reposition-action-params` whose JSON holds `"itemExternalId":"ASIN:<asin>|<merchant>"`.
Inside, ids are suffixed with the item id:

| Field | Selector |
| --- | --- |
| title / product URL | `a#itemName_<id>` (`title` attr, `href` → `/dp/<ASIN>/…`) |
| byline | `span#item-byline-<id>` — `by <names> (<binding or department>)` |
| price | `span#itemPrice_<id> span.a-offscreen`, or `data-price` on the `li` |
| used/new price | `span.itemUsedAndNewPrice` |
| priority | `span#itemPriority_<id>` (hidden int: −2…2) and `span#itemPriorityLabel_<id>` (`> medium`) |
| comment | `span#itemComment_<id>` |
| date added | `span#itemAddedDate_<id>` — **only rendered for the signed-in owner** |
| star rating | `i#review_stars_<id> span.a-icon-alt` → `4.7 out of 5 stars` |
| review count | `a#review_count_<id>` |
| image | `div#itemImage_<id> img[src]` (`._SS135_` size token; strip for full size) |
| wanted / has | `span#itemRequested_<id>`, `span#itemPurchased_<id>` |
| option | `span#twisterText` |

The byline's trailing parenthetical is the **binding for books** (Paperback,
Hardcover, Kindle Edition, Mass Market Paperback, Board book, Audible
Audiobook …) and the **department for everything else** (Apparel, Vinyl,
Electronics, Grocery …). That, plus "the ASIN is a valid ISBN-10" (true for
most print books; Kindle ASINs start with `B0`), classifies books.

### Pagination

The page shows 10 items and loads more by cursor. Each page carries a
`<script type="a-state" data-a-state='{"key":"scrollState"}'>` JSON with
`lastEvaluatedKey` and `showMoreUrl`
(`/hz/wishlist/slv/items?filter=…&paginationToken=<lek>&itemsLayout=LIST&sort=default&type=wishlist&lid=<id>`),
mirrored in hidden `input.showMoreUrl` / `input.lastEvaluatedKey`. Fetching
`showMoreUrl` returns an HTML fragment (`ul#g-items`) with the next 10 items
and a fresh cursor; an empty `lastEvaluatedKey` means the end. Verified
live: 3 pages → 25 items.

### Prior art

- [nateify/amazon-wishlist-exporter](https://github.com/nateify/amazon-wishlist-exporter) —
  the maintained reference (curl_cffi + selectolax, same selectors, captcha
  solver, locale handling, `--html-file` route with a bookmarklet that scrolls
  the list to the end). Its Playwright fixtures were used as test input.
- [Jaymon/wishlist](https://github.com/Jaymon/wishlist), [andre-st/amazon-wishless](https://github.com/andre-st/amazon-wishless),
  [jcapona/amazon-wishlist-scraper](https://github.com/jcapona/amazon-wishlist-scraper),
  [renefritze/pyawl](https://github.com/renefritze/pyawl) — older Python scrapers.
- [doitlikejustin/amazon-wish-lister#31](https://github.com/doitlikejustin/amazon-wish-lister/issues/31) —
  the `lek` / `showMoreUrl` pagination discovery (2018; still the mechanism).
- Hosted actors on Apify (`truenorth/amazon-wishlist-scraper`,
  `crawlerbros/amazon-list-registry-scraper`) use headless browsers; not
  needed here.

## 3. Enrichment sources

### Open Library — primary (free, no key)

Docs: https://openlibrary.org/developers/api. Rate limit 1 req/s anonymous,
3 req/s with a contact in the User-Agent (`MyApp (me@example.org)`). Bulk
needs should use the monthly dumps.

What matters for an Amazon import:

- **ASIN lookup works directly**: `search.json?q=id_amazon:<ASIN>` matches
  both print ASINs and Kindle `B0…` ASINs (verified: `B0095H4Y9W` →
  *Fantastic Mr Fox*). Print ISBN-10 ASINs are better matched via
  `q=isbn:<isbn>` (the `id_amazon` field is sparser than `isbn`).
- The search doc (`fields=` picks them) carries most of what a reading list
  wants in one call: `title, subtitle, author_name, author_key,
  first_publish_year, cover_i, subject, place, person, time,
  ratings_average, ratings_count, want_to_read_count,
  currently_reading_count, already_read_count, readinglog_count,
  number_of_pages_median, edition_count, first_sentence, language,
  id_goodreads, id_amazon, isbn` plus an `editions` sub-document filtered by
  the same query (`editions.key, editions.publisher, editions.publish_date,
  editions.number_of_pages, editions.physical_format, editions.isbn,
  editions.id_amazon`).
- Work record `/works/OL…W.json`: `description` (string or `{type,value}`),
  `subjects`, `subject_places`, `subject_people`, `subject_times`, `genres`
  (mixed names and `/tags/OL…T` keys), `covers`, `links`,
  `identifiers.wikidata` (QID for the work — the bridge to Wikidata).
- Author record `/authors/OL…A.json`: `name, personal_name, bio, birth_date,
  death_date, photos, alternate_names, links, remote_ids {wikidata, viaf,
  isni, goodreads, amazon, librarything, …}`.
- `/works/<id>/ratings.json` and `/bookshelves.json` duplicate the search
  doc's counts; `/authors/<id>/works.json` lists an author's other works.
- Covers: `https://covers.openlibrary.org/b/id/<cover_i>-L.jpg`,
  author photos `…/a/id/<photo>-L.jpg`.
- Legacy `api/books?bibkeys=ISBN:…&jscmd=data` also returns `identifiers`
  (goodreads, storygraph, isfdb…), `classifications` (LCC, Dewey),
  `excerpts` — but the docs say prefer `search.json`.

### Google Books — optional (API key required in practice)

`https://www.googleapis.com/books/v1/volumes?q=isbn:…` (also `intitle:`,
`inauthor:`). `volumeInfo` adds `description`, `categories` (slash-separated
BISAC-ish paths), `averageRating`, `ratingsCount`, `pageCount`,
`publishedDate`, `publisher`, `language`, `maturityRating`, `imageLinks`,
`previewLink`. **Anonymous calls now fail**: the shared anonymous project
answers HTTP 429 `Queries per day … limit value 0`, so a key (free, 1000/day
default) is mandatory. No ASIN lookup — ISBN or title only.

### Hardcover — optional (token required)

GraphQL at `https://api.hardcover.app/v1/graphql`, bearer token from
account settings; free tier 5000 req/day, 60/min, burst 10. `editions`
can be filtered by `isbn_13`, `isbn_10` **or `asin`** (so Kindle books
resolve); the `book` exposes `rating`, `users_count`, `description`,
`cached_tags` (genres / moods / content warnings as tag buckets),
`book_series { position series { name } }`, `release_date`, `slug`.
The query shape in the extension follows the published schema but was not
run end to end (no token available).

### Wikidata — optional (free, no key)

SPARQL at `https://query.wikidata.org/sparql`. Reached through the QIDs Open
Library already stores (`remote_ids.wikidata` on authors,
`identifiers.wikidata` on works), so no fuzzy matching:

- Authors: P27 citizenship, P19 birthplace, P106 occupations, P166 awards,
  P18 image, P569/P570 dates, P1412 languages, enwiki sitelink.
- Works: P136 genre, P166 award (+ P585 year), P179 series (+ P1545
  ordinal), P577 publication date, P921 main subject, P840 narrative
  location, P7937 form, P407 language.

Direct ISBN lookup on Wikidata (P212) is unreliable — ISBNs live on
*edition* items (P629 → work) and most books have none, so the OL bridge is
the practical route.

### Others considered

- **Goodreads API** — retired; its ids survive in Open Library (`id_goodreads`).
- **ISBNdb** — paid; good coverage, no free API tier.
- **WorldCat / OCLC Classify** — Classify shut down; WorldCat Search needs a
  paid key. OL already supplies LCC/Dewey when known.
- **Amazon product pages** — scraping each `/dp/<ASIN>` would give the
  publisher blurb and "Customers also bought", but it is 1 fetch per item
  against the most bot-hostile pages on the site; not worth it when Open
  Library resolves the ASIN directly.
- **Library of Congress, BookBrainz, StoryGraph, LibraryThing** — ids for
  most are already present in OL records (`identifiers`, `remote_ids`) and
  are stored on the nodes for anyone who wants to follow them later.

## 4. Decisions

- **Python, stdlib only.** The `init --lang py` glue needs no `mcp` package,
  so the extension installs with `--from` and runs anywhere python3 exists.
- **Plain HTTP, no browser.** The list page renders server-side and the
  cursor endpoint returns HTML fragments; a 1.5 s pause between pages avoided
  robot checks in testing.
- **Every item is kept** as `(:Item)`; books add `:Edition` and a `(:Book)`.
  The wishlist stays a faithful mirror; book queries filter on the label.
- **Open Library is the spine**; the other sources attach to the OL work key
  and are strictly additive and optional.
- **Idempotent writes** (`MERGE` on list id / ASIN / OL key / term name,
  `IF NOT EXISTS` schema) so a re-run refreshes prices, priorities and
  newly resolvable books. An ASIN that was Amazon-only and later resolves in
  Open Library has its placeholder Book replaced.
