# Working in this repository

Guidance for coding agents (and humans) on relate-book. Two deliverables live
here: a Relate extension that imports an Amazon wishlist into a graph
(`wishlist-to-graph/`) and a SwiftUI iPhone app over that graph (`ios/`).
Read the README closest to what you touch before changing it:
[`README.md`](README.md), [`wishlist-to-graph/README.md`](wishlist-to-graph/README.md),
[`ios/README.md`](ios/README.md). The product plan, every design decision and
the per-phase changelog are in [`docs/ios-app-plan.md`](docs/ios-app-plan.md);
the research that shaped the extension is in [`docs/research.md`](docs/research.md).

## Layout

```
wishlist-to-graph/      Relate extension: extension.json + wishlist-to-graph.py (Python 3.10+, stdlib only)
ios/                    Xcode project (xcodegen) + SwiftPM package RelateBooksCore + tests + UI tests
  RelateBooks/          app sources; App/ and Features/ are UI-only, everything else is core and tested
  Tests/                Swift Testing suites (run on the Mac against in-memory or temp stores;
                        ScaledLibrary.swift grows the sample to 1,800 books for the perf suites)
  UITests/              XCUITest suite (simulator)
  docs/                 simulator screenshots per phase
  scripts/              refresh_store.sh, convert_embedding_model.py (+ pinned requirements)
docs/                   ios-app-plan.md (plan + changelog), research.md
books.rl                your own export (git-ignored); ios/RelateBooks/Resources/books.rl is the tracked public sample
LICENSE, NOTICE         Apache-2.0; third-party material (model, sample data, screenshots)
```

## External dependencies

- **Relate** (embedded Cypher graph database, 1.0.1). `ios/Package.swift` and
  `ios/project.yml` depend on the published Swift package
  `https://github.com/relatedb/relate` at exactly 1.0.1; SwiftPM downloads the
  checksum-pinned XCFramework (no environment variable; unset any stale
  `RELATE_LOCAL_XCFRAMEWORK`). Commit both `Package.resolved` files. Change the
  pin only as a deliberate upgrade: re-run every suite and re-check the engine
  notes below.
- The **`relate` CLI** 1.0.1: `curl -sSfL https://relatedb.ai/install.sh | bash`,
  a release binary, or `cargo build --release --locked -p relate-cli` in a
  Relate checkout of tag `v1.0.1`. Check `relate --version` before trusting a
  binary you find lying around; never modify someone else's Relate checkout.
- Full Xcode 27 (Swift Testing macros), `xcodegen` (`brew install xcodegen`),
  an iOS 26 simulator named "iPhone 17". `uv` only for regenerating the Core ML
  model.

## Commands

```sh
# Extension
relate extension install wishlist-to-graph --from ./wishlist-to-graph
relate run wishlist-to-graph <wishlist-url> [--contact you@example.com] [--wikidata] [--geocode] -d ./books.rl
relate run wishlist-to-graph --geocode -d ./books.rl        # geocode-only pass on an existing store
python3 -I -B wishlist-to-graph/wishlist-to-graph.py --self-test   # offline geocoder checks

# Ad-hoc Cypher (always on a COPY of a store; --read-only unless you are testing a write)
relate query --read-only -d ./copy.rl "MATCH (b:Book) RETURN count(b)"   # --param N=V, --json --max-rows 0

# iOS
cd ios
xcodegen generate            # after adding or removing files; commit project.yml AND the .xcodeproj
swift test                   # core tests, macOS; expect "Test run with 266 tests in 35 suites passed"
xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rb-dd build
xcodebuild test -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RelateBooksUITests   # ~7 min, 12 tests
```

UI tests need a fresh install (`xcrun simctl uninstall <udid> com.johnymontana.RelateBooks`)
because the app keeps its own copy of the store, and they include the
first-launch embedding pass (about a minute with the six-book sample, mostly
launch and model load). `TEST_RUNNER_SCREENSHOT_DIR=/abs/dir` saves the
screenshots that `ios/docs/` holds. Run one simulator at a time and
shut it down afterwards. Xcode 27 shows simulators through its `DeviceHub.app`;
there is no separate `Simulator.app`.

