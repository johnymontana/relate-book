import Foundation
import Observation

/// Wires the app's actors and bootstraps the store. Main-actor state that
/// views observe; all graph work is awaited on `GraphStore`.
@MainActor
@Observable
final class AppEnvironment {
    enum LoadState {
        case loading
        case ready(AppSession)
        case failed(message: String)
    }

    private(set) var state: LoadState = .loading
    private(set) var store: GraphStore?
    /// Routes pushed on launch (`--open-book`, `--open-author`, `--open-term`).
    let launchOptions: LaunchOptions
    /// The in-flight load, so overlapping `start()` calls share one bootstrap
    /// instead of opening the same `.rl` file twice.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// `--reset-user-data` ran in this process (a retry never resets twice).
    @ObservationIgnored private var didReset = false
    /// `--reset-embeddings` ran in this process.
    @ObservationIgnored private var didResetEmbeddings = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        launchOptions = LaunchOptions.parse(arguments)
    }

    /// Idempotent: a call while ready does nothing, and a call while a load
    /// is in flight awaits that load instead of starting another.
    func start() async {
        if case .ready = state { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await self.load() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func load() async {
        state = .loading
        do {
            guard let bundled = Bundle.main.url(forResource: "books", withExtension: "rl") else {
                throw GraphError.bundledStoreMissing
            }
            let store: GraphStore
            if let existing = self.store {
                store = existing
            } else {
                store = try await GraphStore.bootstrap(bundledStore: bundled)
                self.store = store
            }
            #if DEBUG
            if launchOptions.resetUserData && !didReset {
                try await store.resetUserData()
                try await store.checkpoint()
                didReset = true
                print("RelateBooks: user data reset (--reset-user-data)")
            }
            if launchOptions.resetEmbeddings && !didResetEmbeddings {
                try await store.resetEmbeddings()
                try await store.checkpoint()
                didResetEmbeddings = true
                print("RelateBooks: embeddings reset (--reset-embeddings)")
            }
            #endif
            let total = try await store.bookCount()
            let line = "RelateBooks: opened store with \(total) books"
            print(line)
            Log.store.notice("\(line, privacy: .public)")
            if !launchOptions.routes.isEmpty {
                print("RelateBooks: launch routes \(launchOptions.routes)")
            }
            // Phase 5: the anonymous Open Library client and the geocoder for
            // places an import creates. DEBUG `--stub-network` swaps both for
            // canned responses (UI tests); Release parses and ignores it.
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
            var transport: any HTTPTransport = URLSessionTransport()
            var geocoder: any PlaceGeocoder = CLPlaceGeocoder()
            var simulatedScan: String? = nil
            #if DEBUG
            if launchOptions.stubNetwork {
                transport = StubOpenLibraryTransport()
                geocoder = StubPlaceGeocoder()
                simulatedScan = launchOptions.simulateScan
                print("RelateBooks: stub network (--stub-network)\(simulatedScan.map { ", simulated scan \($0)" } ?? "")")
            }
            #endif
            let session = AppSession(store: store, userData: UserDataController(store: store),
                                     embedder: MiniLMEmbedder.bundled(),
                                     openLibrary: OpenLibraryClient(transport: transport, appVersion: version),
                                     geocoder: geocoder, simulatedScan: simulatedScan)
            state = .ready(session)
            session.indexing.start()
        } catch {
            let message = error.localizedDescription
            print("RelateBooks: failed to open store: \(message)")
            Log.store.error("failed to open store: \(message, privacy: .public)")
            state = .failed(message: message)
        }
    }

    /// Folds the WAL into the store file (D11): called when the app goes
    /// to the background, never per write. Durability comes from the WAL.
    func checkpoint() async {
        guard let store else { return }
        do {
            try await store.checkpoint()
        } catch {
            Log.store.error("checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
