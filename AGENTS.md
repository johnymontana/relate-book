# Working in this repository

Guidance for coding agents (and humans) on relate-book. Three deliverables live
here: a Relate extension that imports an Amazon wishlist into a graph
(`wishlist-to-graph/`), a SwiftUI iPhone app over that graph (`ios/`), and a
browser app over the same graph that runs Relate as WebAssembly (`web/`).
Read the README closest to what you touch before changing it:
[`README.md`](README.md), [`wishlist-to-graph/README.md`](wishlist-to-graph/README.md),
[`ios/README.md`](ios/README.md), [`web/README.md`](web/README.md). The product plan, every design decision and
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
web/                    Vite + React + TypeScript app: Relate WASM, NVL, WebLLM, transformers.js
  src/engine/           the engine worker, the dataset loader, the graph model (no React)
  src/queries/          Cypher per tab (no React); src/search/ and src/ai/ are logic, tested in Node
  src/features/, components/, state/   UI only
  scripts/export-store.mjs   .rl -> dataset JSON through the relate CLI
  public/data/sample.json    the public sample as a dataset (tracked); local/ is your export (git-ignored)
  tests/, e2e/          Vitest (Node, real WASM engine) and Playwright (installed Chrome)
docs/                   ios-app-plan.md (plan + changelog), research.md
books.rl                your own export (git-ignored); ios/RelateBooks/Resources/books.rl is the tracked public sample
LICENSE, NOTICE         Apache-2.0; third-party material (model, sample data, screenshots)
```

## External dependencies

- **Relate** (embedded Cypher graph database). The extension, the bundled
  store and the web app are on 1.0.1. The iOS app is on 1.1.0, the first
  release with the Swift API it uses (ADR-0596): `ios/Package.swift` and
  `ios/project.yml` depend on the published Swift package
  `https://github.com/relatedb/relate` at exactly 1.1.0, and SwiftPM downloads
  the checksum-pinned XCFramework (no environment variable; unset any stale
  `RELATE_LOCAL_XCFRAMEWORK`, which makes Relate's manifest look for a local
  build). Commit both `Package.resolved` files. Change the pin only as a
  deliberate upgrade: re-run every suite and re-check the engine notes below.
- The **`relate` CLI** 1.0.1: `curl -sSfL https://relatedb.ai/install.sh | bash`,
  a release binary, or `cargo build --release --locked -p relate-cli` in a
  Relate checkout of tag `v1.0.1`. Check `relate --version` before trusting a
  binary you find lying around; never modify someone else's Relate checkout.
- Full Xcode 27 (Swift Testing macros), `xcodegen` (`brew install xcodegen`),
  an iOS 26 simulator named "iPhone 17". `uv` only for regenerating the Core ML
  model.
- For `web/`: Node 22+, and Google Chrome for the end-to-end tests (Playwright
  drives the installed browser; nothing is downloaded). The app pins
  `@relate/relate-wasm` at exactly 1.0.1; change it only as a deliberate
  upgrade and re-run both suites. The in-browser models are fetched by the
  browser at run time and are never part of the repository or a build.

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
swift test                   # core tests, macOS; expect "Test run with 293 tests in 40 suites passed"
xcodebuild -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/rb-dd build
xcodebuild test -project RelateBooks.xcodeproj -scheme RelateBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:RelateBooksUITests   # ~8 min, 14 tests
```

```sh
# Web
cd web
npm install
npm test                     # unit tests in Node on the real WASM engine; expect "Tests  95 passed (95)"
npm run e2e                  # Playwright, installed Chrome, stubbed models; 12 tests (2 against a production build), about 30 s
npm run typecheck && npm run build
npm run export-store -- ../books.rl      # your list -> web/local/books.json (git-ignored)
npm run refresh-sample       # after the bundled sample store changes
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

`web/public/data/sample.json` is an export of that sample
(`npm run refresh-sample` in `web/`); the web tests name the same books, so
refresh it and both web suites together with the store. A personal export for
the web app goes to `web/local/` (git-ignored, served only by the dev server)
and nowhere else: never under `web/public/`, which is copied into every build.

**Relate engine rule (LABS-1188, still present in 1.0.1 and 1.1.0).** Never create and
then delete the same node inside one explicit transaction: the engine panics
and poisons the connection. Deleting nodes that existed before the transaction
is fine. Every write through `GraphStore` is an explicit transaction now, a
single statement included.

**Relate 1.0.1 engine changes the app depends on.** Upper-case `AND`/`OR`/`NOT`
in a fulltext query string are operators (0.16.1 treated them as words), so
fulltext `$text` must come from `KeywordQuery`. `point.withinBBox` now wraps
the antimeridian; `GeoBox.split()` is kept regardless.

**Relate 1.1.0 behaviour the app depends on.** A statement that
contains a `CALL { }` subquery is reported as read-write whatever it does, and
a managed read refuses it (LABS-1761): run such a statement through
`GraphStore.readWithSubquery`, never `read`. A raw fulltext query string that
ends in a backslash is a syntax error (1.0.1 accepted it), and in a raw
string `*` is a wildcard and a trailing `~` makes a term fuzzy; `KeywordQuery`
sends only letters, digits and spaces, so none of these reach the engine.

**Swift 6 strict concurrency.** `GraphStore` is a `Sendable` struct around one
Relate `Database`, which owns the connections (one writer, pooled readers); the
app never holds a `Connection`. A query method is `async` and runs its
statement with `read` or `write`; statements that must see the same snapshot,
or a check and the write that depends on it, share one `database.read { }` or
`database.write { }` body, because two awaited calls can interleave with other
work. A `read` refuses a statement that writes. View models are
`@MainActor @Observable`. Views contain
no Cypher; query files (`Graph/Queries/*`) contain no SwiftUI. New UI-only
folders go under `Features/`; anything else under `RelateBooks/` is compiled
by `swift test` on macOS too and must build there. A new top-level UI-only
folder must be added to `exclude` in `Package.swift`.

