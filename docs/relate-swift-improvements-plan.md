# Plan: a more idiomatic Relate Swift package

Status: implemented 2026-11-12 as ten stacked branches (`swift-api-0-adr`
to `swift-api-9-snotel-ios-guide`) in the worktree
`/Users/lyonwj/github/relatedb/relate-wt-swift-api`. On 2026-11-13 the ADR was
minted as ADR-0596 and merged as
[relatedb/relate#333](https://github.com/relatedb/relate/pull/333). The first
code branch, `swift-api-1-names-errors`, is draft pull request
[#335](https://github.com/relatedb/relate/pull/335). Branches 2 to 9 are local
only, stacked on it (`main` at `9dfe9bf`). See [Outcome](#9-outcome) for what was
built, the spike results and the deviations from the design below.

Update 2026-11-15: every branch is merged (the last as
[#436](https://github.com/relatedb/relate/pull/436)); no release carries the
stack yet. The relate-book migration (§7) was done the same day against
`main` at `af8c2e4`, through a path dependency on a source snapshot; see
[§10](#10-the-relate-book-migration).

This plans 18 Swift-only improvements to the `Relate` Swift package
(`github.com/relatedb/relate`, sources in `clients/swift`, version 1.0.1). None
needs an engine or C ABI change. The relate-book iOS app (`ios/`) and the Relate
repo's own `examples/ios-snotel` are the two consumers used to validate each step.

## 1. Where the work happens

- **Upstream, in `relatedb/relate`.** The improvements belong in the package, not
  in an add-on. An add-on package was considered and rejected: items 6, 9, 12, 13
  and 15 change the package's own types and cannot be done from outside.
- **In a worktree on a fresh branch.** The Relate repo requires
  `git worktree add <dir> -b <branch> origin/main` for every change; the main
  checkout at `/Users/lyonwj/github/relatedb/relate` is never edited.
- **An ADR comes first** (Relate `AGENTS.md` §1: public-API decisions need an ADR
  before implementation). This matters more than usual here because
  `docs/design/swift-apple-platforms.md` records two decisions this plan reverses:
  - "Synchronous core API; apps call it from their own actor — no fake `async`
    over blocking FFI" (items 1, 2).
  - "Deferred: `Codable` row decoding" (item 3).
- **Every PR carries its docs** (Relate `AGENTS.md` §2): `docs/api/swift/spec.md`,
  `description.md`, at least one runnable example under `docs/api/swift/examples`
  per new public item, and
  `surfaces/relate-cli/src/skill/bundle/references/client-swift.md`.
- **Gate:** `make test-swift` (XCFramework build, `swift test`, the examples, the
  SNOTEL example's tests and simulator build). During development:
  `scripts/build-xcframework.sh --slices macos` once, then
  `RELATE_LOCAL_XCFRAMEWORK=1 swift test`.

## 2. Facts the design rests on

Checked by reading the 1.0.1 sources and specs:

| Fact | Source | Consequence |
| --- | --- | --- |
| The C ABI has no async, cancel, clone or read-only-connection call | `surfaces/relate-ffi/include/relate.h` | Everything below is built from `query`, `begin`, `commit`, `rollback`, `connect`, `checkpoint` |
| A `relate_database` may be shared across threads; calls on one `relate_connection` must be serialized, but may come from different threads | `docs/api/c/spec.md`, Threading | A connection can live on a serial `DispatchQueue`; no thread affinity is needed |
| Reads pin `commit_ts` at statement start and run concurrently with one writer; checkpoint takes the exclusive side | ADR-0018 | A reader pool gives real concurrency (item 2) |
| `begin` pins a snapshot for the whole transaction; `rollback` discards the overlay | ADR-0028 | `begin … rollback` gives a consistent multi-statement read that cannot commit a write (item 1) |
| A caught panic poisons the handle it ran on (a database flag and a connection flag exist separately) | `surfaces/relate-ffi/src/tabular.rs` | A poisoned connection can be replaced from the same `Database` (item 10) |
| Stage `internal` covers more than poison: NULL handle, params-builder refusals, IO failures. All share one code row; only the message differs | `abi.rs` `boundary_error_json`, C spec error table | `isPoisoned` cannot be derived from the error without matching message text, which the Relate repo forbids. Use a probe (item 10) |
| `Relate.Notification` is ambiguous with `Foundation.Notification`; inside `extension CypherValue`, `Date` means `CypherValue.Date` | Compiled a stand-in module with the same shapes | Item 6 |
| Package floor is iOS 16 / macOS 13, Swift 6 language mode | `Package.swift` | Use `OSAllocatedUnfairLock`, not `Mutex` (iOS 18). Do not rely on custom actor executors |

Not verified; each is a spike in PR 0 (§5):

1. A schema statement (`CREATE INDEX …`) inside `begin … rollback`: refused, rolled
   back, or committed? Decides whether `read { }` can promise "never writes".
2. Overload resolution between `[String: CypherValue]` and
   `[String: any CypherValueConvertible]` for dictionary literals (item 4).
3. A reader on a second connection is not blocked while a writer holds an open
   transaction or runs a long statement (ADR-0018 says so; measure it).
4. `Foundation.Date` → `.dateTime` → stored → read back is exact at millisecond
   precision and compares equal to a value stored earlier with `datetime($iso)`.

## 3. Design by item

Items keep the numbers from the improvement list. Sketches show the intended
shape; the ADR and review settle names.

### Async and concurrency (items 1, 2, 10)

```swift
extension Database {
    /// A consistent snapshot on a pooled reader connection. Nothing commits.
    public func read<T: Sendable>(
        _ body: @Sendable (ReadTransaction) throws -> T) async throws -> T

    /// One transaction on the single writer connection; commits when body returns.
    public func write<T: Sendable>(
        retries: Int = 0,
        _ body: @Sendable (Transaction) throws -> T) async throws -> T
}
```

- **Bodies are synchronous closures** run on the connection's own serial
  `DispatchQueue`, bridged with `withCheckedThrowingContinuation`. This is the
  GRDB shape. It keeps the non-`Sendable` `Connection` confined without an actor,
  works on iOS 16, never blocks the cooperative pool, and makes it impossible to
  suspend while holding a transaction.
- **Pool:** one writer connection and up to `maxReaders` reader connections
  (default 2), created lazily and held in state guarded by
  `OSAllocatedUnfairLock`. `Database` stays `Sendable`. A read-only database has
  no writer; `write` throws.
- **`read`** is `begin`, body, `rollback` (subject to spike 1). **`write`** is
  `begin`, body, `commit`, with rollback on throw.
- **Poison recovery (item 10):** when a connection call fails on the call-status
  channel (not an error riding a result), the pool probes the connection with
  `RETURN 1`. If the probe also fails at stage `internal`, the connection is
  discarded and replaced; the original error is rethrown, never retried.
  `Connection.isPoisoned` exposes the same probe for callers using connections
  directly. A typed ABI signal is the clean fix and is noted as a follow-up
  outside this plan.
- **Cancellation:** `Task` cancellation is checked before a body starts. A running
  statement cannot be interrupted without an ABI change; the docs say so.
- **The synchronous API stays** unchanged for command-line tools and tests.

### Transactions (item 9)

- `Transaction` and `ReadTransaction` are non-`Sendable` classes exposing
  `query`/`run` only: no `begin`, `commit`, `rollback` or `setNamespace`. They are
  invalidated when the closure returns.
- `Connection.transaction { tx in }` changes its closure parameter from
  `Connection` to `Transaction`. Call sites that only call `tx.query` compile
  unchanged; this is checked against every existing test and example.
- `retries:` re-runs the body when a statement error or the commit error has
  `retryable == true`, which is the loop the spec describes but does not ship.

### Statements and parameters (items 4, 11)

```swift
public protocol CypherValueConvertible { var cypherValue: CypherValue { get } }

public struct Statement: Sendable, Hashable, ExpressibleByStringInterpolation {
    public var cypher: String
    public var parameters: [String: CypherValue]
}

let key = "/works/OL59800W"
try tx.run("MATCH (b:Book {key: \(key)}) RETURN b.title")   // binds $p0
```

- **Conformances:** `CypherValue`, `Bool`, the signed integers and `UInt8…UInt32`,
  `Double`, `Float`, `String`, `Substring`, `Optional` (nil is `.null`), `Array`,
  `Dictionary<String, _>`, `Foundation.Date`, `URL`, `UUID`. `UInt` and `UInt64`
  are left out because they can overflow `Int64`. `[Float]` converts to a list,
  not a vector; vectors are always explicit (item 7).
- **`query` gains an overload** taking `[String: any CypherValueConvertible]`
  (subject to spike 2). If literals turn ambiguous, the fallback is a
  `Parameters` wrapper type instead of an overload.
- **Interpolation never shares a name with the `String` API.** `query` keeps
  taking `String`; the interpolating entry point is `run(_: Statement)`. If
  `query` accepted both, `query("… \(key)")` would resolve to `String` and inline
  the value into the query text. Labels and relationship types use
  `\(label: name)` / `\(identifier: name)`, which backtick-escape; the app's
  `MERGE (t:\(target.label) …)` needs this.
- **`Statement` replaces** the app's own `Statement` type, and
  `Transaction.run(_: [Statement])` covers batch execution.
- **`CypherValue(encoding:)`** turns an `Encodable` into a `.map` through a custom
  `Encoder`. Nil properties are omitted by default, because `SET n += {k: null}`
  removes `k`; an option encodes them as `.null`.

### Results and decoding (items 3, 12)

```swift
for row in result {                       // QueryResult: RandomAccessCollection
    let title: String = try row.get("title")
    let year: Int? = try row.get("firstPublishYear")
}
let books = try result.decode(BookSummary.self)
let count = try result.scalar(as: Int.self)
```

- **`Row`** is a `Sendable`, `Hashable` view: a shared column index built once per
  result, plus the row's values. `row["name"]`, `row[0]`, and
  `get(_:as:)`, which throws an error naming the column, the expected type and
  the actual kind.
- **`QueryResult`** becomes a `RandomAccessCollection` of `Row` and gains
  `first`, `single()` (throws unless exactly one row) and `scalar(as:)`.
  `records` stays as is for compatibility. `QueryResult` gains `Equatable`; the
  docs note that it compares timings too, so tests should compare `rows`.
- **`Decodable`:** a `CypherValueDecoder` over a row, map, node or relationship,
  with a key strategy option (`convertFromSnakeCase`). It decodes
  `Foundation.Date`, `URL`, `UUID` and `[Float]` (from a vector) specially.
- **Strict by design:** integers widen to `Double`; nothing else converts. The
  app's tolerant rules (an integer from the string `"4"`, empty string as nil)
  stay in the app as a thin layer over `Row`.

### Value bridges (items 5, 7, 8)

- **Dates:** `CypherValue(_: Foundation.Date)` gives a UTC `.dateTime`;
  `DateTime.foundationDate`; `LocalDateTime.foundationDate(in: TimeZone)`;
  `CypherValue.Date` to and from `DateComponents`; `CypherValue.Duration` to
  `Swift.Duration` (failable: only when months and days are zero) and to
  `DateComponents`. Sub-millisecond rounding is settled by spike 4.
- **Vectors:** `CypherValue.vector(_: [Float])` (dtype `FLOAT32`),
  `Vector.float32Values`, `Vector.count`, `Vector.dtype`, and `MLMultiArray` /
  `MLShapedArray<Float>` initializers under `#if canImport(CoreML)`. Storage
  stays `[Double]`; changing the enum payload is a breaking change left for 2.0
  together with a bulk-copy ABI call.
- **Points:** `Point(latitude:longitude:height:)`, `Point(x:y:z:)`, a computed
  `crs` enum over the four srids, computed `latitude`/`longitude` (nil for
  Cartesian), and `CLLocationCoordinate2D` conversions under
  `#if canImport(CoreLocation)`. The stored `srid: Int32` does not change.

### Naming, errors, opening (items 6, 13, 14, 15)

- **Renames (item 6):** `Notification` → `QueryNotification`, `Severity` →
  `NotificationSeverity`, `Category` → `NotificationCategory`, `Namespace` →
  `DatabaseNamespace` (`SwiftUI.Namespace` exists, so `@Namespace` hits the same
  ambiguity rule). `CypherValue.Date` and `CypherValue.Duration` keep their
  names: they mirror Cypher's, and the shadowing only affects code inside
  `extension CypherValue`. See open decision B for how the old names retire.
- **Typed throws (item 13):** `query`, `begin`, `commit`, `rollback`, `connect`,
  `checkpoint`, `setNamespace` and the initializers become
  `throws(RelateError)`. Closure-taking methods stay untyped because the body's
  error type is the caller's.
- **Error predicates (item 14):** `isConstraintViolation`, `isSyntaxError`,
  `isMissingParameter`, `isWriteConflict`, plus `classification` parsed from the
  code's second segment. Each constant has a test that provokes the real engine
  error, so a drift from the engine's table fails CI.
- **Opening (item 15):** `Database(url:readOnly:)`,
  `connect(namespace: DatabaseNamespace)`, and the `Database` doc comment
  corrected to cover single-file `.rl` stores.

### Tracing, observation, provisioning (items 16, 17, 18)

- **Tracing:** `database.setTraceHandler { (QueryTrace) in }` reports statement
  text, row count, the four timings, query type and any error for every
  statement on every connection. Parameter values are never included. An
  option emits `OSSignposter` intervals.
- **Commit stream:** `database.commits()` returns a new `AsyncStream<Commit>` per
  call. The wrapper yields after each auto-commit write that returns a bookmark
  and after each `commit()` that returns one. `Commit` carries the bookmark, the
  summed stats and caller-supplied tags (`write(tags: ["notes"]) { }`), which is
  what lets an app route changes the way `UserDataController` does. Limits,
  stated in the docs: in-process only, and only for writes through this
  `Database` instance.
- **Provisioning:** `Database.provision(at:from:)` copies a seed store when the
  target is missing (temp name, then move; mode 0600; file protection on iOS;
  stale temp cleanup), and `Database.defaultStoreURL(named:)` returns the
  Application Support location.
- **Migrator:** idempotent DDL run every launch, plus versioned steps each in one
  transaction, with the version stored on a node whose label is configurable.

## 4. Compatibility

- Everything is additive except item 6 (renames), item 9 (the `transaction`
  closure parameter type) and any new `RelateError` case. A new enum case breaks
  callers' exhaustive `switch` statements, so all new cases land in one release.
- The guard is mechanical: the existing `clients/swift/Tests`, the five
  `docs/api/swift/examples` and `examples/ios-snotel` must compile with only the
  rename edits before any of them is migrated to the new API.
- No file grows past 1,000 lines (Relate `AGENTS.md`); the plan adds new files
  rather than extending `Database.swift` and `CypherValue.swift`.

## 5. Sequence

Small PRs, one concern each, stacked in dependency order. Each includes tests,
spec, description and an example.

| PR | Contents | Items | Size |
| --- | --- | --- | --- |
| 0 | Run the four spikes; write the ADR (async managed layer, decoding, statement interpolation, rename policy); add a later-reference to the design doc | — | S |
| 1 | Renames; typed throws; `Database(url:)`; typed `connect(namespace:)`; error predicates | 6, 13, 14, 15 | S |
| 2 | Foundation date, vector and point bridges | 5, 7, 8 | M |
| 3 | `CypherValueConvertible`; `Row`; `QueryResult` as a collection; `single`, `scalar(as:)` | 4, 12, 3 (part) | M |
| 4 | `Statement` with interpolation; `run`; `CypherValueEncoder` and `CypherValueDecoder` | 3, 4, 11 | L |
| 5 | `Transaction` types; retry; poison probe | 9, 10 (part) | M |
| 6 | `Database.read` / `write`; reader pool; auto-reconnect | 1, 2, 10 | L |
| 7 | Trace handler, signposts, commit stream | 16, 17 | M |
| 8 | `provision`, `defaultStoreURL`, `Migrator` | 18 | M |
| 9 | Migrate `examples/ios-snotel` to the new API; add an iOS guide (bundle seeding, checkpoint on background, vectors, points, dates) | — | M |

PRs 1 to 4 are independent of the concurrency work and can ship in a release on
their own. PR 6 is the largest design risk and depends on spikes 1 and 3.

## 6. Tests that matter most

- **Reader concurrency:** a read completes while a write body is parked on a
  semaphore inside an open transaction.
- **Read isolation:** a `CREATE` inside `read { }` is gone afterwards; two
  statements in one `read` see the same snapshot across a concurrent commit.
- **Retry:** two connections produce a real write-write conflict; `retries: 1`
  succeeds and `retries: 0` throws with `retryable == true`.
- **Poison recovery:** tested through an injected failing connection, not through
  an engine panic. The only known trigger today is the create-then-delete panic,
  and a test must not depend on an engine bug staying unfixed.
- **Interpolation safety:** a value containing `'}) DETACH DELETE` arrives as a
  parameter and matches nothing.
- **Decoding errors:** a type mismatch names the column and both types.
- **Round trips:** every bridge (date, duration, vector, point, `Encodable`) goes
  to the engine and back.

## 7. Validating in relate-book

After a Relate release that contains PRs 1 to 6 (or earlier through a local path
dependency with `RELATE_LOCAL_XCFRAMEWORK=1`):

| App code | Replaced by |
| --- | --- |
| `Graph/GraphStore.swift` connection ownership and the two reconnect blocks | `Database.read` / `write` |
| `Graph/Decoding/Row.swift` (173 lines) | `Record` and `decode`, keeping the app's tolerant accessors as a small extension. The app's `result.records.map(Row.init)` passes dictionaries, so it needs `.dictionary` (or the app's `Row` wraps a `Record`) |
| `Statement` in `Row.swift` | `Relate.Statement` |
| About 160 `.string(…)` wraps and the `?? .null` patterns | `CypherValueConvertible` and interpolation |
| `Timestamps.instant`, 17 `datetime($now)` and 5 `date($today)` wraps, `Row.instant`, `Row.day` | Date bridges |
| `EmbeddingVector.cypherValue` / `floats(from:)` | `CypherValue.vector(_:)`, `float32Values` |
| `Row.point`, lat/lon float pairs | `Point(latitude:longitude:)`, CoreLocation bridge |
| `Graph/Schema.swift`, `GraphStore.provision` | `Migrator`, `Database.provision` |
| `Log.query` timing in `GraphStore.run` | Trace handler |

Acceptance for the app migration: `swift test` still reports 266 tests in 35
suites passing, the perf suites stay inside their 50 ms and 30 ms budgets, the UI
suite passes 12 of 12 from a fresh install, and the app's `AGENTS.md` rules on
timestamps and connection ownership are rewritten to match. The embedding
indexer moving to the writer while the library list reads from a reader is the
one behaviour change to measure: list latency during first-launch indexing,
before and after.

## 8. Open decisions

| | Decision | Recommendation |
| --- | --- | --- |
| A | `read`/`write` directly on `Database`, or a separate `DatabasePool` type | On `Database`: one object to hold, and the pool is an implementation detail |
| B | Retire the old type names in the next minor release, or keep deprecated aliases until 2.0 | Rename outright in the next minor. A deprecated `typealias Notification` keeps the Foundation ambiguity alive, so aliases do not fix the problem they exist for. `Severity` and `Category` can keep aliases |
| C | One module, or a second `RelateFoundation` / `RelateCoreML` target for the bridges | One module with `#if canImport`. The package already imports Foundation, and system frameworks add no binary size |
| D | Where the migrator stores its version | A node in the default namespace with a configurable label, matching what the app does today |

## 9. Outcome

### Decisions taken (§8)

| | Decision | Chosen |
| --- | --- | --- |
| A | Where `read`/`write` live | On `Database` |
| B | Retiring the old type names | Renamed outright; `Severity` and `Category` keep deprecated aliases |
| C | Module layout | One module, `#if canImport` for Core ML and Core Location |
| D | Migrator version storage | A node with a configurable label and properties (`Migrator.VersionRecord`) |

| E | Name of the row view, and what `records` returns (decided 2026-11-13) | `Record`, not `Row`, to match the Neo4j drivers and the Python client; `QueryResult.records` returns `[Record]` |

Also decided: work in a sibling worktree, one local branch per PR, nothing
pushed; the ADR is drafted but its number is not minted (minting pushes to a
counter branch on `origin`); relate-book is migrated after a release.

### Spike results (§2)

1. A schema statement inside `begin … rollback` succeeds and is discarded by
   the rollback, like a data write. `read { }` can promise that nothing commits.
2. A dictionary of literals is not ambiguous beside the new overload, but it
   resolved to the new one. The new overloads are marked `@_disfavoredOverload`
   so literals keep resolving to the original, non-converting entry point.
3. Reads on a second connection are not blocked: 2,000 reads completed during an
   880 ms write (median 0.03 ms each), and 2,000 writes during a 515 ms read.
4. A `Foundation.Date` round-trips exactly at millisecond precision and is equal,
   in the engine, to the same instant stored with `datetime($iso)`.

### What was built

| Branch | Items | Package tests after it |
| --- | --- | --- |
| `swift-api-0-adr` | ADR draft, later-reference notes | — |
| `swift-api-1-names-errors` | 6, 13, 14, 15 | 48 |
| `swift-api-2-bridges` | 5, 7, 8 | 73 |
| `swift-api-3-records-params` | 4, 12, 3 (part) | 84 |
| `swift-api-4-statements-codable` | 3, 4, 11 | 102 |
| `swift-api-5-transactions` | 9, 10 (part) | 112 |
| `swift-api-6-async-pool` | 1, 2, 10 | 131 |
| `swift-api-7-tracing-commits` | 16, 17 | 147 |
| `swift-api-8-provisioning-migrator` | 18 | 175 |
| `swift-api-9-live-query` | live values (`Database.values`) and the SwiftUI `@LiveQuery` (added 2026-11-15, not in §3) | 204 |
| `swift-api-10-snotel-ios-guide` | SNOTEL example moved to live queries, iOS guide | 204 |

The package went from 39 tests to 204. The SNOTEL example was reworked around
`@LiveQuery` (its views declare their statements; 43 tests pass), it builds
for the iOS Simulator and was launched there. Thirteen documentation
examples run. A pull-request description for each branch is in the worktree's
git-ignored `target/pr-bodies/`.

### Deviations from the design in §3

- **The row view is `Record`, and `records` returns `[Record]`.** §3 calls it
  `Row` and keeps `records` as dictionaries. `record["name"]` reads the same
  as before; `record.dictionary` is the old dictionary form. This is a third
  source-breaking change, beside the renames and the transaction body's
  parameter type. Messages follow: `single()` reports "expected exactly one
  record".
- **One `Transaction` type**, with `isReadOnly`, instead of separate
  `Transaction` and `ReadTransaction`. A read scope refuses a statement whose
  query type is not `read`.
- **`CypherValueConvertible` is two-way and throwing.** It also converts values
  back out (which is what `Row.get` uses), and `UInt`/`UInt64` are supported,
  throwing when a value does not fit, rather than left out.
- **Interpolated literals need `try`.** Binding a value can throw, so
  `let s: Statement = try "… \(key)"`. Inside `try conn.run("…")` the existing
  `try` covers it.
- **`CypherValue(vector:)` is an initializer**, not a static `vector(_:)`
  function, which would have overloaded the enum case of the same name.
- **`isPoisoned()` is a method on `Connection`** (it runs a statement), and
  there is no `error.isPoisoned`: the error alone cannot say.
- **Snake-case decoding looks up the Swift name's snake spelling** rather than
  converting stored keys to camel case. The second way cannot find `cover_url`
  for `coverURL`.
- **Signposts are always on**, not an option; they cost almost nothing unless
  Instruments is recording.
- **Two new `RelateError` cases**: `unexpectedResult` and `misuse`.
- **Added beyond the list:** `Connection.read`, `runInTransaction`,
  `Database.checkpointInBackground()`, `Statement` embedding, `QueryType`
  descriptions.
- **The SNOTEL example keeps its own query log** rather than adopting the trace
  handler, because its log deliberately shows parameter values.

### Not verified

- The CI `swift` job has not run; `make test-swift` was reproduced piecewise.
- Only Swift 6.4.2 was tried. One construct crashed that compiler (a typed-throws
  closure passed where an untyped one is expected) and was rewritten.
- The SNOTEL app was built for the simulator, not launched.
- iOS file protection in `provision` is compiled only for iOS and is not
  exercised by the macOS test run.
- No signpost output is asserted.

### Left to do

1. ~~Mint the ADR number.~~ Done: ADR-0596, merged in #333.
2. Branch 1 is draft PR #335. Push branches 2 to 9 and open their pull
   requests in order. Each PR is squash-merged, so after each merge the rest
   is rebased onto `main`.
3. ~~After a release, migrate relate-book (§7).~~ Done before a release, on
   2026-11-15 (§10). After a release: point the app back at the published
   package (steps in `ios/README.md`).

## 10. The relate-book migration

Done on 2026-11-15; the record is the last entry of the changelog in
[`ios-app-plan.md`](ios-app-plan.md). Against the table in §7:

| §7 row | Outcome |
| --- | --- |
| `GraphStore` connection ownership and reconnect blocks | Replaced by `Database.read` / `write`; `GraphStore` is a `Sendable` struct |
| `Row.swift` | Kept as the tolerant layer, over `Record`; its date and point reads use the bridges. `Codable` decoding not adopted |
| The app's `Statement` | Deleted; `Relate.Statement` |
| `.string(…)` wraps and `?? .null` | 143 wraps down to 17 (nested maps), through the `[String: any CypherValueConvertible]` initializer. Named parameters kept; interpolated literals not adopted |
| `Timestamps`, `datetime($now)`, `date($today)` | Deleted; `Foundation.Date` and `CypherValue.Date(_:in:)` are bound directly |
| `EmbeddingVector.cypherValue` / `floats(from:)` | `CypherValue(vector:)`, `float32Values` |
| `Row.point`, lat/lon float pairs | `CypherValue.Point(latitude:longitude:)` parameters; `latitude` / `longitude` accessors |
| `Schema.swift`, `GraphStore.provision` | `Migrator(versionLabel: "AppMeta")` plus one statement that adopts the old `value` property; `Database.provision`, `defaultStoreURL` |
| `Log.query` timing in `GraphStore.run` | Trace handler |

What the migration found in the package and the engine:

1. **A read refuses a read-only `CALL { }` subquery.** The engine reports the
   query type of any statement containing a CALL subquery as read-write, and
   `Connection.read` refuses what is not a read. The app's text search and
   ISBN lookup hit this and run on the writer instead. Either the engine's
   classification or the read scope's rule needs to change before a consumer
   can use subqueries in reads.
2. **`Statement("…\(x)…")` with one argument binds `\(x)`.** The type is
   expressible by a string literal, so `Statement(literal)` is the literal
   form, not the `String` initializer, and an interpolated Swift string that
   was program text becomes a parameter. It compiles silently wherever a
   `try` is already in scope. Worth a line in the spec's Statements section
   and in the iOS guide.
3. **Atomicity moves to the caller.** Code that was one actor method becomes
   several awaited calls; a check followed by a write has to move into one
   `write` body. The guide could say so where it introduces `read`/`write`.
4. **A migrator cannot adopt an existing version record** that uses another
   property name: it reports the node as a broken record. An app that
   already versions its store needs a statement of its own first.

Not measured: the app's binary size on the new package, and the Xcode GUI
path (the app was built and tested from the command line only).
