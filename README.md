# relate-book

An Amazon wishlist as a reading-list graph, and an iPhone app to live in it.
Built on [Relate](https://relatedb.ai), the embedded Cypher graph database.

Two parts:

1. **`wishlist-to-graph/`**, a Relate **extension** (`relate run wishlist-to-graph`).
   It fetches a public Amazon wishlist, writes every item into a graph the host
   owns, enriches each book from Open Library (authors, subjects, places,
   characters, ratings, reading-log counts, descriptions, covers), optionally
   adds Google Books, Hardcover and Wikidata facts (genres, series, awards,
   author birthplaces and citizenship), and with `--geocode` puts the places
   on a map through Nominatim.
2. **`ios/`**, **Relate Books**, a SwiftUI iPhone app that bundles an exported
   store (a small public sample; swap in your own) and opens it with the
   embedded Relate engine. Browse and filter the
   list, open book, author and subject pages, mark books read, rate and tag
   them, keep notes, search semantically with an on-device MiniLM model,
   explore the books on a map, and add new books from Open Library, an ISBN
   barcode or by hand. Everything except the add-book lookups and cover
   images works offline.

<p>
  <img src="ios/docs/phase5-library.png" width="19%" alt="Library">
  <img src="ios/docs/phase3-search.png" width="19%" alt="Semantic search">
  <img src="ios/docs/phase4-map.png" width="19%" alt="Map">
  <img src="ios/docs/phase4-place-san-francisco.png" width="19%" alt="Place sheet">
  <img src="ios/docs/phase5-added-detail.png" width="19%" alt="Added book">
</p>

## Quick start: the graph

```bash
curl -sSfL https://relatedb.ai/install.sh | bash          # the relate CLI (macOS, Linux)
relate extension install wishlist-to-graph --from ./wishlist-to-graph
relate run wishlist-to-graph https://www.amazon.com/hz/wishlist/ls/XXXXXXXXXXXXX \
    --contact you@example.com --wikidata -d ./books.rl
relate run wishlist-to-graph --geocode -d ./books.rl      # places -> coordinates (about 9 min for 700 places)
relate query -d ./books.rl "MATCH (a:Author)<-[:WRITTEN_BY]-(b:Book)
  RETURN a.name AS author, count(b) AS books ORDER BY books DESC LIMIT 10"
```

Flags, the graph model, how books are resolved, the geocoder's rules, starter
queries and caveats: [`wishlist-to-graph/README.md`](wishlist-to-graph/README.md).

## Quick start: the app

```bash
cd ios
xcodegen generate
swift test                                # 266 core tests on the Mac
xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rb-dd build
```

Then install and launch on the simulator, or open `RelateBooks.xcodeproj` in
Xcode. Requirements, launch arguments, the embedding pipeline, map data, the
add-book importer, binary sizes and the store lifecycle:
[`ios/README.md`](ios/README.md).

### The bundled sample, and using your own list

The app ships with `ios/RelateBooks/Resources/books.rl`, built from a public
six-book sample wishlist (`https://www.amazon.com/hz/wishlist/ls/9N4X43GP6SVK`):
Getting Things Done, Red Mars, The Curious Incident of the Dog in the
Night-Time, A Truck Full of Money, Project Hail Mary and The Left Hand of
Darkness. To rebuild it, or to put your own list in the app:

```bash
relate run wishlist-to-graph <wishlist-url> --wikidata --geocode -d ./books.rl
ios/scripts/refresh_store.sh ./books.rl     # copies it into the app's resources
```

Your own export stays out of git (`*.rl` is ignored except the bundled
sample), but **do not commit or publish it if your list is personal**: the
store records the list id and URL. The tests do not depend on the bundled
list being large. The perf suites scale it to 1,800 books in a temp copy
(`ios/Tests/RelateBooksCoreTests/ScaledLibrary.swift`), and the functional
and UI tests are written against the sample's six books.

## Requirements

- **Relate 1.0.1.** The iOS package and project depend on the published Swift
  package (`https://github.com/relatedb/relate`, exact version 1.0.1); SwiftPM
  downloads its checksum-pinned `RelateFFI.xcframework` (about 300 MB, once).
  The `relate` CLI (for the extension and ad-hoc Cypher) comes from the
  installer above, the [release page](https://github.com/relatedb/relate/releases),
  or `cargo build --release -p relate-cli` in a Relate checkout.
- **Python 3.10+** for the extension (standard library only).
- **Xcode 27**, **xcodegen** and an iOS 26 simulator for the app. `uv` only if
  you regenerate the Core ML model.

## Layout

```
wishlist-to-graph/
  extension.json          the manifest relate parses (flags, commit policy, executable)
  wishlist-to-graph.py    the extension: MCP client glue, the wishlist walk, enrichment, geocoding
  README.md
ios/
  project.yml             xcodegen spec -> RelateBooks.xcodeproj (both committed)
  Package.swift           RelateBooksCore library + Swift Testing suites
  RelateBooks/            app sources (Graph/, Embedding/, Search/, OpenLibrary/, Geo/, ViewModels/, Features/, App/)
  Tests/, UITests/        core tests (macOS) and XCUITests (simulator)
  docs/                   simulator screenshots, phase by phase
  scripts/                refresh_store.sh, convert_embedding_model.py
docs/
  ios-app-plan.md         the plan, every decision, and a changelog per phase
  research.md             how Relate extensions, Amazon wishlist pages and the metadata sources behave
AGENTS.md                 conventions for coding agents (CLAUDE.md imports it)
```

### Data files and git

- `books.rl` at the root is the extension's output and is **git-ignored**
  (`*.rl`), as is `backups/`. The copy the app bundles,
  `ios/RelateBooks/Resources/books.rl` (the six-book sample, 212,992 bytes,
  with Wikidata facts and geocoded places), **is tracked** so a clone builds
  and the tests run. Refresh it with `ios/scripts/refresh_store.sh`.
- The Core ML model `ios/RelateBooks/Embedding/Model/MiniLM_L6_v2.mlmodelc`
  (45 MB, mostly `weights/weight.bin`) is tracked too. It is below GitHub's
  file-size limit, but it is binary and changes rarely. If it ever needs to be
  replaced more than once or twice, move it to Git LFS. It is reproducible
  byte for byte with `ios/scripts/convert_embedding_model.py`.
- Nothing here contains credentials. The extension reads an optional
  `GOOGLE_BOOKS_API_KEY` and `HARDCOVER_API_TOKEN` from the environment at run time.

## Status

- **Extension** 0.2.0. On relate 1.0.1 the sample list imports with
  `--wikidata --geocode` in about 30 seconds (6 books, 8 authors, 173
  subjects, 58 awards, 34 places, 19 on the map). On relate 0.16.1, a
  2,002-item amazon.com list imported in 52 minutes (1,811 books, 1,757
  resolved) and geocoded in 9 minutes (600 of 693 places located). Google
  Books and Hardcover are wired but have not been run end to end (no
  credentials).
- **App** phases 0 to 5 of the plan are implemented and verified on the
  iPhone 17 simulator: scaffold, browse, reading status/tags/notes, semantic
  search, map, add books. 266 core tests, 12 UI tests. Phase 6 (offline covers,
  importing a newer export, export, share) is next.

## Privacy and rate limits

The extension and the app identify themselves to Open Library and Nominatim
with a User-Agent that names this repository. A contact address is sent only
when you pass `--contact`. Both respect the services' one-request-per-second
guidance; the extension caches geocoding results in
`~/.cache/relate-book/geocode.json` so re-runs make no requests.

## Amazon

The extension reads the public HTML of a wishlist you point it at, slowly
(one page every 1.5 s by default) and only when you run it. Use it on lists
you own or have been given, and check that your use fits Amazon's Conditions
of Use. This project is not affiliated with or endorsed by Amazon.

## Contributing

Issues and pull requests are welcome. [`AGENTS.md`](AGENTS.md) is the short
guide to conventions, build and test commands, and the rules that are easy to
get wrong; it applies to humans and coding agents alike. In short: core logic
comes with a Swift Testing case, Cypher is tried on a store copy with the CLI
before it lands in a query file, the perf suite stays green, and behaviour
changes go into the changelog in [`docs/ios-app-plan.md`](docs/ios-app-plan.md)
and the README closest to the code.

## License

[Apache License 2.0](LICENSE). Third-party material (the MiniLM model, the
data in the sample store, map and cover imagery in the screenshots) is listed
in [`NOTICE`](NOTICE).