## Rules that are easy to get wrong

**Stores.** `ios/RelateBooks/Resources/books.rl` is the public six-book
sample (`https://www.amazon.com/hz/wishlist/ls/9N4X43GP6SVK`, imported with
`--wikidata --geocode` on relate 1.0.1; sha256 `b798db09…5aee3c`, 212,992
bytes). Geocoding does not change the byte size, so compare checksums, never
sizes. Do not edit it in place; tests copy it to a temp directory, and the
perf suites grow that copy with `ScaledLibrary`. Functional and UI tests name
the sample's books, places and terms (Left Hand of Darkness, Project Hail
Mary, San Francisco, Gethen, Hainish Cycle…), so replacing the sample means
updating them. **Never commit a personal export**: a store records the list id
and URL. Root `books.rl` and `backups/` are git-ignored for that reason.

**Relate engine rule (LABS-1188, still present in 1.0.1).** Never create and
then delete the same node inside one explicit transaction: the engine panics
and poisons the connection. Deleting nodes that existed before the transaction
is fine.

**Relate 1.0.1 engine changes the app depends on.** Upper-case `AND`/`OR`/`NOT`
in a fulltext query string are operators (0.16.1 treated them as words), so
fulltext `$text` must come from `KeywordQuery`. `point.withinBBox` now wraps
the antimeridian; `GeoBox.split()` is kept regardless.

**Swift 6 strict concurrency.** `Connection` is not `Sendable` and never leaves
the `GraphStore` actor. View models are `@MainActor @Observable`. Views contain
no Cypher; query files (`Graph/Queries/*`) contain no SwiftUI. New UI-only
folders go under `Features/`; anything else under `RelateBooks/` is compiled
by `swift test` on macOS too and must build there. A new top-level UI-only
folder must be added to `exclude` in `Package.swift`.

**Timestamps.** Swift passes ISO-8601 strings and statements use
`datetime($now)` / `date($today)`. Never call argument-less `date()` or
`datetime()` in app Cypher (the engine clock is UTC).

**Writes.** All user-data writes go through `UserDataController`; every write is
one statement or one `transaction`. Multi-entity imports run in one
transaction of `MERGE` statements with no `DELETE`. Defaults are never
bulk-written (a missing `reading_status` means "want").

**Network and privacy.** The app talks only to `openlibrary.org`,
`covers.openlibrary.org` and Apple's geocoder; the extension to Amazon, Open
Library, Nominatim and the optional sources. User-Agents identify the project
by URL (`+https://github.com/johnymontana/relate-book`) and carry a contact
only when one is passed explicitly (`--contact`). Never put a personal e-mail
address in code, headers, tests or docs. Respect the published rate limits
(Open Library and Nominatim: about 1 request per second anonymous).

**Tests travel with changes.** Core logic gets a Swift Testing case; Cypher is
verified on a store copy with the CLI before it lands in a query file; the
perf suite (`PerfTests.swift`) has a 50 ms budget per query (30 ms for place
queries) and must stay green. UI tests must not depend on the live network or
the camera: use the DEBUG launch flags `--stub-network` and `--simulate-scan`.

**Docs travel with changes.** Each phase or notable change appends to the
Changelog in `docs/ios-app-plan.md` (decisions, deviations, measurements) and
updates the relevant README section. Keep numbers in the docs equal to what
was measured.

**Housekeeping.** Scratch files, derived data and store copies belong outside
the repository or in git-ignored paths. Never run `git init`, commit or push
unless asked. Do not create `__pycache__` inside `wishlist-to-graph/` (use
`python3 -B`).

## Status

Phases 0 to 5 of the plan are implemented (browse, reading status/tags/notes,
on-device semantic search, map, adding books). Phase 6 (offline covers,
importing a newer `.rl`, export, share) is pending. The Google Books and
Hardcover passes in the extension have never been run end to end (no
credentials).
