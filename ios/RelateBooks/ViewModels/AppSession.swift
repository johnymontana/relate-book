import Foundation

/// The long-lived objects the app builds once the store is open: one
/// `UserDataController` shared by every screen, the root tab models, and
/// (phase 3) the embedder, indexer model and search, (phase 4) the map, and
/// (phase 5) the Open Library client, the importer and the one shared
/// place locator.
@MainActor
struct AppSession {
    let store: GraphStore
    let userData: UserDataController
    let library: LibraryModel
    let tags: TagsModel
    /// nil when the model is missing: search is keyword only.
    let embedder: (any TextEmbedder)?
    let indexing: IndexingModel
    let searchService: SearchService
    let search: SearchModel
    /// The Map tab (phase 4).
    let map: MapModel
    /// The Map tab's "Near your reading" list.
    let nearReading: NearReadingModel
    /// The Library's "Next up" screen.
    let nextUp: NextUpModel
    /// Phase 5: the anonymous Open Library client (one gate for the app).
    let openLibrary: OpenLibraryClient
    let importer: BookImporter
    /// ONE locator, so its RequestGate keeps geocoding serial across imports (D13).
    let placeLocator: PlaceLocator
    /// DEBUG `--simulate-scan` payload; AppEnvironment passes it only with
    /// `--stub-network`.
    let simulatedScanPayload: String?

    /// - openLibrary: default `OpenLibraryClient(transport: URLSessionTransport())`.
    /// - geocoder: default `CLPlaceGeocoder()` (where CoreLocation exists).
    init(store: GraphStore, userData: UserDataController? = nil, embedder: (any TextEmbedder)? = nil,
         openLibrary: OpenLibraryClient? = nil, geocoder: (any PlaceGeocoder)? = nil,
         simulatedScan: String? = nil) {
        let controller = userData ?? UserDataController(store: store)
        self.store = store
        self.userData = controller
        self.library = LibraryModel(store: store, userData: controller)
        self.tags = TagsModel(controller: controller)
        self.embedder = embedder
        let indexer = embedder.map { EmbeddingIndexer(store: store, embedder: $0) }
        self.indexing = IndexingModel(indexer: indexer, userData: controller)
        let service = SearchService(store: store, embedder: embedder)
        self.searchService = service
        self.search = SearchModel(service: service, userData: controller)
        self.map = MapModel(store: store, userData: controller)
        self.nearReading = NearReadingModel(store: store, userData: controller)
        self.nextUp = NextUpModel(store: store, userData: controller)
        let client = openLibrary ?? OpenLibraryClient(transport: URLSessionTransport())
        self.openLibrary = client
        self.importer = BookImporter(client: client, store: store)
        self.placeLocator = PlaceLocator(store: store, geocoder: geocoder ?? AppSession.defaultGeocoder())
        self.simulatedScanPayload = simulatedScan
        // A book embedded after an add re-runs the visible Search query, so
        // it can appear semantically even when the add flow stopped waiting.
        let search = self.search
        indexing.onBookEmbedded = { [weak search] key in
            Task { await search?.bookDidEmbed(key: key) }
        }
    }

    private static func defaultGeocoder() -> any PlaceGeocoder {
        #if canImport(CoreLocation)
        CLPlaceGeocoder()
        #else
        NoGeocoder()
        #endif
    }

    /// The Add Book screen's model. No side effects (SwiftUI may build
    /// and discard extra instances).
    func addBookModel() -> AddBookModel {
        AddBookModel(importer: importer, controller: userData, locator: placeLocator, indexing: indexing,
                     simulatedScan: simulatedScanPayload)
    }

    /// A Book detail model wired to the shared controller and search.
    func bookDetailModel(key: String) -> BookDetailModel {
        BookDetailModel(key: key, store: store, userData: userData, search: searchService)
    }
}

#if !canImport(CoreLocation)
/// No geocoder on this platform: every place stays unresolved.
struct NoGeocoder: PlaceGeocoder {
    let sourceName = "none"
    func geocode(_ query: String) async throws -> [GeocodeCandidate] { [] }
}
#endif