**Web app layering.** The same split as iOS, in TypeScript: `features/`,
`components/` and `state/` contain no Cypher; `queries/` contains no React;
`engine/`, `queries/`, `search/` and `ai/` (except the two `*.worker.ts`
runtimes and their clients) run in Node and are tested there. Only the engine
worker touches the WASM handle. Parameters cross into WASM as JSON, so typed
values are built in the statement (`vector($q, 384, FLOAT32)`, `point($p)`,
`datetime($t)`), never passed as objects.

**Generated Cypher is read-only.** Anything a language model writes goes
through `ai/text2cypher/pipeline.ts`: the lexical guard and the EXPLAIN plan
check both have to pass before it runs (Relate WASM has no per-statement
read-only mode). Do not add a path that runs model output any other way. The
Query tab's own editor is the user's and may write.

**Statements.** Query builders return `Relate.Statement` with named
parameters and Swift values (`try Statement("… $key …", ["key": key])`), so
they `throw`. A one-argument `Statement("…\(x)…")` is a statement literal that
binds `\(x)` as a parameter: splice program text with `\(raw:)` and labels
with `\(identifier:)`, or pass a parameter dictionary, which makes the text a
plain string. A vector is bound with `CypherValue(vector:)` (a bare `[Float]`
is a list), a coordinate with `GeoCoordinate.point()`.

**Graph queries (connections, Next up).** A two-hop read through a shared
node must not expand hubs: count a node's degree once per node (collect its
uses, count, `UNWIND`), skip nodes above the degree cap and noise subjects, and
add the statement to `PerfTests.graphStatements`. The scaled perf store, where
every subject is on hundreds of books, is what catches a per-row degree count
or an `EXISTS` over an award's winners; the six-book sample is what catches
"rare" meaning nothing on a small library. Check both, and a copy of a full
list if you have one, before changing `ConnectionQueries` weights or caps.

**Timestamps.** Statements bind a `Foundation.Date` for an instant (stored as a
UTC DATETIME) and `CypherValue.Date(date, in: timeZone)` for the user's
calendar day (a DATE). Never call argument-less `date()` or
`datetime()` in app Cypher (the engine clock is UTC).

**Writes.** All user-data writes go through `UserDataController`; every write is
one statement or one `transaction`. Multi-entity imports run in one
transaction of `MERGE` statements with no `DELETE`. Defaults are never
bulk-written (a missing `reading_status` means "want").

**Network and privacy.** The iOS app talks only to `openlibrary.org`,
`covers.openlibrary.org` and Apple's geocoder; the extension to Amazon, Open
Library, Nominatim and the optional sources. The web app has no backend: it
fetches model files from Hugging Face and WebLLM's model libraries from
`raw.githubusercontent.com` when the user turns a model on, and hot-links
cover images; the graph, searches and questions never leave the tab, and NVL's
telemetry stays off (`disableTelemetry: true`). User-Agents identify the project
by URL (`+https://github.com/johnymontana/relate-book`) and carry a contact
only when one is passed explicitly (`--contact`). Never put a personal e-mail
address in code, headers, tests or docs. Respect the published rate limits
(Open Library and Nominatim: about 1 request per second anonymous).

**Tests travel with changes.** Core logic gets a Swift Testing case; Cypher is
verified on a store copy with the CLI before it lands in a query file; the
perf suite (`PerfTests.swift`) has a 50 ms budget per query (30 ms for place
queries) and must stay green. UI tests must not depend on the live network or
the camera: use the DEBUG launch flags `--stub-network` and `--simulate-scan`.
In `web/`: logic gets a Vitest case against the real WASM engine
(`tests/helpers/engine.ts`); every few-shot example in
`ai/text2cypher/examples.ts` must validate and run (the suite checks all of
them); end-to-end tests use `?dataset=sample&stub-ai` and must not need the
network, a GPU or a model. A change to how assets, workers or datasets are
located needs the `build` Playwright project to stay green: the dev server
hides URL mistakes that a build exposes.

**Docs travel with changes.** Each phase or notable change appends to the
Changelog in `docs/ios-app-plan.md` (decisions, deviations, measurements) and
updates the relevant README section. The web app keeps its decisions and
measurements in `web/README.md`. Keep numbers in the docs equal to what
was measured.

**Housekeeping.** Scratch files, derived data and store copies belong outside
the repository or in git-ignored paths. Never run `git init`, commit or push
unless asked. Do not create `__pycache__` inside `wishlist-to-graph/` (use
`python3 -B`). In `web/`, `node_modules/`, `dist/`, `local/`, `test-results/`
and `playwright-report/` are ignored; commit `package-lock.json`.

## Status

Phases 0 to 5 of the iOS plan are implemented (browse, reading status/tags/notes,
on-device semantic search, map, adding books). Phase 6 (offline covers,
importing a newer `.rl`, export, share) is pending. On top of the phases the
app has four graph features (graph-expanded search, reasons that link a book
to the user's reading, Next Up, near-your-reading on the map; see "Graph
features" in `ios/README.md`). The iOS app is written against the Swift API
Relate released in 1.1.0 and depends on that published package. The web app (overview
charts, library with hybrid search, NVL graph explorer, Cypher console,
text-to-Cypher and the chat agent) is implemented; it is read-mostly and has
none of the iOS app's user data (status, tags, notes). The Google Books and
Hardcover passes in the extension have never been run end to end (no
credentials).
