# Relate Books (iOS)

Relate Books is a SwiftUI iPhone app. It bundles a `books.rl` graph store exported by wishlist-to-graph and opens it with the embedded Relate graph database. The tracked store is a public six-book sample (see [Bundled store](#bundled-store)); `scripts/refresh_store.sh` puts your own export in its place. Phases 1–5 are implemented: 1 ("Browse"), 2 ("User data"), 3 ("Semantic search"), 4 ("Map") and 5 ("Add books"):

- **Library tab.** Every book with its cover, title, authors, format, status badge and price. You can sort it (title, author surname, wishlist order, Open Library rating, publish year), filter it with chips (status, format, genre, unresolved), and search it as you type (title, author or Amazon title; search starts at 2 characters). It pages 40 rows at a time with infinite scroll.
- **Book detail.** Amazon price and rating with "Open on Amazon", authors, series, awards with years, genres, subjects, places, people, eras, publishers, description, Open Library facts, and every wishlist edition. Every facet links on.
- **Author page.** Photo, dates, occupations, the author's books on the list, bio, birthplace, citizenship, awards, and Wikipedia, Wikidata and Open Library links.
- **Your reading (phase 2).** Book detail has a Want / Reading / Read segmented control with the started and finished dates, a 1–5 star rating, tags (chips plus a picker that adds an existing tag or creates a new one) and plain-text notes (newest first, with add, edit and delete). Library rows have status swipe actions (leading: Read / Reading, trailing: Want) and show your rating.
- **Tags tab (phase 2).** Lists tags by book count, then name. Tap a tag to see its books; swipe or long-press to rename, recolour or delete. The Library has a matching **Tag** filter chip and a **Recently updated** sort (most recent status change first; untouched books last, by title).
- **Semantic search (phase 3).** A Search tab with one field. You can describe a book ("lonely astronaut saves earth") or type a title or author. Hybrid search fuses on-device MiniLM vectors, the fulltext indexes and your notes. Each result row carries its match reason ("Semantic 0.59", "Keyword (title or author)", "Semantic 0.52 + keyword", "Your note: “…”"). Status and tag filters sit in the toolbar. Book detail gains a **More like this** strip: the 10 nearest books by stored embedding. On first launch the app embeds every book on device, in the background, and shows a thin banner ("Indexing 412 of 1,811 books…" on a full-size list; the six-book sample finishes in a few seconds). Search works throughout and says how much is covered so far.
- **Map tab (phase 4).** An `MKMapView` of the places books are set in: one pin per place label (every heading that geocoded to the same place, e.g. United States / USA / États-Unis, shares one pin), coloured by book count and clustered with summed book counts. A **Birthplaces** toggle adds the places authors were born in as a second layer (purple, clustered separately). Tapping a pin opens the **place sheet**: the label, "N books", "N authors born here", the headings filed under it ("Also filed as: …"), the books set there (title order, paged; a row pushes Book detail inside the sheet) and the authors born there. A **place search** field at the top finds a label or heading as you type (2+ characters) and flies to it. A capsule at the bottom says how many places are in view ("3 places in view").
- **Add books (phase 5).** A **+** button on the Library opens **Add Book** with a Search / Scan / Manual control. **Search** queries Open Library as you type (3+ letters) and shows covers, titles, authors and first years; a work already in the store is badged **In your library** and opens at once, any other asks "Add “…”?" first. **Scan** reads an ISBN barcode with the camera (VisionKit) and always offers a typed ISBN field with check-digit validation. **Manual** saves a title and authors with no lookup. The import shows its steps ("Checking your library…", "Looking up…", "Saving…", "Locating places… 1 of 2", "Indexing…") and ends on the book's detail with "Added to your library" (or "Already in your library" for a book you have). App-added books show an **Added in app** section (date, how it was added, ISBN, publisher and year) where wishlist books show the Amazon price, and "Added in app" in list rows. New places the import creates are geocoded on device, so the book reaches the Map, and the book is embedded within seconds for semantic search.
- **Term pages.** One generic `TermBooksView` covers subjects, genres, series (in series order), places, people, eras, publishers, awards and countries. Places, countries and awards also list linked authors. A place page has **Show on map** (switches to the Map tab, flies there and opens the sheet), or says why the place has no pin ("Not on the map: fictional or not a real place" / "Not on the map: location unknown").
- **Graph features.** Four things the graph does that neither the lists nor the vectors do alone (details in [Graph features](#graph-features)):
  - **Graph-expanded search.** The top search hits pull in their neighbours: the rest of a series, the author's other books, books that share an award or a rare subject, place, person or era. A result found only this way says why ("Same series as The Left Hand of Darkness").
  - **Reasons.** A search row names the book's strongest link to something you have read or rated ("Shares “American Science fiction” with The Left Hand of Darkness, which you rated 5"). Book detail lists up to three such links, each to a different book, under **Connected to your reading**, and each **More like this** card says what it shares with the book on screen.
  - **Next Up.** A sparkles button on the Library opens a screen with series you have started (the next unread book, by position), unread books by authors you rated 4 or 5, and unread award winners.
  - **Near your reading.** A book button on the Map lists unread books set where a book you read is set, or within 250 km of it; choosing one flies the map there.

The full roadmap is in [`../docs/ios-app-plan.md`](../docs/ios-app-plan.md).

## Requirements

- **Full Xcode 27 or later.** Swift Testing macros need it. With only the CommandLineTools, `swift test` fails with "plugin for module 'TestingMacros' not found".
- **xcodegen** (`brew install xcodegen`).
- **Network on first resolve.** Relate 1.1.0 is the published Swift package `https://github.com/relatedb/relate`, pinned with `exact: "1.1.0"` in `Package.swift` and `exactVersion: 1.1.0` in `project.yml`. SwiftPM downloads its checksum-pinned `RelateFFI.xcframework.zip` (377,347,553 bytes) once and caches it. `Package.resolved` (for `swift`) and `RelateBooks.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (for Xcode) record the revision, `f529cbb`. The exact pin is deliberate: tests and these notes record engine behaviour, so an upgrade should be a reviewed change. 1.1.0 is the first release with the Swift API the app is written against (ADR-0596: managed `read`/`write`, `Statement`, `Record`, the Foundation, Core Location and vector bridges, `Migrator`, `Database.provision`, the trace handler).

`RELATE_LOCAL_XCFRAMEWORK` is no longer used; unset it if a shell still exports it, because Relate's manifest then looks for a locally built framework instead of the release binary. From 2026-11-15 to 2026-11-17, before a release carried the API, the app was built from a source snapshot of Relate's `main` (`af8c2e4`) in `Vendor/relate` with that variable set; a `Vendor/` directory left over from then can be deleted. To try an unreleased engine again, point both manifests at a checkout with `scripts/build-xcframework.sh` run in it, and set the variable.

## Build

```sh
cd ios
scripts/refresh_store.sh [path]     # only to bundle a different export (default ../books.rl)
xcodegen generate                   # after adding/removing files
swift test                          # core tests on the Mac (macOS slice)
xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rb-dd build
```

- `swift test` should end with `Test run with 293 tests in 40 suites passed` (phase 5 was 266 in 35; the move to the new Relate API made it 270). An extra XCTest line, "Executed 0 tests", is normal. Parameterized tests count once.
- The **perf suite** (`PerfTests.swift`) bootstraps a temp copy of `RelateBooks/Resources/books.rl`, grows it to 1,800 books with `ScaledLibrary` (300 copies of the six sample books, authors and editions under distinct keys; shared subjects, awards and other terms; the first 30 copies also clone the places at shifted coordinates, for 570 located places and 510 map labels), and runs 194 library, detail, term, user-data, search, graph and place queries, including the recently-updated sort and the tag filter. The perf store is seeded with statuses on 300 books, a 200-book tag, a 3-book tag, random unit 384-d vectors on 400–402 books and 60 embedded notes. The real model never runs in PerfTests. Current lines (2026-11-17, Relate 1.1.0, scaled sample, median of 5 warm runs, this Mac; the 2026-11-15 run on Relate `main` at `af8c2e4` had a slowest median of 21.94 ms, and the 2026-11-12 run on 1.0.1 had 187 queries and a slowest median of 22.31 ms):

  ```
  PERF places: 570 located, 510 world pins
  PERF semantic top50: cold 3.99 ms, median 3.84 ms, max 3.91 ms, rows 50
  PERF bookText [lonely astronaut saves earth]: cold 24.57 ms, median 23.52 ms, max 23.91 ms, rows 50
  PERF moreLikeThis Project Hail Mary: cold 4.27 ms, median 4.05 ms, max 4.32 ms, rows 10
  PERF related 5 seeds: cold 2.75 ms, median 2.46 ms, max 2.60 ms, rows 0
  PERF readingLinks 50 keys: cold 11.56 ms, median 11.24 ms, max 11.53 ms, rows 0
  PERF connections to Left Hand, 10 keys: cold 5.14 ms, median 4.85 ms, max 5.04 ms, rows 0
  PERF nextUp series: cold 1.60 ms, median 1.34 ms, max 1.41 ms, rows 1
  PERF nextUp authors: cold 0.26 ms, median 0.21 ms, max 0.27 ms, rows 0
  PERF nextUp awards: cold 7.90 ms, median 7.84 ms, max 8.05 ms, rows 10
  PERF placeRegion world: cold 11.13 ms, median 10.51 ms, max 10.70 ms, rows 510
  PERF placeBooks San Francisco p0: cold 2.08 ms, median 1.85 ms, max 1.89 ms, rows 40
  PERF placeAuthors New York City: cold 1.62 ms, median 1.40 ms, max 1.42 ms, rows 271
  PERF nearReading 250 km: cold 8.89 ms, median 8.36 ms, max 8.71 ms, rows 5
  PERF summary: 194 queries; slowest median 23.52 ms (bookText [lonely astronaut saves earth])
  PERF import summary: 19 queries; slowest median 24.05 ms (import bookText [perfect storm])
  ```

  The three connection lines return no rows here on purpose: on the scaled store every shared subject, award and series is on hundreds of books, so they time the degree check that keeps hubs from being expanded. On a temporary copy of a real 1,811-book list (151 books marked read), the same statements took 3.4 ms (related, 5 seeds, 10 rows), 13 ms (reasons for 50 books), 0.5 ms (connections to one book), about 2 ms for the three Next Up statements together and 5 ms for near-your-reading. Those were measured before the weight floor, the noise rules and the place cap were added, which only remove work.

  These are engine-reported statement times. Every write now runs inside a transaction, and the write lines are far lower than a statement that commits itself would be (`writeBooks 32 rows` reads 0.37 ms), so they most likely no longer include the commit; that was not isolated. What a screen waits for is the wall-clock time of the call, which the reader pool changes: on the same scaled store, the first library page took 4.1 ms (median) with nothing else running, and 4.5 ms median, 7.5 ms at the 95th percentile and 9 ms at worst while the indexer embedded all 1,800 books with the instant test embedder. Before the migration (one connection behind an actor, Relate 1.0.1) the same measurement gave 5.0 ms idle and 11 ms median, 15 ms at the 95th percentile and about 470 ms at worst during indexing. Three runs each, about 300 and 125 page reads during indexing; a one-off test, not part of the suite.

  The historical lines below were measured on the original 1,811-book export (phases 3–5, relate 0.16.1) and are kept for comparison. Phase 3 lines:

  ```
  PERF semantic top50: cold 3.61 ms, median 3.18 ms, max 3.49 ms, rows 50
  PERF bookText [lonely astronaut saves earth]: cold 17.83 ms, median 18.38 ms, max 19.16 ms, rows 50
  PERF itemText [lonely astronaut saves earth]: cold 13.96 ms, median 12.79 ms, max 13.93 ms, rows 22
  PERF notes top20: cold 0.48 ms, median 0.32 ms, max 0.35 ms, rows 12
  PERF moreLikeThis Project Hail Mary: cold 3.59 ms, median 3.57 ms, max 3.84 ms, rows 10
  PERF hydrate 150 keys [status=want]: cold 2.54 ms, median 2.53 ms, max 3.04 ms, rows 50
  PERF writeBooks 32 rows: cold 7.88 ms, median 6.66 ms, max 7.56 ms, rows 1
  PERF summary: 170 queries; slowest median 32.96 ms (libraryPage author [text=an] p0)
  ```

  Phase 4 adds 16 place queries with their own 30 ms budget (and a guard that the bundled store is geocoded: more than 300 located places after scaling). The place statements now target San Francisco and New York City instead of Montana and London. Lines from the phase 4 run (the summary is now `187 queries; slowest median 28.10 ms (libraryPage author [text=an] p0)`):

  ```
  PERF places: 600 located, 482 world pins
  PERF placeRegion world: cold 10.15 ms, median 10.60 ms, max 11.13 ms, rows 482
  PERF placeRegion US: cold 5.77 ms, median 5.49 ms, max 5.62 ms, rows 269
  PERF placeRegion Europe: cold 2.31 ms, median 1.90 ms, max 2.08 ms, rows 98
  PERF placeRegion Montana: cold 0.55 ms, median 0.44 ms, max 0.52 ms, rows 18
  PERF placeRegion Seattle: cold 0.13 ms, median 0.12 ms, max 0.13 ms, rows 2
  PERF placeRegion antimeridian 170..180: cold 0.09 ms, median 0.10 ms, max 0.17 ms, rows 1
  PERF placeRegion antimeridian -180..-160: cold 0.08 ms, median 0.07 ms, max 0.07 ms, rows 0
  PERF placeSearch [mont]: cold 1.34 ms, median 1.24 ms, max 1.27 ms, rows 20
  PERF placeSearch [new york]: cold 1.15 ms, median 0.98 ms, max 1.05 ms, rows 6
  PERF placeSearch [an]: cold 3.71 ms, median 3.48 ms, max 3.88 ms, rows 20
  PERF placeSummary Montana: cold 0.21 ms, median 0.16 ms, max 0.17 ms, rows 1
  PERF placeBooks Montana p0: cold 1.18 ms, median 0.99 ms, max 1.16 ms, rows 29
  PERF placeBooks United States p0: cold 2.05 ms, median 1.81 ms, max 2.50 ms, rows 40
  PERF placeAuthors London: cold 0.22 ms, median 0.12 ms, max 0.13 ms, rows 14
  PERF placeResolve Montana: cold 0.77 ms, median 0.60 ms, max 0.65 ms, rows 1
  PERF placeLocation Montana: cold 0.04 ms, median 0.03 ms, max 0.03 ms, rows 1
  PERF placesNear Missoula 500 km: cold 0.27 ms, median 0.22 ms, max 0.22 ms, rows 20
  ```

  Phase 5 leaves PerfTests unchanged (every budget still met: "PERF summary: 187 queries; slowest median 25.01 ms (libraryPage author [text=an] p0)"; the library and detail projections now tolerate books without an `Item`). `ImportRealStoreTests` runs the whole import pipeline (stub transport, stub geocoder) on the same scaled temp copy, seeded with a located "New England" (one of The Perfect Storm's places, which a real export already has), with The Perfect Storm imported, under `HeavyTestGate`, with the same budgets. Its phase 5 lines (median of 5 warm runs):

  ```
  PERF import bookByISBN PHM 0.73 ms
  PERF import existingBooks 21 0.05 ms
  PERF import missingPlaces 3 0.03 ms
  PERF import libraryPage [text=perfect storm] 2.71 ms
  PERF import detail Perfect Storm 4.79 ms
  PERF import libraryPage title p0 6.67 ms
  PERF import libraryPage wishlist skip 1800 14.56 ms
  PERF import libraryPage [format=Hardcover] p0 12.50 ms
  PERF import libraryCount [format=Paperback] 9.48 ms
  PERF import bookText [perfect storm] 14.82 ms
  PERF import nearestLabel Gloucester 0.04 ms
  PERF import save transaction: 3.12 ms (cold, single run, 4 statements)
  PERF import summary: 19 queries; slowest median 14.82 ms (import bookText [perfect storm])
  ```

  `EmbedderTests` prints the real MiniLM time per text on the Mac (`MINILM per-text median 2.23 ms, p90 3.16 ms (all)` and `3.84 ms, p90 4.20 ms (cpuOnly)`). Model load takes 66–93 ms with `.all` (warm Neural Engine cache) and 37–53 ms with `.cpuOnly`. `HeavyTestGate` stops the perf and Core ML suites from running at the same time. It asserts that each query's engine-reported `elapsedMs` (median of 5 warm runs) is under 50 ms, and prints one `PERF <query>: cold … median … max … rows …` line per query. To see only those lines: `swift test --filter PerfTests 2>&1 | grep PERF`.
- Always pass an **absolute** `-derivedDataPath`.
- **UI tests** (target `RelateBooksUITests`, 14 tests) drive the app on a simulator. Classes run in alphabetical order: AddBook, ChipNavigation, GraphFeatures, Map, Search, then UserData. `TEST_RUNNER_SCREENSHOT_DIR` saves each screen as a PNG, through the shared `saveScreenshot` helper in `UITests/Screenshots.swift`.
  - `AddBookUITests` (phase 5; 5 tests, run first). Every test launches with `--reset-user-data --stub-network`, so the add flow uses canned Open Library responses for The Perfect Storm (ISBN 9780393337013) and a stub geocoder: no test depends on openlibrary.org, Apple's geocoder or the camera. Covers still load from covers.openlibrary.org when the Mac has network; no assertion depends on them.
    - `testAlreadyInLibraryOpensExistingBook`: Scan mode shows `addBook.scanner.unavailable` on the simulator; typing 9780593135211 (the sample's Kindle edition) reads "Valid ISBN-13"; Look Up opens Project Hail Mary with "Already in your library" and its Amazon item (a local ISBN match, no request) (`phase5-already.png`).
    - `testManualEntry`: Manual mode, "Field Notes from the Bitterroot" by "Jane Doe, Rana Foroohar" → detail with "Added to your library", Added in app "… · entered manually" and both authors (`phase5-manual.png`); the Library search "bitterroot" lists it with "Added in app".
    - `testSearchResultImport`: "perfect storm" → `addBook.result.0` is The Perfect Storm (`phase5-add-search.png`) → "Add to Library" → detail whose Added in app line says "Open Library search" and shows no ISBN (D8); the Library lists it.
    - `testSimulatedScanAddsBook`: `--simulate-scan 9780393337013` feeds the payload through the Scan section's `onPayload` handler (the one the camera calls) → detail with "ISBN scan" and "ISBN 9780393337013"; the Library lists it. The same scan again, and the search row (badged "In your library"), both open the existing book with "Already in your library".
    - `testTypedISBNAddsBookToLibrarySearchAndMap` (the §8 acceptance flow): typed ISBN (`phase5-add-scan.png`, `phase5-importing.png`) → detail with "Added to your library" and "Added Nov 8, 2026 · ISBN scan, ISBN 9780393337013, W.W. Norton & Company · 2009" (`phase5-added-detail.png`; `PHASE5_IMPORT_SECONDS`, 4.3 s on 2026-11-12; 3.3–3.4 s on the original export) → the Library row with "Added in app" (`phase5-library.png`) → the Search tab's first row "Semantic 0.57 + keyword", i.e. keyword and, after the incremental embed, semantic (`phase5-search.png`; `PHASE5_SEARCH_REASON`) → the Map's place search "glouc" opens the new Gloucester pin, "1 book", The Perfect Storm (`phase5-map-gloucester.png`) → a relaunch with `--map-place Gloucester` shows the same sheet → a relaunch with `--reset-user-data` no longer finds the book, so later classes see the bundled six books.
  - `ChipNavigationUITests` opens The Left Hand of Darkness, taps the "science fiction" genre chip and the "Gethen" place chip, and checks that each term page opens. Since phase 4 the Gethen page must show `term.notOnMap` ("Not on the map: fictional or not a real place") and no Show on map button.
  - `MapUITests` (phase 4; writes no user data). Map content is checked through the on-screen `map.count` label, not through `MKMapView`'s accessibility children, which XCUITest exposes inconsistently (clusters hide most markers).
    - `testMapShowsPinsAndPlaceSheet`:
      1. `--open-tab map`: waits for `map.view` and for `map.count` to match `^[1-9][0-9]* places? in view$` (3 on the iPhone 17 with the sample), with no empty state (`phase4-map.png`). The Birthplaces toggle must raise the count (authors born in Waukegan, Davis, Berkeley and New York City).
      2. `--map-place "San Francisco"`: the sheet's `place.title` is "San Francisco", `place.bookCount` is "1 book", the section header is "Books set here (1)", and `place.book.0` exists (`phase4-place-san-francisco.png`). The core perf test asserts all 271 distinct rows on the scaled store; a lazy List cannot be counted from XCUITest.
      3. Tapping `place.book.0` pushes Book detail inside the sheet (a navigation bar titled with the row's book).
      4. Back, Done (`place.close`) closes the sheet; typing "sahara" in `map.search` lists results, and tapping `map.search.result.0` opens the Sahara sheet.
    - `testShowOnMapFromTermPage`: `--open-term "place=San Francisco"`, taps `term.showOnMap`, and lands on the map with the San Francisco sheet; then `--open-term place=Gethen` shows `term.notOnMap`.
  - `SearchUITests.testSemanticSearchIndexAndRelaunch` launches with `--reset-user-data --reset-embeddings --open-tab search --wait-for-index`, so the whole index is rebuilt and timed.
    1. It screenshots the banner if it catches indexing in progress (with six books it usually does not, so no `phase3-indexing.png` is kept).
    2. It waits up to 360 s for the `index.status` label to begin "Index complete.". It asserts under 300 s and "6 of 6 books embedded", and prints `PHASE3_INDEX_ELAPSED_SECONDS=…` (65.4 s on 2026-11-12, almost all of it app launch and model load; the six embeds took 0.5 s).
    3. It types "lonely astronaut saves earth" and asserts Project Hail Mary is in the first 3 rows (`phase3-search.png`).
    4. It opens the book and asserts at least 3 "More like this" cards (`phase3-more-like-this.png`).
    5. It relaunches without resets, waits up to 90 s, and asserts "0 embedded this launch" with no banner (`PHASE3_RELAUNCH_STATUS=…`).

    It writes no user data. The whole test takes about a minute with the sample (3–4 minutes on the 1,811-book export). For a literal fresh install, run `xcrun simctl uninstall <udid> com.johnymontana.RelateBooks` first.
  - `GraphFeaturesUITests` (2 tests). `testNearYourReadingSheet` launches with `--reset-user-data --open-tab map`, opens the sheet from `map.nearReading` and finds its explanation of the empty list (`graph-near-reading.png`); the sample has no two books set near each other, so the list itself is covered by the core tests. `testNextUpConnectionsAndSearchReasons` opens Next Up from the Library (`graph-next-up.png`: the two award winners), marks The Left Hand of Darkness read with 5 stars and sees it leave the list; relaunches on Red Mars and finds "Connected to your reading" naming the shared subject and the rating, which opens the rated book (`graph-connected.png`); then searches "left hand darkness" and finds a row with the same reason (`graph-search.png`). It leaves that status and rating behind; Search and UserData start with a reset.
  - `UserDataUITests.testLibrarySwipeSetsStatus` launches with `--reset-user-data`, searches for the book and swipes its row to Reading (`phase2-swipe.png`).
  - `UserDataUITests.testUserDataSurvivesRelaunch` launches with `--reset-user-data --open-book /works/OL59800W`. It sets Read, gives 4 stars, creates the tag "Favorites" and adds a note. It then relaunches **without** the reset flag and checks that all of it is still shown (`phase2-book-detail.png`). Finally it relaunches with `--open-tab tags`, finds "Favorites (1)" (`phase2-tags.png`), and filters the Library by that tag (`phase2-library-tag.png`).
  - Only The Left Hand of Darkness is touched, so after a run it is the only book with user data in the simulator's `library.rl`, and no app-added book is left (the typed-ISBN test ends with a reset).

  Run them (about 8 minutes with the sample: 14 tests in 470.0 s on 2026-11-17, Relate 1.1.0):

  ```sh
  TEST_RUNNER_SCREENSHOT_DIR=/abs/shots xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks \
    -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rb-dd test -only-testing:RelateBooksUITests
  ```

  If several runtimes have an "iPhone 17", use `-destination 'platform=iOS Simulator,id=<udid>'`. A rare "Application failed preflight checks (Busy)" launch error is a simulator hiccup; re-run.
- `scripts/refresh_store.sh [path]` copies `../books.rl` (or `path`) to `RelateBooks/Resources/books.rl` and prints the book count. The source file is never opened for writing.

## Version control


- The root `.gitignore` ignores `*.rl` but excepts `ios/RelateBooks/Resources/books.rl` (`!ios/RelateBooks/Resources/books.rl`), so the bundled sample is tracked and a fresh clone builds. It is 212,992 bytes. Never commit a personal export over it: a store records the wishlist id and URL.

## Bundled store

`RelateBooks/Resources/books.rl` is built from the public sample wishlist `https://www.amazon.com/hz/wishlist/ls/9N4X43GP6SVK` with relate 1.0.1:

```sh
relate run wishlist-to-graph https://www.amazon.com/hz/wishlist/ls/9N4X43GP6SVK --wikidata --geocode -d ./books.rl
scripts/refresh_store.sh ../books.rl
```

It holds 6 books (Getting Things Done, Red Mars, The Curious Incident of the Dog in the Night-Time, A Truck Full of Money, Project Hail Mary, The Left Hand of Darkness), 8 authors (Open Library lists three "David Allen" records on Getting Things Done), 173 subjects, 58 awards, 3 genres, 1 series, 34 places (19 located; fictional ones such as Gethen are skipped), sha256 `b798db09…5aee3c`. The import took about 30 s. Functional and UI tests name its books, places and terms, and the perf suites scale it (see Build). A different export works in the app as-is, but those tests are written for this sample.
- `ios/.gitignore` ignores SwiftPM output (`.build/`, `.swiftpm/`) and per-user Xcode state (`xcuserdata/`).
- `RelateBooks.xcodeproj` is committed so the project opens without xcodegen. Regenerate it with `xcodegen generate` after adding or removing files, and commit the result together with `project.yml`.

## Run on a simulator

Several runtimes each have an "iPhone 17", so pick one by UDID:

```sh
xcrun simctl list devices available | grep "iPhone 17 ("
U=<udid>
xcrun simctl boot $U && xcrun simctl bootstatus $U -b        # skip if already Booted
APP=/tmp/rb-dd/Build/Products/Debug-iphonesimulator/RelateBooks.app
xcrun simctl uninstall $U com.johnymontana.RelateBooks         # optional: test the first-launch copy
xcrun simctl install $U "$APP"
xcrun simctl launch --console-pty --terminate-running-process $U com.johnymontana.RelateBooks
#   -> RelateBooks: opened store with 6 books
xcrun simctl launch --terminate-running-process $U com.johnymontana.RelateBooks --open-book /works/OL17876078W
xcrun simctl io $U screenshot /tmp/relatebooks.png
xcrun simctl spawn $U log show --last 5m --style compact \
  --predicate 'subsystem == "com.johnymontana.RelateBooks"'   # same line via os_log
xcrun simctl shutdown $U
```

### Launch arguments

The app pushes screens on launch, for testing and screenshots. Arguments go after the bundle id in `simctl launch`, or in the scheme's "Arguments Passed On Launch":

| Argument | Pushes |
| --- | --- |
| `--open-book <key>` | Book detail, e.g. `--open-book /works/OL59800W` (The Left Hand of Darkness) or `--open-book amazon:B0GNZ8ZYPG` |
| `--open-author <key>` | Author page, e.g. `--open-author /authors/OL31353A` (Ursula K. Le Guin) |
| `--open-term <kind>=<name>` | Term page. `kind` is one of subject, genre, series, place, person, era, publisher, award, country. Example: `--open-term "series=Hainish Cycle"` |
| `--open-next-up` | The Next Up screen. |
| `--open-tab <library\|tags\|search\|map>` | Selects the first tab (no push). Example: `--open-tab search`, `--open-tab map` |
| `--map-place "<label or heading>"` | Phase 4. Selects Map (unless `--open-tab` chose another tab; it wins over `--search`), then flies to that place and opens its sheet, once, on first appear. Matches a `geocoded_label` or a heading, case-insensitively: `--map-place Montana`, `--map-place USA` (→ United States), `--map-place "Los Angeles (Calif.)"` (→ Los Angeles). A place with no pin shows the banner "“Gethen” is not on the map". |
| `--search "<text>"` | Selects Search (unless `--open-tab` chose another tab), prefills the field and runs the query. Like any query, it runs again when indexing completes. |
| `--wait-for-index` | Shows the always-on status line (`index.status`) at the bottom of Search. Its label begins "Index complete." once every book is embedded, e.g. "Index complete. 1811 of 1811 books embedded. 1811 embedded this launch in 163.3 seconds." While indexing it reads "Indexing 412 of 1811 books." Used by the UI tests. |
| `--reset-embeddings` | **DEBUG builds only.** Before the UI loads, removes `embedding`, `embedding_model` and `embedding_text_hash` from every Book and Note, then checkpoints, so the next index is a full rebuild. |
| `--reset-user-data` | **DEBUG builds only** (parsed but ignored in Release). Before any screen loads, it deletes every Tag and Note node, every book added in the app (`source: 'app'`) and every Author, Subject, Place, Person, Era and Genre node an import created (`added_on` set), and removes `reading_status`, `my_rating`, `started_on`, `finished_on` and `status_changed_on` from every Book, in one transaction, then checkpoints. Used by the UI tests. |
| `--stub-network` | **DEBUG builds only** (phase 5). Swaps the Open Library transport for canned responses for The Perfect Storm (ISBN 9780393337013, work `/works/OL2670211W`; any other search returns no matches) and the geocoder for a stub with fixed coordinates for its new places. Covers still load from the network. Used by `AddBookUITests`. |
| `--simulate-scan <isbn>` | **DEBUG builds only, and only together with `--stub-network`** (phase 5). Feeds that barcode payload once to the Scan section's payload handler when the Scan segment appears, as if the camera had read it. Each new Add Book screen hands it out once. |

You can pass several; the routes are pushed in order on top of the Library, whichever tab is selected. Unknown arguments are ignored. `LaunchOptions.parse` in `RelateBooks/Navigation/Route.swift` handles them.

### Screenshots

All screenshots in `docs/` are written by the UI tests (`TEST_RUNNER_SCREENSHOT_DIR`, see Build) on the bundled six-book sample. They were regenerated on 2026-11-15 (iPhone 17, iOS 26.4, Relate `main` at `af8c2e4`, fresh install; not regenerated for 1.1.0, which changes nothing on screen), so they show the Library's Next Up button and the Map's near-your-reading button. The earlier hand-taken phase 0/1 screens and the phase 5 live-network check showed the original export and were removed; their descriptions remain in the plan's changelog.

- Graph features (`GraphFeaturesUITests`):
  - [`graph-next-up.png`](docs/graph-next-up.png): Next Up on the untouched sample, with the two award winners.
  - [`graph-connected.png`](docs/graph-connected.png): Red Mars, "Connected to your reading", after The Left Hand of Darkness was rated 5.
  - [`graph-search.png`](docs/graph-search.png): "left hand darkness". Red Mars is second: the vectors put it last (cosine 0.08), the graph lifts it, and the row says what it shares with the rated book.
  - [`graph-near-reading.png`](docs/graph-near-reading.png): the Map's Near Your Reading sheet with nothing read yet.
- Phase 1 (`ChipNavigationUITests`): [`phase1-chip-genre.png`](docs/phase1-chip-genre.png), the "science fiction" genre page opened from The Left Hand of Darkness (Project Hail Mary and The Left Hand of Darkness), and [`phase1-chip-place.png`](docs/phase1-chip-place.png), the Gethen place page with "Not on the map: fictional or not a real place".
- Phase 2 (`UserDataUITests`):
  - [`phase2-book-detail.png`](docs/phase2-book-detail.png): The Left Hand of Darkness after a relaunch, with Read, the finished date, 4 stars, the Favorites tag chip and the note.
  - [`phase2-tags.png`](docs/phase2-tags.png): the Tags tab with Favorites and count 1.
  - [`phase2-library-tag.png`](docs/phase2-library-tag.png): the Library filtered by the Favorites tag.
  - [`phase2-swipe.png`](docs/phase2-swipe.png): a Library row after the leading swipe set Reading.
- Phase 3 (`SearchUITests`):
  - [`phase3-search.png`](docs/phase3-search.png): "lonely astronaut saves earth" after the full index: 6 results, Project Hail Mary first (Semantic 0.59), then Red Mars (0.23), The Curious Incident (0.20) and A Truck Full of Money (0.16). The status line reads "Index complete. 6 of 6 books embedded. 6 embedded this launch in 0.5 seconds."
  - [`phase3-more-like-this.png`](docs/phase3-more-like-this.png): Project Hail Mary's detail with the "More like this" strip (the other five books).
  - There is no indexing-banner screenshot any more: six books embed in about half a second, before the banner can be captured.
- Phase 4 (`MapUITests`):
  - [`phase4-map.png`](docs/phase4-map.png): the Map tab on first open (`--open-tab map`), centred on the continental US: "3 places in view" (San Francisco, Pasadena, United States).
  - [`phase4-place-san-francisco.png`](docs/phase4-place-san-francisco.png): `--map-place "San Francisco"`. The sheet shows PLACE / San Francisco / 1 book / "Also filed as: San Francisco · San Francisco (Calif.)" / "Books set here (1)" / Project Hail Mary, with the Pasadena pin below.
- Phase 5 (`AddBookUITests`, `--stub-network`):
  - [`phase5-add-search.png`](docs/phase5-add-search.png): Add Book, Search mode, "perfect storm", from the canned Open Library response.
  - [`phase5-add-scan.png`](docs/phase5-add-scan.png): Scan mode on the simulator: "Camera scanning unavailable", the typed ISBN 9780393337013, "Valid ISBN-13" and Look Up.
  - [`phase5-importing.png`](docs/phase5-importing.png): the progress card.
  - [`phase5-added-detail.png`](docs/phase5-added-detail.png): The Perfect Storm's detail: "Added to your library" and the Added in app section "ISBN scan / ISBN 9780393337013 / W.W. Norton & Company · 2009".
  - [`phase5-library.png`](docs/phase5-library.png): the Library search "perfect storm": "1 book of 7", the row with "Added in app" where the price would be.
  - [`phase5-search.png`](docs/phase5-search.png): the Search tab, "perfect storm": The Perfect Storm first with "Semantic 0.57 + keyword".
  - [`phase5-map-gloucester.png`](docs/phase5-map-gloucester.png): the new Gloucester pin and its sheet "Gloucester / 1 book / The Perfect Storm".
  - [`phase5-manual.png`](docs/phase5-manual.png): the manual book's detail ("Added manually").
  - [`phase5-already.png`](docs/phase5-already.png): Project Hail Mary with "Already in your library".

## Map data

- **Source.** The extension's `--geocode` run (see `../wishlist-to-graph/README.md`) geocodes `Place` headings once, on the Mac, with Nominatim and a manual table of region centroids, and writes `location` (a WGS-84 `point`), `geocoded_label`, `geo_source` (nominatim | manual), `geo_status` (ok | unresolved | skipped) and the other `geo_*` properties. The bundled store came from that run: 693 places, 600 located (550 Nominatim, 50 manual centroids), 81 skipped (fictional, non-terrestrial or not a place), 12 unresolved, 482 distinct labels. Of the 91 places with at least 2 books, 83 are located (91.2 %). The app never geocodes in phase 4 (no network, no location permission). Since phase 5 it geocodes only the places an import creates (see "Add books").
- **One pin per label.** `geocoded_label` is the place a heading resolved to. Many headings share one (United States, USA, États-Unis, United States of America), and every node of a label carries the same point. The region query groups by label and counts **distinct** books and authors across all of its nodes (summing per heading would double-count: United States would gain 13). The sheet lists the headings behind the pin ("Also filed as: …"). Montana is only the heading `Montana` (29 books); `(Mont.)` headings and the Blackfeet reservation are their own nearby pins.
- **Region query.** The map reports each settled region; `MapModel` fetches the visible box padded by 50 % on each side (debounced 300 ms) with `point.withinBBox` on the `place_location` POINT INDEX, so panning and zooming in inside that box never re-query. A box that crosses the antimeridian is split in two and the results merged by label. Relate 0.16.1's `withinBBox` did not wrap the antimeridian. 1.0.1 does: a west > east box matches the wrapped band, with or without the POINT index. The split stays anyway, because it is cheap and does not depend on the engine version. World: 482 pins in about 11 ms; US 269 in about 5.5 ms; Montana 18 in 0.4 ms.
- **Indexes.** `POINT INDEX place_location` and the range index `place_label` on `Place(geocoded_label)` (search and sheet queries). Both are in `Schema.ddl` (idempotent; `schema_version` stays 2) and already in the bundled store.
- **Pins.** Colour and priority by book count (`PinTier`): birthplace-only purple (person glyph), 1 book teal (book glyph), 2–4 blue, 5–14 orange, 15+ red (count glyph); bigger tiers have higher display and z priority. Book pins cluster as "places", birthplace pins as "birthplaces", so book clusters never count authors. Tapping a cluster zooms to its members. The selected place leaves its cluster so it can be highlighted.
- **Not on the map.** Headings with `geo_status = 'skipped'` (Gethen, Mars, Earth, Moon, …) say "Not on the map: fictional or not a real place" on their term page; unresolved or never-tried ones say "Not on the map: location unknown".
- **Near me** is not shipped: the core statement (`PlaceQueries.nearMe`, `GraphStore.placesNear`) and its test exist, but there is no UI and no location permission.
- **Refreshing.** `scripts/refresh_store.sh` is unchanged (it copies `../books.rl`); the store it copies must come from a `--geocode` run, or PerfTests' guard fails with "bundled books.rl has no geocoded places". Geocoding did not change the store's size (7,315,456 bytes), so compare checksums, not sizes. An installed app keeps its `library.rl`: delete the app to pick up a new bundled store.

## Add books

Phase 5. Code: `RelateBooks/OpenLibrary/` (client, models, ISBN, draft, importer, DEBUG stub), `RelateBooks/Geo/` (heading normaliser, geocoder protocol, CLGeocoder, locator, DEBUG stub), `Graph/Queries/ImportQueries.swift`, `ViewModels/AddBookModel.swift` (the state machine, tested in core) and the UI in `Features/AddBook/` (`AddBookView`, `ISBNScannerView`).

- **Entry points.** The Library's **+** (`library.add`) pushes Add Book on the Library stack. When the flow ends, the screen replaces itself with the book's detail (`Route.addedBook`), so Back returns to the Library list.
  - **Search**: Open Library `search.json` as you type, debounced 400 ms, from 3 characters; a newer query cancels the one in flight. Rows show cover, title, authors and first year; non-work keys are dropped. A work already in the store is badged "In your library" and opens without a confirmation or any request; any other row asks "Add “…”?" → **Add to Library**.
  - **Scan**: VisionKit `DataScannerViewController` (EAN-13, EAN-8, UPC-E) when `isSupported && isAvailable`, scanning only while the screen is idle and stopping after the first ISBN; a `startScanning()` that throws (e.g. before the view is in a window) is retried up to 4 times, 0.4 s apart. The simulator and a device without the hardware show "Camera scanning unavailable". On a supported device the camera permission decides: not asked yet → "Allow Camera" (asks, then shows the scanner); denied or restricted → "Camera access is off" with an **Open Settings** button (re-checked when the app becomes active). The typed field is always there: it validates the check digit ("Valid ISBN-13", "Valid ISBN-10 (978…)", "Check digit doesn't match", "ISBN has 10 or 13 digits") and converts ISBN-10 to 13. `NSCameraUsageDescription`: "Scan a book's barcode to add it to your library."
  - **Manual**: a title (1–300 characters) and comma-separated authors (up to 8); key `manual:<uuid>`, authors `name:<slug>` like the extension's byline authors, so "Rana Foroohar" links to the existing `name:rana-foroohar`. No lookup.
- **Network policy.** Open Library only, anonymous: User-Agent `RelateBooks/<CFBundleShortVersionString> (+https://github.com/johnymontana/relate-book)`, no contact string. One request in flight per client, each start at least **1.05 s** after the previous one (the extension's anonymous interval). 429/503 is retried once when `Retry-After` is absent or at most 5 s; a longer `Retry-After` fails the call ("Open Library asked us to slow down; try again in N s.") and pauses every later request for that long. 15 s idle timeout and a 30 s overall (resource) timeout per request, so a server that trickles bytes cannot keep "Looking up…" spinning. Ephemeral `URLSession`: responses are not cached and no cookies are kept. The network is used only by the add flow and for cover images; everything else stays offline.
- **Lookup chain (ISBN).** The store first (Item.isbn13 / Item.isbn10 / Book.isbn13; a hit is "Already in your library" with no request), then `q=isbn:<13>`, then `q=isbn:<10>`, then `GET /isbn/<13>.json` → `works[0]` → `q=key:"…"`. A doc whose work key is already a Book is "already in library" without fetching the work. Otherwise the work and the **missing** authors are fetched (existing authors are never fetched or modified): The Perfect Storm takes 3 requests. Any transport error fails the import before anything is written.
- **What is written.** One transaction of MERGE statements (never a DELETE; no Item, Edition, Publisher or Series node). The Book gets the extension's Open Library properties (`title`, `subtitle`, `description`, `first_sentence`, `first_publish_year`, `cover_url`, `ol_rating` and the OL counts, `pages_median`, `edition_count`, `languages`, `url`, …) plus `source: 'app'`, `added_on` and `match` (`isbn` | `search` | `manual`). Only the ISBN flow writes edition facts (`isbn13`, `isbn10`, `publisher`, `publish_date`, `publish_year`, `pages`, `physical_format`, `ol_edition_key`); a search import picked a work, not an edition (D8). Subjects, places, people, eras and genres use the extension's lists, dedupe rules and label/relationship pairs. Every node the import creates (Book, Author, Subject, Place, Person, Era, Genre) gets `added_on`; that is what the DEBUG reset removes, and what a future delete would use. An existing Book is never overwritten: the flow opens it with "Already in your library". There is no delete in this phase.
- **New places.** Only places the import creates are geocoded, at most 10 per import, one at a time through the session's single `PlaceLocator` (serial across imports, 10 s per request, one fallback query). Headings are normalised with a minimal port of the extension's `normalize_heading` ("Gloucester (Mass.)" → "Gloucester, Massachusetts") and its `skip_reason` denylist (fictional or non-terrestrial → `geo_status: 'skipped'`); the extension's synonym table is not ported. A candidate is accepted when one of its fields covers the heading's significant tokens. US and Canadian state abbreviations from CLGeocoder ("MA") are spelled out first ("Massachusetts"), as the bundled store's `geo_region` and suffixes are. **Label rule** (the extension's `assign_labels`, labels compared by `fold`, so case and accents are ignored): reuse the label (and point) of a located Place within 1 km; else take the placemark's locality, administrative area or country that equals the base name, else the base name, and if a located Place already carries that label (or its ", <qualifier/region>" form) within 50 km, reuse that label and point; when the place is itself a country or first-level division, that radius is 3,000 km or 1,000 km, because Apple's and Nominatim's centres for one region lie far apart (so "California (U.S.)" or "new england" joins the existing pin). Only a same-named place genuinely elsewhere gets ", <qualifier or region>" appended, then " (lat, lon)". Written: `location`, `geocoded_label`, `geo_source` (`clgeocoder`, or `stub` under `--stub-network`), `geo_status`, `geo_lat`, `geo_lon`, `geo_display_name`, `geo_place_type`, `geo_query`, `geo_region`; failures leave `geo_status: 'unresolved'` with `geo_reason` and never fail the import. The progress screen waits for geocoding at most 20 s, then moves on while it finishes in the background. CLGeocoder is deprecated in the iOS 26 SDK (no warning at the iOS 18 deployment target); `MKGeocodingRequest` is a phase 6 candidate. CLGeocoder needs no permission.
- **Incremental embed.** After the save, `IndexingModel.embedBook(key:)` embeds just that book on the same serial chain as note embeds (the screen waits at most 15 s, "Indexing…"), so semantic search finds it within seconds; keyword search works at once because `book_text` is a fulltext index. Book detail's "More like this" fills in when the vector lands.
- **Change propagation.** `UserDataChange.bookAdded(key:)` makes the Library reload (rows, total, format facets), Search re-run an active query (and again when the book's vector lands: `IndexingModel.onBookEmbedded` → `SearchModel.bookDidEmbed`, so the semantic hit appears even when the add screen stopped waiting for the embed), and the Map reload once it has loaded; `.placesLocated(labels:)` reloads the Map when background geocoding finishes. Lists, detail, search, term and place pages all tolerate a book without an `Item`: the row shows "Added in app" where the price would be, and the format comes from `Book.physical_format`. App books sort last in wishlist order.
- **One import at a time.** Look Up, Add to Library, a scan and Save set the first step ("Checking your library…", or "Saving…" for a manual entry) before they return, so a double tap in the same moment is refused instead of starting a second run.
- **Leaving.** Leaving the screen (Back, or switching tabs) while it is "Checking your library…" or "Looking up…" cancels the lookup; nothing has been written and the inputs are kept. Once "Saving…" starts, the pipeline runs to the end in the background.
- **Stub mode for tests.** `--stub-network` (DEBUG) serves the recorded responses for The Perfect Storm from `StubOpenLibraryFixtures` (the same JSON as `Tests/RelateBooksCoreTests/Fixtures/OpenLibrary/`, checked by a core test) with 150 ms latency and the real 1.05 s gate, plus a stub geocoder for Gloucester, Massachusetts and North Atlantic Ocean. `--simulate-scan <isbn>` exercises the camera's payload handler. On the simulator the stubbed ISBN flow takes about 3.4 s from Look Up to the detail.
- **Logging.** Each Open Library request logs `Open Library request <n>: <path>` (path only, never the query text) and each place `geocode <heading> (<source>): <outcome>` (subsystem `com.johnymontana.RelateBooks`, category `store`, notice level).
- **Live check** (2026-11-08, Debug build on the iPhone 17 simulator, real Open Library and CLGeocoder, no stub flags). *The Old Man and the Sea* (ISBN 9780684801223): Look Up → detail in **4.0 s** with **3 requests** (`q=isbn:`, the work, Hemingway's author record; about 1.08 s apart); a Search-mode query "old man and the sea" took 1 more request, first results 1.7 s after typing began, the work badged "In your library". It created 4 places, geocoded serially in 0.6 s: **Cuba** → a new correct pin (label Cuba, 21.33, −77.82); **Gulf Stream** → the town of Gulf Stream, Florida, not the ocean current; **Straits of Florida** → a point in Miami; **Swahili** → unresolved ("no matching result"). CLGeocoder prefers a same-named locality for water bodies; that is a phase 6 item. The book was embedded, and a `--reset-user-data` relaunch removed it again.
- **Phase 6 candidates.** Delete a book (and its orphans, found by `added_on`); retry `unresolved` or untried app places; a contact string in the User-Agent from Settings; fetching the edition record for pages and format (search editions never carry them); porting the synonym table; `MKGeocodingRequest`; a "Recently added" sort; keeping the Library's **+** reachable while its search field is active (the active `.searchable` field hides the toolbar button and its keyboard covers the tab bar; the UI tests tap the search field's Close first). Live camera scanning, and the camera-permission cards, have not been run on a device.

## Embedding model

- **Source.** [sentence-transformers/all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) at commit `1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, under the Apache-2.0 licence (weights and `vocab.txt`). Only the safetensors weights, JSON configs and vocab are downloaded: no pickles and no remote code.
- **Conversion.** Python 3.12.12 with torch 2.7.0, coremltools 9.0, transformers 4.56.2, sentence-transformers 5.1.1 and numpy 2.2.6. The full transitive set is pinned in `scripts/requirements-embedding.txt`.
  - The output is an ML Program, fp16 compute and weights, minimum iOS 17 / macOS 14, compiled with `xcrun coremlcompiler`.
  - Inputs: `input_ids` and `attention_mask`, int32 [1, 256]. The sequence length is fixed at 256.
  - Output: `embedding`, float32 [1, 384]. Mean pooling over the mask and L2 normalization are **in the graph**.
  - The attention mask is additive `(1 - mask) * -1e4`. BertModel's own mask uses `finfo(float32).min`, which becomes -inf in fp16 and gave NaN on the CPU and GPU compute units, including the simulator.
  - The script checks the compiled model on all four compute units against sentence-transformers. The minimum cosine is 0.99997.
- **Sizes.** `MiniLM_L6_v2.mlmodelc` is 45,228,025 bytes and `vocab.txt` is 231,508 bytes. Hashes, the interface and the tokenizer rules are in [`RelateBooks/Embedding/Model/MODEL.md`](RelateBooks/Embedding/Model/MODEL.md).
- **Regenerate** the model and the test fixtures with this command, run from the repository root (macOS on Apple silicon, [uv](https://docs.astral.sh/uv/)):

  ```sh
  uv run --python 3.12 --with-requirements ios/scripts/requirements-embedding.txt python -I ios/scripts/convert_embedding_model.py
  ```

  It writes the model, the vocab and MODEL.md to `ios/RelateBooks/Embedding/Model`. It also writes `tokenizer_fixtures.json` (50 cases) and `embedding_fixtures.json` (20 sentence-transformers references) to `ios/Tests/RelateBooksCoreTests/Fixtures`. `--cache` sets the Hugging Face download directory (default `$RELATE_BOOK_SCRATCH/hf`, else `$TMPDIR/relate-book-embedding/hf`). `--work` sets where the `.mlpackage` is built. `--fixtures-only` skips the conversion and rewrites just the two fixture files (the full run writes the same files). `weights/weight.bin` and `model.mil` are byte-for-byte reproducible. Some metadata files carry per-run ids.

## Embedding pipeline

- **Text per book (D12).** The parts are joined with " · " in this order:
  1. the title;
  2. the authors (deduped, sorted);
  3. up to 15 subjects, with `nyt:` and `collection:` tags, call numbers and a short stoplist of catalogue headings dropped, then deduped and sorted alphabetically;
  4. the first 800 Unicode scalars of the description.

  Empty parts are dropped, so a book without a description is title · authors · subjects. The Swift `WordPieceTokenizer` (BERT uncased) truncates to 256 tokens and matches Python's `BertTokenizer` on all 50 fixtures. Like transformers, it cuts the five special-token literals (`[SEP]` etc.) out of the raw text wherever they occur, even inside a word, and lowercases one character at a time, so a word-final capital Σ becomes σ, never ς (fixtures `special_tokens_inline` and `greek_uppercase_sigma`).
- **Hash.** `embedding_text_hash` is the lowercase hex SHA-256 of `"<model id>\n<text>"`, and `embedding_model` is `all-MiniLM-L6-v2-coreml-fp16-256`. A book is stale when its vector is missing or either value differs, so a changed description or a new model re-embeds only what changed.
- **Indexer.** `EmbeddingIndexer` is an actor, driven by the `@MainActor` `IndexingModel`. It starts when the session is ready, as a utility-priority task.
  1. It scans 200 books per page, plus all notes, without loading the model. If nothing is stale, the pass is complete and the model is never loaded. A relaunch takes about 1 s.
  2. Otherwise it embeds stale notes first, then stale books in batches of 32. Each batch is one `UNWIND $rows AS row MATCH (b:Book {key: row.key}) SET b.embedding = row.vector, b.embedding_model = $model, b.embedding_text_hash = row.hash` statement, so it commits whole or not at all.
  3. It publishes progress after each batch and checkpoints once at the end.

  Progress lives in the store, so a killed or paused pass resumes on the next launch. The app pauses indexing when it goes to the background and on a memory warning. It resumes on `.active`, when the Search tab appears, and by itself 10 s after a memory warning (unless the app went to the background meanwhile). A query run while indexing is still going is run again once indexing completes, so partial semantic results are replaced. A new or edited note is embedded within about a second, through a `UserDataController` subscription. The indexer writes only the three embedding properties and never removes anything.
- **Storage.** Vectors are typed `VECTOR<FLOAT32>(384)`, passed as `.vector(.floats(dtype: .float32, …))`. Swift rejects non-finite values and wrong dimensions before writing, because Relate silently skips a stored vector of the wrong size.
- **Store growth.** On the original 1,811-book export, a full index grew `library.rl` from 7.3 MB to about 46–48 MB (45.8 MB on the simulator), mostly WAL and checkpoint overhead. A clone of the same data is 16 MB. Compaction moves to phase 6.
- **On the simulator.** In the phase 3 UI run on the original export (iPhone 17, iOS 26.2, fresh install, with the Mac under load average about 14), a full index of 1,811 books took 161.2 s by the app's own clock. That was 164.7 s from launch, as measured by the test. The re-run after the review fixes took 159.5 s by the app (162.4 s from launch). The model loads in about 130–230 ms on the simulator. A relaunch finds nothing stale in 0.2 s.

## Search pipeline

`SearchService.search` builds four candidate lists (the fourth, the graph neighbours of the top hits, is described under [Graph features](#graph-features)):

1. **Vector.** The query is embedded on device, then top-50 on `book_embedding`.
2. **Keyword.** `book_text` top-50 plus `item_text` top-50 (item title and byline), mapped to Book. A book stays in the list only if it contains **every** sanitized query term (the keyword gate).
3. **Notes.** Top-20 on `note_embedding`, mapped to the owning Book, keeping notes with cosine ≥ 0.30.

4. **Related.** Up to 10 graph neighbours of the top 5 hits of the first three lists, ranked from position 6.

The lists are fused with reciprocal rank fusion: k = 60, equal weights, with ties going to a keyword title or author match. The result's reason is note if a note matched, else "both", else semantic or keyword, and "related" only when the graph is the sole source. The status and tag filters are applied after fusion, in the hydrate query, which also joins authors and the cover. Up to 50 results.

- Relate's SEARCH score for cosine is `(1 + cos) / 2`. Swift reports `cos = 2·score − 1`, so "Semantic 0.59" is a cosine.
- **Why the gate.** Relate 0.16.1 fulltext ORs the lowercase terms and scores by raw term frequency. Without the gate, plain RRF put five "Earth" titles ahead of Project Hail Mary for the acceptance query.
- **Fulltext facts (0.16.1; re-checked on 1.0.1 and 1.1.0).** There is no stemming and no accent folding. In 0.16.1 there was no operator syntax: AND, OR and NOT were ordinary words. In 1.0.1 the **upper-case** `AND`, `OR` and `NOT` are operators: `hail AND mary` matches 1 book where `hail mary` matches 4. Lower-case `and`/`or`/`not` are still words. `KeywordQuery` lower-cases its terms and drops and/or/not as stopwords, so the app never sends an operator; `SearchTests.hostileStrings` pins both behaviours. Quotes, colons, parentheses, `+`, `-` and so on are still separators. In 1.0.1 `*` was one too; in 1.1.0 a `*` inside a raw term is a wildcard (`caf*` matches cafe and café) and a trailing `~` makes a term fuzzy (`hale~` matches hail). Neither reaches the engine from the app. Every input is accepted, and an empty string returns 0 rows. A query costs about 16 ms (`book_text`) or 12 ms (`item_text`) whatever the query (1.0.1, CLI on a store copy: 17.5–18.2 ms for `book_text`). A pattern comprehension directly after a fulltext SEARCH costs about 4 ms per row, so the queries use `WITH … OPTIONAL MATCH … collect` instead. Since 1.0.1 (seen on `main` at `af8c2e4`, still so in 1.1.0) one raw input is refused: a query string that ends in a backslash is a syntax error ("a trailing `\` escapes nothing"). `KeywordQuery` only ever sends letters, digits and spaces, so the app is unaffected; `SearchTests.hostileStrings` pins the refusal.
- **Sanitizer** (`KeywordQuery`). It lowercases, takes runs of letters and digits, and drops 1-character tokens and stopwords (including and/or/not and book/books). It dedupes and keeps at most 8 terms. With no terms left, both fulltext queries are skipped. It exists for ranking and the gate, not for safety.
- **More like this** is one statement that uses the book's stored vector as the `FOR` expression (`MATCH (s:Book {key:$key}) WITH s, s.embedding AS q MATCH (b:Book) SEARCH b IN (VECTOR INDEX book_embedding FOR q LIMIT $probe) SCORE AS score WHERE b <> s …`). It returns the top 10 and excludes the seed. A book that is not embedded yet gives an empty list, and the section says "Similar books appear once indexing finishes".
- **While indexing**, search uses whatever is embedded plus the keyword list, and the results header says "Semantic results cover 412 of 1,811 books so far".
- **Without a model** (missing resource or load failure), search is keyword only and the tab says so.

## Graph features

All four are multi-hop reads over the same graph the lists use; the statements are in `Graph/Queries/ConnectionQueries.swift` and `NextUpQueries.swift`, and run as managed reads.

**Connections.** Two books are connected when they point at the same node with the same relationship: `(book)-[rel]->(shared)<-[rel]-(other)`. `ConnectionKind` lists the seven kinds and how much each counts before rarity: series 4, author 3, award 2, person 1.5, place and subject 1, era 0.5. Genres are left out (a handful of nodes on most of the list).

- **Rarity.** A link weighs `strength / degree`, the degree being the number of books on the shared node. A node on more than 50 books links nothing and is never expanded. A subject, place, person or era on more than a third of the library links nothing either, unless it is on exactly two books; series, authors and awards are exempt. On the full 1,811-book list the absolute cap is the one that bites (16 subjects and one place are above it, "Fiction" at 303 books); on the six-book sample the relative one is.
- **Noise.** Subjects that are machine tags (`nyt:…`, `award:…=…`) or catalogue bookkeeping (`ConnectionQueries.noiseSubjects`: the embedding text's stoplist plus headings such as "Romans, nouvelles" and "Fiction, general") never link.
- **Cost.** The degree is counted once per shared node, not once per book that uses it. The perf suite's scaled store, where every subject is on 300 to 1,200 books, is the worst case for that count.

**Graph-expanded search.** After the semantic, keyword and note lists are fused, the top 5 hits that are confident (a keyword or note hit, or a vector hit with cosine ≥ 0.35) are seeds. `ConnectionQueries.related` returns their neighbours with summed link weights; a link from the n-th seed counts `1/n`, seeds themselves are not returned, and neighbours lighter than 0.05 are dropped. Up to 10 neighbours join the fusion as a fourth list whose ranks start at 6, so a book found only through the graph never outranks the hits it was reached from, and one that the vectors also found is lifted. Every knob is in `SearchTuning` (`relatedSeeds: 0` turns it off).

**Reasons.** `ConnectionQueries.reading` finds, for a list of books, each one's strongest link to a book that is read, being read, or rated 4 or more; a rating scales the link by up to two (a 5 doubles it). Links lighter than 0.1 are not reasons, which in practice means a subject shared by at most ten books, or twenty when the other book is rated 5. Two books that share several nodes are one reason, named by the strongest. Search attaches one reason per row; Book detail shows up to three, each to a different book. `ConnectionQueries.between` explains the "More like this" cards relative to the book on screen. On a temporary copy of the full list with 151 books marked read and 38 of them rated, 106 of 200 unread books had a reason (90 by subject, 11 by author, 5 by place).

**Next Up** (`GraphStore.nextUp`, three statements and the book rows in one snapshot):

- **Continue a series.** Series with at least one read book and an unread one; the unread book with the lowest position is "next" (positions are strings such as "4" or "1.5"; one that is not a number sorts last). A book you are reading is not suggested.
- **More by an author.** Authors of a book you rated 4 or 5, with their unread, unrated books (three shown, by title).
- **Award winners you haven't read.** Books that won an award which one of your 4- or 5-star books also won come first, then the most awarded.

The screen reloads when you come back to it after a status or rating changed.

**Near your reading** (`GraphStore.placesNearReading`). From each place a read book is set in, the located places within 250 km (that place itself included, at 0 km) that have unread books, nearest first, one row per map label. A place heading on more than 25 books is neither an origin nor a destination: "United States" is on 173 books of the full list and its point is the middle of the country.

**What the six-book sample shows.** It has one series with one book and no two authors in common, so Next Up shows only the award winners, graph expansion finds one pair (Red Mars and The Left Hand of Darkness share "American Science fiction"), and Near your reading stays empty. The core tests use small fixtures that have every kind of link.

## Open in Xcode

From `ios/`:

```sh
open RelateBooks.xcodeproj
```

Xcode resolves Relate 1.1.0 from GitHub on first open. No environment variable is needed.

## Layout

```
ios/
  project.yml                 xcodegen spec -> RelateBooks.xcodeproj (generated; regenerate after adding files)
  Package.swift               SwiftPM: RelateBooksCore library + RelateBooksCoreTests (Swift Testing)
  scripts/refresh_store.sh    re-copies ../books.rl into Resources
  scripts/convert_embedding_model.py + requirements-embedding.txt
                              reproducible MiniLM -> Core ML conversion and test fixtures (run with uv)
  RelateBooks/
    App/                      SwiftUI app (RelateBooksApp, AppEnvironment, ContentView + MainTabs, LibraryRoot, TagsRoot)
    Features/                 SwiftUI screens, UI only (excluded from SwiftPM):
                                Library/ (LibraryView, FilterBar), Authors/, Terms/ (TermBooksView),
                                BookDetail/ (BookDetailView, StatusControl, RatingControl, TagSection + TagPickerSheet,
                                             NotesSection + NoteEditorSheet),
                                Tags/ (TagsView, TagBooksView),
                                Search/ (SearchView, SearchResultRow, IndexingBanner),
                                Map/ (MapScreen, PlaceMapView + PlaceAnnotation/PlaceMarkerView/PlaceClusterView,
                                      PlaceSheet, PinTier+Color, ShowOnMapAction),
                                BookDetail/MoreLikeThisSection, NextUp/NextUpView, Map/NearReadingSheet,
                                AddBook/ (AddBookView + search/scan/manual sections, ImportProgressView, ISBNScannerView),
                                Shared/ (BookRow, CoverImage, StatusBadge, FlowLayout + RouteChip, RouteDestination,
                                         TagChip + TagColor.color, StatusSwipeActions, ReplaceRouteAction)
    Embedding/                WordPieceTokenizer, TextEmbedder, MiniLMEmbedder (Core ML actor), BookEmbeddingText,
                              EmbeddingIndexer, EmbeddingResources (Bundle.main / Bundle.module), EmbeddingSpace
      Model/                  MiniLM_L6_v2.mlmodelc, vocab.txt, MODEL.md (a resource folder, not source)
    Search/                   SearchModels, KeywordQuery (sanitizer), RankFusion (RRF), SearchService
    OpenLibrary/              HTTPTransport (+ URLSessionTransport), RequestGate, OpenLibraryClient, OpenLibraryModels,
                              ISBN, ImportDraft, BookImporter; DEBUG StubOpenLibraryTransport + StubOpenLibraryFixtures
    Geo/                      HeadingNormalizer, PlaceGeocoder, CLPlaceGeocoder, PlaceLocator; DEBUG StubPlaceGeocoder
    Graph/                    GraphStore (one Relate Database), Schema (a Relate Migrator); UI-free, testable
      Queries/                LibraryQueries, BookQueries, AuthorQueries, TermQueries,
                              StatusQueries, TagQueries, NoteQueries, EmbeddingQueries, SearchQueries, PlaceQueries,
                              ImportQueries, ConnectionQueries (two-hop links), NextUpQueries
                              (Cypher + GraphStore extensions)
      Models/                 BookSummary, BookDetail (+ AuthorRef, EditionItem, SeriesMembership, AwardWin),
                              AuthorDetail, AuthorSummary, TermKind, TermSummary, LibraryFilter, LibrarySort, ReadingStatus,
                              UserData (BookUserData, TagSummary, BookTag, BookNote, TagColor, LocalDay, UserDataError),
                              Place (GeoCoordinate, GeoBox, PinTier, PlacePin, PlaceSummary, PlaceLocation, NearbyPlace)
      Decoding/Row.swift      tolerant typed accessors over Relate records
    Navigation/Route.swift    Route (book/author/term/tag/addBook/addedBook), AddedBookNotice, AppTab and LaunchOptions
    ViewModels/               @MainActor @Observable LibraryModel, PagedBooks, BookDetailModel, AuthorModel, TermModel,
                              TagsModel, TagBooksModel, IndexingModel, SearchModel, MapModel + PlaceSheetModel, AddBookModel;
                              UserDataController (every user-data
                              write + change notifications); AppSession (the store, the controller, the tab models,
                              the embedder, indexing and search, the Open Library client, importer and place locator)
    Resources/books.rl        bundled store (copy of ../books.rl)
  Tests/RelateBooksCoreTests/ Swift Testing suites, run on the Mac against in-memory/temp stores
    Fixtures/                 tokenizer_fixtures.json, embedding_fixtures.json (written by convert_embedding_model.py)
      OpenLibrary/            10 recorded Open Library responses (The Perfect Storm, Project Hail Mary, not-found)
  UITests/                    XCUITest target RelateBooksUITests (add books, chip navigation, map, search + indexing, user data + relaunch;
                              not part of SwiftPM)
  docs/                       simulator screenshots (phase0-* … phase5-*)
```

The same sources are built two ways, in two separate build graphs:

- **Xcode app target.** Compiles all of `RelateBooks/` directly as module `RelateBooks` and depends only on the `Relate` package product. It does not depend on `ios/Package.swift`.
- **SwiftPM (`swift test`).** Target `RelateBooksCore` uses `path: "RelateBooks"` with `exclude: ["App", "Features", "Resources"]`. So it compiles only the UI-free `Embedding/`, `Search/`, `Graph/`, `Navigation/`, `ViewModels/`, `OpenLibrary/` and `Geo/` code, and the 7 MB store stays out of the test bundle. `Embedding/Model` is a `.copy` resource (`resources: [.copy("Embedding/Model")]`). SwiftPM does not compile Core ML models, so the pre-compiled `.mlmodelc` is shipped. In `project.yml` the same folder is excluded from the app's sources and added as a `type: folder` resource, so one artifact serves both: `RelateBooks.app/Model/…` and `Bundle.module/…/Model/…`. `EmbeddingResources` uses `Bundle.module` under `SWIFT_PACKAGE` and `Bundle.main` otherwise. Tests use `@testable import RelateBooksCore`, so core types stay `internal`.

**Rule for new folders.** When you add a UI folder directly under `RelateBooks/` (for example `Features/`), add it to `exclude` in `Package.swift` and run `xcodegen generate`. New subfolders of `Features/` are already covered. A **resource** folder goes in `resources` (`.copy`) in `Package.swift`, not `exclude`, and gets a matching `type: folder` entry plus an `excludes` line in `project.yml`. List only folders that exist, because SwiftPM warns about invalid excludes.

`GraphStore` is a `Sendable` value around one Relate `Database`, opened once. The database owns the connections: one writer and up to two readers, each on its own queue. A query method runs its statement with `read` (a transaction that is rolled back, on a reader) or `write` (one transaction on the writer); several statements that must agree share one `database.read { }` or `database.write { }`. Reads do not wait for a write in progress. View models are `@MainActor` and `await` the store, and views never contain Cypher.

- **Statements** are `Relate.Statement` values with named parameters, built with Swift values: `try Statement("MATCH (b:Book {key: $key}) …", ["key": key, "rating": rating, "now": now])`. Building one can throw (a value Cypher cannot hold), so the builders in `Graph/Queries` are `throws`. A filter that has several optional parts builds a statement and `append`s to it, which carries the parameters along (`LibraryQueries.page`).
- **One trap.** `Statement("…\(x)…")` with one argument is a statement *literal*: `\(x)` is bound as a parameter, not spliced into the text. Splice program text with `\(raw: x)` and a label with `\(identifier: x)`. With a parameter dictionary as the second argument the text is an ordinary Swift string, which is how the builders here are written.
- **Subqueries.** The engine reports any statement that contains a `CALL { }` subquery as read-write, and a managed read refuses a statement that is not a read. The library's text search and the ISBN lookup are such statements; they run through `GraphStore.readWithSubquery`, on the writer, and commit nothing.
- **Logging.** The database's trace handler writes one line per statement to the `query` log channel (rows, engine and wall time, the first 160 characters of the text, marked private). Each statement is also a signpost interval in Instruments (subsystem `ai.relatedb.relate`).

**User-data writes** all go through the one `UserDataController` in `AppSession`. It writes through `GraphStore`, re-reads the book's `BookUserData`, and publishes a `UserDataChange`. Every model that shows that book patches its rows in place, or marks itself for reload on appear when the change could move rows (a status filter, the recently-updated sort, or a tag filter). Book detail updates optimistically and takes the re-read value; on error it restores its snapshot and shows an alert. Note saves and tag create/rename wait for the write, so the sheet or alert stays open with the text on error. Each write is a single statement. The multi-statement transactions are the DEBUG reset and (phase 5) a book import, which goes through `UserDataController.saveImportedBook` and publishes `.bookAdded`.

**Query conventions.** Each list query filters `Book`s, computes one `sortKey` per book, sorts, applies `SKIP $skip LIMIT $limit`, and only then joins authors (`collect(DISTINCT a.name)`, since the store has same-name Author nodes) and one wishlist item (`LibraryQueries.summaryProjection()`): the first by position, or, while a format filter is on, the first item in that format. Image URLs decode through `Row.imageURL`, which upgrades `http` to `https`, so no ATS exception is needed. Only active filters go into the WHERE clause; every value is a parameter. Search text runs as a UNION of three label scans (book titles, author names, item titles); on the real store that measured about 3x faster than per-book `EXISTS` subqueries. Detail queries use pattern comprehensions, so a book with many subjects and several items does not fan out.

- **Tag filter.** When there is no search text, a tag-filtered page starts at the `Tag` (`MATCH (t:Tag {name: $tag})<-[:TAGGED]-(b:Book)`) instead of testing each book with `EXISTS`. That takes 0.2–3.7 ms instead of 7–10 ms.
- **Timestamp policy.** A statement binds times as values. `$now` is a `Foundation.Date`, stored as a UTC DATETIME to the microsecond. `$today` is `CypherValue.Date(now, in: calendar.timeZone)`, the calendar day in the user's time zone, stored as a DATE. Stores written by earlier builds hold the same DATETIME and DATE types (at millisecond precision), so old and new values compare and sort together. App statements never call argument-less `date()` or `datetime()`: the engine clock is UTC, so `date()` would give tomorrow's date on a US evening. `started_on` and `finished_on` are DATE values; `status_changed_on`, `Tag.created_on`, `TAGGED.on`, `Note.created_on` and `Note.updated_on` are DATETIME values.
- **Defaults are never written.** A missing `reading_status` means Want. It is written only on a book the user touched. "Recently updated" counts status changes only.
- **Transactions.** Never create and then delete the same node inside one explicit transaction. Relate panics ("update counters are non-negative") and poisons the connection. This happened on 0.16.1 and was re-checked on 1.0.1 (2026-11-12) with a standalone Swift repro, and on `main` at `af8c2e4` (2026-11-15) and 1.1.0 (2026-11-17) through `Database.write`: still present (LABS-1188). There the write throws an internal error, the pool replaces the connection, and the next call works.

## Binary size

Re-measured 2026-11-12 on Relate 1.0.1, same build: the executable is 28,406,872 bytes (+1,271,096 over 0.16.1, engine only; the app code did not change), 22,289,184 after `strip -x` (+1,131,528), and the `.app` holds 81,188,104 bytes of files (77 MB on disk). That `.app` still bundled the 7,315,456-byte original export; the sample store is 212,992 bytes, so a current build is about 7.1 MB smaller (not re-measured). The table below is the 0.16.1 measurement.

Measured 2026-11-08 after phase 5: Release, `generic/platform=iOS`, arm64, `CODE_SIGNING_ALLOWED=NO`, Xcode 27.2.

```sh
xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/rb-dd-rel CODE_SIGNING_ALLOWED=NO build
```

| What | Size |
| --- | --- |
| `RelateBooks.app/RelateBooks` | 27,135,776 bytes (25.9 MiB; re-measured after both review rounds); phase 4 was 25,853,200 (+1,282,576 for adding books: the Open Library client and importer, geocoding, the Add Book UI and the DEBUG-only code that Release leaves out), phase 3 25,082,640, phase 0 21,699,800 |
| same after `strip -x` | 21,157,656 bytes (20.2 MiB); phase 4 was 20,616,688 (+540,968), phase 0 19,017,360 |
| `.app` total | 79,917,008 bytes of files (76 MB on disk): the executable, the 7,315,456-byte geocoded `books.rl` and the 45.5 MB `Model/` folder (`MiniLM_L6_v2.mlmodelc` 45,228,025 bytes plus `vocab.txt` and `MODEL.md`). Phase 4 was 78,634,348; phase 0 28 MB. VisionKit, Vision, CoreLocation and MapKit are system frameworks and add nothing to the bundle. The Info.plist carries `NSCameraUsageDescription`. |

On the original export, after a full index, the store in Application Support grew from 7.3 MB to about 46 MB (46,026,752 bytes on the simulator after the phase 4 UI run; 45,838,336 after phase 3).

The app links with `-dead_strip` (`DEAD_CODE_STRIPPING = YES`), which cuts the roughly 163 MB `ios-arm64` static library down to about 21 MB.

A Debug simulator build is not a size measure. It puts the code in `RelateBooks.debug.dylib` (about 25 MB), and the small `RelateBooks` stub next to it is only a launcher.

## Store lifecycle

- **First launch.** `GraphStore.bootstrap` calls `Database.provision` to copy the bundled `books.rl` to `Application Support/library.rl` (`Database.defaultStoreURL`). The copy goes to a temporary name, gets mode 0600 and `FileProtectionType.completeUntilFirstUserAuthentication`, and is then moved into place. The app then opens the copy, migrates it and checkpoints.
- **Schema.** `Schema.migrator` is a Relate `Migrator`: the index and constraint statements run on every launch, and the version is `(:AppMeta {key: 'schema_version'}).version` (2). Builds before the migrator kept it in `.value`; `Schema.migrate` moves it across first, so an installed store upgrades in place. A store written by a newer build is refused before anything runs.
- **Later launches** reuse the existing `library.rl`. The bundled file is never opened in place.
- **To reset**, delete the app from the device or simulator.
- **Interrupted first launch.** A failed copy removes its own temporary file, and a later launch removes one that an interrupted launch left behind, once it is more than ten minutes old (`Database.provision`).
- **Poisoned connection.** After a call fails at stage `.internal`, the database probes the connection it ran on and replaces a poisoned one on the next use. The error is rethrown and nothing is retried.
- **Checkpoint.** `AppEnvironment.checkpoint()` runs when the scene goes to the background (and after the DEBUG reset), never per write. Writes are already durable through the WAL inside the `.rl` file.
- **User data** (status, rating, tags, notes, and books added in the app) lives only in `library.rl`. Deleting the app deletes it; export and import come in phase 6.
- **One process at a time.** A `.rl` store is single-file (the WAL lives inside it) and takes an exclusive lock, so only one process can open it.
- **Refreshing the bundle.** The shipped store is the root `books.rl` after the extension's geocode pass (`relate run wishlist-to-graph --geocode -d ./books.rl`, then `scripts/refresh_store.sh`). Geocoding adds properties without changing the file's byte size, so compare checksums, not sizes, when checking whether the bundle changed. The pre-geocode export from 2026-11-08 is kept at `backups/books-2026-11-08-pre-geocode.rl`; a device that already has `library.rl` keeps its old copy until the app is reinstalled.
