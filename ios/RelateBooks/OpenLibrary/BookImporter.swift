import Foundation

/// Why an import could not produce a draft.
enum ImportError: Error, Equatable, LocalizedError {
    /// Open Library has no record for this ISBN-13 or work key.
    case notFound(String)
    /// Manual entry without a title.
    case emptyTitle
    case network(OpenLibraryError)

    /// D32 copy.
    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            id.hasPrefix("/works/")
                ? "Open Library has no record for \(id). Try another result, or add the book manually."
                : "No Open Library record for ISBN \(id). Check the number, or add the book manually."
        case .emptyTitle:
            "Enter a title."
        case .network(let error):
            error.errorDescription
        }
    }
}

/// What a lookup found.
enum ResolveResult: Sendable, Equatable {
    case draft(ImportDraft)
    case alreadyInLibrary(key: String)
}

/// Resolves an ISBN or a search result into an `ImportDraft` (network), and
/// answers local "already in library" questions (store). Saving is
/// `GraphStore.saveImport`, through `UserDataController.saveImportedBook`.
///
/// Lookups mirror the extension's `resolve` / `enrich_from_open_library`
/// (D5-D7): search doc → work → authors that are not in the store yet (at
/// most 8 authors). Any network error fails the whole lookup before
/// anything is written (D4); a 404 on the work leaves it empty and a 404
/// on an author falls back to the doc's name. Every `OpenLibraryError` is
/// wrapped as `ImportError.network`; CancellationError passes through.
struct BookImporter: Sendable {
    let client: OpenLibraryClient
    let store: GraphStore
    static let maxAuthors = ImportDraft.maxAuthors

    init(client: OpenLibraryClient, store: GraphStore) {
        self.client = client
        self.store = store
    }

    /// D5 step 1 (no network): the Book whose Item (isbn13 / isbn10) or
    /// Book (isbn13) carries this ISBN.
    func localMatch(isbn: ISBN) async throws -> String? {
        try await store.bookKey(matching: isbn)
    }

    /// `localMatch` with the book's title (for the result note).
    func localBook(isbn: ISBN) async throws -> (key: String, title: String?)? {
        try await store.bookMatch(matching: isbn)
    }

    /// Which of `keys` are Books already (search-result badges, D22).
    func localKeys(_ keys: [String]) async throws -> Set<String> {
        try await store.existingBookKeys(keys)
    }

    /// D5 steps 2-6: `q=isbn:<13>`, then `q=isbn:<10>`, then `/isbn/<13>.json`
    /// → `q=key:"<works[0]>"`. A doc whose key is already a Book is
    /// `.alreadyInLibrary` with no further requests. Throws `.notFound`,
    /// `.network`, or CancellationError.
    func resolve(isbn: ISBN) async throws -> ResolveResult {
        do {
            var doc = try await client.searchISBN(isbn.isbn13).first
            if doc == nil, let ten = isbn.isbn10 {
                doc = try await client.searchISBN(ten).first
            }
            var edition: OLEdition?
            if doc == nil, let record = try await client.edition(isbn: isbn.isbn13), let workKey = record.workKeys.first {
                edition = record
                doc = try await client.searchWork(key: workKey)
            }
            guard let doc else { throw ImportError.notFound(isbn.isbn13) }
            if try await store.bookExists(key: doc.key) { return .alreadyInLibrary(key: doc.key) }
            return .draft(try await draft(for: doc, isbn: isbn, edition: edition, match: .isbn))
        } catch let error as OpenLibraryError {
            throw ImportError.network(error)
        }
    }

    /// Search-result import: `searchWork(key:)` → work → missing authors.
    /// `.alreadyInLibrary` when the key is a Book already (no request).
    /// Throws `.notFound(key)` when Open Library has no doc for the key.
    func resolve(workKey: String) async throws -> ResolveResult {
        if try await store.bookExists(key: workKey) { return .alreadyInLibrary(key: workKey) }
        do {
            guard let doc = try await client.searchWork(key: workKey) else { throw ImportError.notFound(workKey) }
            if doc.key != workKey, try await store.bookExists(key: doc.key) { return .alreadyInLibrary(key: doc.key) }
            return .draft(try await draft(for: doc, isbn: nil, edition: nil, match: .search))
        } catch let error as OpenLibraryError {
            throw ImportError.network(error)
        }
    }

    /// The work, then only the authors the store does not have (D6).
    private func draft(for doc: OLSearchDoc, isbn: ISBN?, edition: OLEdition?, match: ImportMatch) async throws -> ImportDraft {
        let work = try await client.work(key: doc.key)
        var keys: [String] = []
        for key in (work?.authorKeys.isEmpty == false ? work!.authorKeys : doc.authorKeys) where !keys.contains(key) {
            keys.append(key)
        }
        keys = Array(keys.prefix(Self.maxAuthors))
        let known = try await store.existingAuthorKeys(keys)
        var records: [String: OLAuthor] = [:]
        for key in keys where !known.contains(key) {
            try Task.checkCancellation()
            if let record = try await client.author(key: key) { records[key] = record }
        }
        return ImportDraft.fromOpenLibrary(doc: doc, work: work, authors: records, knownAuthorKeys: known,
                                           isbn: isbn, edition: edition, match: match)
    }
}
