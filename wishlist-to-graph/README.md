# wishlist-to-graph

A [Relate](https://relatedb.ai) extension that turns a public Amazon wishlist
into a reading-list graph: the list and its items, the books behind them,
their authors, subjects, places, characters, genres, series, awards and
community ratings — enriched from Open Library and, optionally, Google Books,
Hardcover and Wikidata. With `--geocode` it also puts the places on a map
(Nominatim, cached on disk; see [Geocoding](#geocoding)).

The package is `extension.json` (the manifest) plus `wishlist-to-graph.py`
(the executable — a minimal MCP client with the transport generated inline by
`relate extension init`, so there is nothing to `pip install`). Python 3.10+
is the whole runtime.

## Install and run

```bash
relate extension install wishlist-to-graph --from ./wishlist-to-graph
relate run wishlist-to-graph https://www.amazon.com/hz/wishlist/ls/XXXXXXXXXXXXX \
    --contact you@example.com -d ./books.rl
```

The list must be **Public** (or Shared with a link); the share URL from the
list's *Send list to others* menu works as-is, and so does a bare list id with
`--domain amazon.co.uk`. A private list redirects to sign-in: open it in your
browser, scroll to the end so every item has loaded, save the page
(*Web Page, Complete* — not *HTML only*) and pass the file:

```bash
relate run wishlist-to-graph --html-file ~/Downloads/my-list.html -d ./books.rl
```

`--contact` is optional but recommended: Open Library allows 3 requests per
second for clients that identify themselves in the User-Agent, 1 per second
otherwise, and the enrichment makes two to four requests per book.

Without `-d` the import lands in `:memory:` and the interactive shell opens on
the graph with the starter queries loaded.

## Flags

| Flag | Default | What it does |
| --- | --- | --- |
| `WISHLIST` (positional) | — | The wishlist URL (any marketplace, short links followed) or bare list id |
| `--domain` | `amazon.com` | Marketplace host for a bare id, or for `--html-file` when the page carries no canonical URL |
| `--html-file PATH` | — | Parse a page saved from the browser instead of fetching (the private-list route) |
| `--contact` | — | Email (or URL) added to the User-Agent sent to Open Library, Wikidata and Nominatim (`--geocode`); it is appended to the User-Agent and nothing else is ever sent |
| `--delay-ms` | `1500` | Pause between Amazon page fetches (the list paginates 10 items at a time) |
| `--max-items` | `0` | Import only the first N items (0 = all) — handy for a dry run |
| `--skip-enrich` | off | Write the wishlist and items only; books get a Book node from the Amazon data |
| `--google-books` | off | Also query Google Books (needs `GOOGLE_BOOKS_API_KEY`; the anonymous quota is 0/day) |
| `--hardcover` | off | Also query Hardcover's GraphQL API (needs `HARDCOVER_API_TOKEN`) |
| `--wikidata` | off | Also query Wikidata for author facts and work genres/awards/series (no key) |
| `--geocode` | off | Geocode every `Place` that has no location yet (Nominatim, 1 request per second, cached on disk) and add a point index; with no `WISHLIST` it runs on the existing store only |
| `--geocode-limit N` | `0` | Geocode at most the first N places, most-booked first (0 = all); for dry runs |

Re-running against the same store refreshes it in place (everything is
`MERGE`d on stable keys: list id, ASIN, Open Library key, term name).

## Graph model

```
(:Wishlist {id, title, description, owner, domain, url, imported_at, item_count, book_count})
  -[:CONTAINS {position, priority, priority_label, comment, date_added, quantity_requested, quantity_purchased}]->
(:Item {asin, title, url, byline, format, is_book, isbn10, isbn13, price, currency, amazon_rating,
        amazon_review_count, image_url, thumbnail_url, availability, used_and_new, option, contributor_names})

(:Item:Edition {+ publish_date, publish_year, pages, physical_format, language, ol_edition_key})
  -[:EDITION_OF]->(:Book)
  -[:PUBLISHED_BY]->(:Publisher {name})

(:Book {key, title, subtitle, description, first_sentence, first_publish_year, cover_url, url,
        ol_rating, ol_rating_count, ol_want_to_read, ol_currently_reading, ol_already_read,
        pages_median, edition_count, languages, goodreads_ids, amazon_asins, wikidata, link_urls,
        match ('identifier'|'title'), source ('openlibrary'|'amazon'),
        google_* (with --google-books), hardcover_* / moods (with --hardcover),
        form, original_language, main_subjects, wikidata_publication_date (with --wikidata)})
  -[:WRITTEN_BY {role}]->(:Author {key, name, personal_name, bio, birth_date, death_date, photo_url,
                                   alternate_names, wikidata, viaf, isni, goodreads_id,
                                   amazon_author_id, wikipedia_url, url,
                                   occupations, languages, image_url (with --wikidata)})
  -[:ABOUT]->(:Subject {name})        -[:SET_IN]->(:Place {name})
  -[:FEATURES]->(:Person {name})      -[:SET_DURING]->(:Era {name})
  -[:IN_GENRE]->(:Genre {name})       -[:PART_OF {position}]->(:Series {name})
  -[:WON {year}]->(:Award {name, wikidata})

(:Author)-[:WON]->(:Award)   (:Author)-[:CITIZEN_OF]->(:Country)   (:Author)-[:BORN_IN]->(:Place)

(:Place {name, location: point, geocoded_label, geo_source, geo_status, geo_query, geo_reason,
         geo_display_name, geo_place_type, geo_osm, geo_region, geo_lat, geo_lon})   (with --geocode)
```

Every wishlist row is an `(:Item)`. Rows whose byline names a book binding
(Paperback, Hardcover, Kindle Edition, Audible Audiobook, Board book, …) or
whose ASIN is a valid ISBN-10 also carry the `:Edition` label and get a
`(:Book)`. Non-book rows (`(Apparel)`, `(Vinyl)`, `(Electronics)` …) stay
plain items, so the list is complete and the book queries stay clean.

Unique constraints on every key above, range indexes on `Item.isbn13`,
`Item.title`, `Book.title`, `Author.name`, and two fulltext indexes
(`book_text` over title/description/first sentence, `item_text` over
title/byline). The schema also declares a point index on `Place.location`
(`place_location`, used by `point.withinBBox` and `point.distance`) and a
range index on `Place.geocoded_label` (`place_label`).

## Geocoding

```bash
relate run wishlist-to-graph --geocode -d ./books.rl
relate run wishlist-to-graph --geocode --contact you@example.com -d ./books.rl   # identified
```

With no `WISHLIST` the run touches nothing but the `Place` nodes of the
existing store: no Amazon, Open Library or Wikidata requests. A full import
can add `--geocode` too; it geocodes after the import, and the summary line
gains a `geocode: …` clause.

### What it does

Open Library places are Library-of-Congress style headings
("Los Angeles (Calif.)", "Washington (State)", "États-Unis", "West (U.S.)",
"Mars"). For each `Place` with no `location` and no earlier verdict
(`geo_status`), most-booked first:

1. **Normalize the heading.** A parenthetical qualifier becomes the comma form,
   with LC abbreviations expanded (`Butte (Mont.)` → `Butte, Montana`,
   `Brooklyn (New York, N.Y.)` → `Brooklyn, New York City`,
   `Washington (State)` → `Washington State`, featuretype state). The
   qualifier also gives a `countrycodes` hint (us, ca, gb, …). Broken
   parentheses are repaired, a `;` list keeps its first entry, and a trailing
   Region/Valley/Watershed/Area/Municipality/Kommun gets a second query
   without it.
2. **Synonym and region tables.** Foreign-language and duplicate headings map
   to one canonical English name (`États-Unis`, `USA`, `America` → United
   States; `Californie` → California; `New York (N.Y.)` → New York City;
   `Côte d'Azur (France)` → French Riviera). About 30 regions and landmarks
   Nominatim answers badly (West (U.S.), Pacific Northwest, Great Plains,
   Latin America, Soviet Union, Patagonia, Santa Clara Valley, the North and
   South Poles, the Kremlin, Monticello, the Cascade Range, Mann Gulch, the
   Lower Elwha Reservation, …)
   get a hand-picked pin with no
   request (`geo_source = 'manual'`).
3. **Fictional and non-terrestrial denylist.** Planets, moons, stars
   (`Tau Ceti e`, `40 Eridani A`), Mars features, "Earth", "Outer space",
   "Imaginary places", fictional settings in this store (Gethen, Ankh Morpork,
   Asgard, …), `(fictional planet)` qualifiers and non-places ("Dogs",
   "Developing countries", unresolved Wikidata ids like "Q975") are marked
   `geo_status = 'skipped'` and never queried, even though Nominatim would
   cheerfully return Mars, Pennsylvania.
4. **Acceptance rule.** Of Nominatim's 3 results, those that pass all of:
   a type allowlist (administrative, ceremonial and natural boundaries, national parks,
   protected and aboriginal lands, any `place` but houses, natural features,
   water bodies, nature reserves and parks, landuse, attractions, historic
   sites, waterways, landmark towers/bridges/cathedrals/castles/palaces, and
   named libraries, universities and hospitals; never shops, restaurants,
   offices, roads, stations or ordinary buildings); a name rule (the heading's
   significant words must all appear in the result's name or one of its
   `namedetails` variants, with at most one extra word, so "Greater London"
   passes for London and "Santa Clara Valley Transportation Authority" fails);
   and, for one-word bare headings, an importance floor of 0.30 (the hamlet
   called Asgard fails). Among those, the first wins, with three corrections:
   - a match on the result's own name beats an earlier match that only came
     through a `namedetails` variant, when its importance is comparable
     ("Reno" is Reno, Nevada, not the Rhine, whose Italian name is Reno);
   - an "X County" / "X Prefecture" / "X Oblast" (or township, parish,
     municipality, district) listed just before an exact "X" of similar
     importance yields to it, preferring one in the same state, then the same
     country (`Monterey (Calif.)` is the city, not Monterey County; bare
     "Nagasaki" is the city);
   - an unqualified heading is checked against the **other places of the same
     books** (the states and countries their headings name: "Montana",
     "(Mont.)", "Washington (State)", "Pacific Northwest", …). A result outside
     them with importance below 0.35 is not trusted, a result inside them
     further down the list is preferred, and if none is accepted the pass asks
     once more with the book's state (`Lisbon Falls, Maine`) and then with
     its country code. Those extra answers must contain every word of the
     heading, so "La Brea" never matches the city of Brea. "Lisbon Falls" on a Maine book is Lisbon Falls, Maine, not
     the waterfall in South Africa.
   - a birthplace with no book places to go by is checked the same way
     against its **authors' citizenships** (`CITIZEN_OF`, from Wikidata;
     historical states such as the Russian Empire or the Soviet Union are
     ignored). Citizenship is weaker evidence than a book's places, so it only
     moves a pin to a result further down the list with at least 65 % of the
     first one's importance: Birmingham is Birmingham, Alabama for Walker
     Percy and E. O. Wilson, Cambridge is Cambridge, Massachusetts for Richard
     Henry Dana, while an immigrant's Toronto or Vienna stays put. An
     "X County" in the right country does not stand for a town called X: the
     pass asks once more within that country and otherwise keeps its first
     choice.

   A bare heading that shares a book with the same name plus a qualifier
   (`Osage County` next to `Osage County (Okla.)`, `Washington` next to
   `Washington (State)`) borrows that heading's query, so both land on one
   pin. Otherwise the place is `geo_status = 'unresolved'` with the reason in
   `geo_reason`.
5. **Labels.** Headings that name the same place share one `geocoded_label`
   and one `location`: same OSM object, or the same base name within 50 km.
   The label is the canonical name when a table supplied one, else the
   most-booked heading's name; two different places with the same name get a
   suffix (`Newark, New York`). Labels are recomputed over every located
   place on every run, so a later partial run still merges with earlier ones.
   A map groups by `geocoded_label` and counts distinct books per label.

The pass only `MATCH`es places by name and `SET`s properties; it never
creates, removes or deletes nodes.

### Nominatim usage policy, as honoured

The [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/):

- at most 1 request per second (1.05 s apart), single-threaded;
- an identifying User-Agent: `relate-book-wishlist-to-graph/0.2.0 (+https://github.com/johnymontana/relate-book)`,
  plus `; <contact>` when you pass `--contact` (no address is ever added otherwise, and no `email=` parameter is sent);
- every answer cached on disk, including empty ones, so nothing is fetched twice;
- retries with back-off on 429/5xx, honouring `Retry-After`;
- `Accept-Language: en`, so labels and display names come back in English;
- an HTTP 403/401 (or five errors in a row) stops the pass at once; what was done so far is kept;
- no bulk re-fetching: re-runs and fresh re-exports are served from the cache.

### Cache

`~/.cache/relate-book/geocode.json`, written atomically (temp file + rename)
every 10 new entries and at the end. Keys are the folded query plus the
countrycodes and featuretype hints (`q=montana|cc=us|ft=`). Delete the file,
or a single entry, to force a refetch. A corrupt file is moved aside
(`geocode.json.corrupt-<time>`) and the pass starts with an empty cache.

### Time

About 700 headings take about 10 minutes once: the first run on this
store's 693 headings made 497 requests in 8 min 48 s. A re-run on the same store makes 0 requests (every place already has
a verdict); a run on a fresh re-export is all cache hits and takes seconds.

### Checking the result

```cypher
// The audit: what was skipped or not found, and why
MATCH (p:Place) WHERE p.geo_status IN ['unresolved','skipped']
RETURN p.geo_status AS status, p.name AS place, p.geo_query AS query, p.geo_reason AS reason
ORDER BY status, place;

// Coverage of the places with two or more books
MATCH (p:Place)
WITH p, COUNT { (p)<-[:SET_IN]-(:Book) } AS books
WHERE books >= 2
RETURN count(p) AS places, count(p.location) AS located,
       round(100.0 * count(p.location) / count(p), 1) AS pct,
       count(CASE WHEN p.geo_status = 'skipped' THEN 1 END) AS skipped,
       [x IN collect(CASE WHEN p.location IS NULL THEN p.name + ' [' + coalesce(p.geo_status, 'untried') + ']' END) WHERE x IS NOT NULL] AS missing;
```

### A dry run

```bash
cp books.rl /tmp/dry.rl
relate run wishlist-to-graph --geocode --geocode-limit 20 -d /tmp/dry.rl
relate query --read-only -d /tmp/dry.rl "MATCH (p:Place) WHERE p.geo_status IS NOT NULL RETURN p.name, p.geo_status, p.geocoded_label, p.location, p.geo_display_name, p.geo_reason ORDER BY p.name"
```

`--geocode-limit` counts headings, not requests (skipped and region headings
make none), and each run takes the next N untried headings. The heading
normalizer, the acceptance rule and the labels have offline checks:
`python3 -I wishlist-to-graph.py --self-test`.

### Retrying failures

```sh
relate query -d ./books.rl "MATCH (p:Place) WHERE p.geo_status = 'unresolved' REMOVE p.geo_status, p.geo_query, p.geo_reason"
```

Then re-run `--geocode`. That only helps if the normalizer changed (a new
query string is a new cache key) or the cache entries were deleted.

### Full reset

Never touches places the app geocoded itself (`geo_source = 'apple'`):

```sh
relate query -d ./books.rl "MATCH (p:Place) WHERE p.geo_source IN ['nominatim','manual'] OR p.geo_status IN ['unresolved','skipped'] REMOVE p.location, p.geocoded_label, p.geo_source, p.geo_status, p.geo_query, p.geo_reason, p.geo_display_name, p.geo_place_type, p.geo_osm, p.geo_region, p.geo_lat, p.geo_lon"
```

### Limits

- An author birthplace with no book of its own is judged by its authors'
  citizenships, which only helps when Nominatim's top 3 results include the
  right country. An unqualified Wikidata label still takes the most
  prominent match in that country, which can be the wrong namesake
  (Mary Roach's Etna, New Hampshire becomes Etna, Pennsylvania; Jonathan
  Maberry's Kensington, Philadelphia becomes Kensington, New York), and a
  name whose top 3 are all abroad stays abroad (Sebastian Junger's Belmont,
  Massachusetts is pinned in France). When the right country only offers
  counties, the first choice stands too (James Clear's Hamilton, Ohio stays
  Hamilton, Ontario; A. B. Guthrie's Bedford, Indiana stays Bedford,
  England). Storing Wikidata coordinates (P625) at
  import time would settle these; `--wikidata` does not store them yet.
- Book context only helps when the book's other headings name a state or a
  country; a bare heading on a book with no other places takes the most
  prominent match.
- Streets, single buildings, hotels and former entities (Wall Street, the
  Metropol Hotel, Mandatory Palestine) stay unresolved by design; see the audit.
- Region pins sit at hand-picked centroids; historical entities (Soviet
  Union, Western Front, Silk Road) get symbolic pins.
- `point.withinBBox` does not wrap the antimeridian: split a box that
  crosses it.

## How the import resolves a book

1. ASIN that is an ISBN-10 → Open Library `search.json?q=isbn:…`
2. Any other ASIN (Kindle `B0…` included) → `search.json?q=id_amazon:…`
3. ISBN-10 still unmatched → `/isbn/{isbn}.json` → the edition's work
4. Otherwise a title + author search; the first candidate whose author's
   surname matches the Amazon byline wins (`Book.match = 'title'`).

The matching work's search document supplies ratings, reading-log counts,
subjects/places/people/times, first sentence, cover, Goodreads ids and the
edition sub-document for the ASIN (publisher, publish date, pages, ISBNs);
the work record adds the description, links and the Wikidata QID; each
author record adds bio, dates, photo and remote ids. A book Open Library
does not know gets a `Book {key: 'amazon:<ASIN>', source: 'amazon'}` with the
byline contributors as authors, so every edition still has its work.

## Starter queries

The run prints them; a few highlights:

```cypher
// What is on the list, by priority and community rating
MATCH (w:Wishlist)-[c:CONTAINS]->(i:Edition)-[:EDITION_OF]->(b:Book)
RETURN i.title, i.format, c.priority_label, i.price, b.ol_rating, i.amazon_rating
ORDER BY c.priority DESC, b.ol_rating DESC LIMIT 25;

// Books on the list that share three or more subjects
MATCH (b1:Book)-[:ABOUT]->(s:Subject)<-[:ABOUT]-(b2:Book) WHERE b1.key < b2.key
WITH b1, b2, count(s) AS shared WHERE shared >= 3
RETURN b1.title, b2.title, shared ORDER BY shared DESC LIMIT 20;

// Fulltext over descriptions
CALL db.index.fulltext.queryNodes('book_text', 'photography OR jazz') YIELD node, score
RETURN node.title, score LIMIT 10;
```

## Limits and caveats

- Anonymous views of a public list do not include *date added*; Amazon only
  renders it for the signed-in owner. `--html-file` from your own browser
  session does carry it, and the importer parses it when present.
- Amazon rate-limits aggressively. The default 1.5 s pause between pages has
  been fine for lists of a few hundred items; a robot check fails the run
  with a message pointing at `--delay-ms` and `--html-file`.
- Amazon's markup changes without notice. The selectors are the `itemName_`,
  `item-byline-`, `itemPrice_`, `itemPriority_`, `itemComment_`,
  `itemAddedDate_`, `review_stars_`, `review_count_`, `itemImage_` ids and the
  `scrollState` pagination cursor, the same hooks the maintained
  [amazon-wishlist-exporter](https://github.com/nateify/amazon-wishlist-exporter) uses.
- Hardcover and Google Books paths are implemented against their documented
  schemas but were not exercised end to end here (no API credentials were
  available); errors from either are logged and skipped, never fatal.
