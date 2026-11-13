import Foundation

/// Typed NavigationStack destinations.
enum Route: Hashable, Sendable {
    case book(key: String)
    case author(key: String)
    case term(kind: TermKind, name: String)
    /// A tag's books (Tags tab).
    case tag(name: String)
    /// The Add Book screen (Library "+", phase 5).
    case addBook
    /// Book detail reached from the add flow, with its notice.
    case addedBook(key: String, notice: AddedBookNotice)
}

/// The note on Book detail after the add flow (phase 5).
enum AddedBookNotice: String, Hashable, Sendable {
    case added, alreadyInLibrary

    /// "Added to your library" | "Already in your library"
    var text: String {
        switch self {
        case .added: "Added to your library"
        case .alreadyInLibrary: "Already in your library"
        }
    }
}

/// The root tabs, in tab-bar order.
enum AppTab: String, Sendable, Hashable, CaseIterable {
    case library, tags, search, map
}

/// Launch arguments for testability (simctl launch … --open-book <key>):
///
/// - `--open-book <key>` pushes that Book detail.
/// - `--open-author <key>` pushes that Author page.
/// - `--open-term <kind>=<name>` pushes a term page (kind: subject, genre,
///   series, place, person, era, publisher, award, country).
/// - `--open-tab <library|tags|search|map>` selects the initial tab (an
///   unknown value is ignored and not consumed).
/// - `--search <text>` prefills the Search tab and runs the query; selects
///   the Search tab unless `--open-tab` chose one.
/// - `--map-place <label or heading>` (phase 4) flies the Map tab to that
///   place and opens its sheet once, on first appear; selects the Map tab
///   unless `--open-tab` chose one (it wins over `--search` for the tab).
/// - `--wait-for-index` (flag) shows the indexing status line the UI tests
///   wait on, and reruns a launch `--search` once indexing completes.
/// - `--reset-embeddings` (flag; DEBUG only) removes every stored
///   embedding before the UI loads, so a full index can be timed.
/// - `--reset-user-data` (flag; honoured in DEBUG builds only) deletes all
///   tags and notes, every book added in the app with the nodes its import
///   created, and removes the user properties from books before the UI
///   loads (UI tests).
/// - `--stub-network` (flag; honoured in DEBUG builds only, phase 5)
///   swaps in canned Open Library responses for The Perfect Storm and a
///   stub geocoder, so the add flow needs no network (UI tests).
/// - `--simulate-scan <payload>` (DEBUG only, and only with
///   `--stub-network`, phase 5) feeds that barcode payload once to the
///   Scan section's payload handler, the same one the camera calls.
///
/// Several may be given; they are pushed in order. Unknown arguments
/// (Xcode adds its own, e.g. `-NSDocumentRevisionsDebugMode`) are ignored.
struct LaunchOptions: Equatable, Sendable {
    var routes: [Route] = []
    var resetUserData = false
    var initialTab: AppTab?
    var searchText: String?
    var waitForIndex = false
    var resetEmbeddings = false
    var mapPlace: String?
    /// DEBUG `--stub-network` (D28): canned Open Library + stub geocoder.
    var stubNetwork = false
    /// DEBUG `--simulate-scan <payload>` (D28): fed once to the Scan
    /// section's payload handler. Honoured only with `stubNetwork`.
    var simulateScan: String?

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            let next = arguments.index(after: index)
            let value = next < arguments.endIndex ? arguments[next] : nil
            switch argument {
            case "--open-book":
                if let value, !value.isEmpty { options.routes.append(.book(key: value)); index = next }
            case "--open-author":
                if let value, !value.isEmpty { options.routes.append(.author(key: value)); index = next }
            case "--open-term":
                if let value, let route = termRoute(value) { options.routes.append(route); index = next }
            case "--open-tab":
                if let value, let tab = AppTab(rawValue: value.lowercased()) { options.initialTab = tab; index = next }
            case "--reset-user-data":
                options.resetUserData = true
            case "--search":
                if let value, !value.isEmpty { options.searchText = value; index = next }
            case "--wait-for-index":
                options.waitForIndex = true
            case "--reset-embeddings":
                options.resetEmbeddings = true
            case "--map-place":
                if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { options.mapPlace = value; index = next }
            case "--stub-network":
                options.stubNetwork = true
            case "--simulate-scan":
                if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    options.simulateScan = value.trimmingCharacters(in: .whitespaces)
                    index = next
                }
            default:
                break
            }
            index = arguments.index(after: index)
        }
        if options.mapPlace != nil && options.initialTab == nil {
            options.initialTab = .map
        }
        if options.searchText != nil && options.initialTab == nil {
            options.initialTab = .search
        }
        return options
    }

    /// "subject=Science fiction" → `.term(.subject, "Science fiction")`.
    static func termRoute(_ value: String) -> Route? {
        guard let eq = value.firstIndex(of: "=") else { return nil }
        let kindText = value[..<eq].lowercased()
        let name = String(value[value.index(after: eq)...])
        guard let kind = TermKind(rawValue: kindText), !name.isEmpty else { return nil }
        return .term(kind: kind, name: name)
    }
}
