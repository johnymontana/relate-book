import Foundation

/// Library list ordering. Ties always break on lowercased title, then key.
enum LibrarySort: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Lowercased Book.title, A to Z.
    case title
    /// Author surname (last word of the name, skipping Jr./III/PhD), A to Z; with
    /// several authors the alphabetically smallest surname counts. No author last.
    case author
    /// Wishlist order: smallest `CONTAINS.position` of the book's items.
    case wishlist
    /// Open Library rating, high to low; unrated last.
    case rating
    /// First publish year, newest first; undated last.
    case year
    /// `Book.status_changed_on`, newest first: books whose reading status
    /// the user changed most recently. Only status changes count (rating,
    /// tag and note edits do not move a book). Never-changed books come
    /// last, in title order.
    case recentlyUpdated = "recent"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .wishlist: "Wishlist order"
        case .rating: "Open Library rating"
        case .year: "Publish year"
        case .recentlyUpdated: "Recently updated"
        }
    }
}

/// The library's active filters. Value type: the view model owns one and
/// `LibraryQueries` turns it into a parameterized statement.
struct LibraryFilter: Sendable, Hashable {
    var status: ReadingStatus?
    /// `Item.format`, matched exactly against any of the book's items.
    var format: String?
    /// `Genre.name`.
    var genre: String?
    /// `Tag.name` (exact; tags are case-insensitively unique).
    var tag: String?
    /// Only books whose key starts with `amazon:` (not resolved in Open Library).
    var unresolvedOnly = false
    /// Search-as-you-type text, matched case-insensitively against the book
    /// title, its authors' names and its items' (English Amazon) titles.
    var text = ""

    init(status: ReadingStatus? = nil, format: String? = nil, genre: String? = nil, tag: String? = nil,
         unresolvedOnly: Bool = false, text: String = "") {
        self.status = status
        self.format = format
        self.genre = genre
        self.tag = tag
        self.unresolvedOnly = unresolvedOnly
        self.text = text
    }

    /// Search starts at this many characters: one letter matches nearly
    /// every book ("a": 1,792 of 1,811) and is the slowest query shape.
    static let minimumSearchLength = 2

    /// Lowercased, trimmed search text; nil when shorter than `minimumSearchLength`.
    var normalizedText: String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.count < Self.minimumSearchLength ? nil : t
    }

    /// Number of active chip filters (text excluded).
    var activeCount: Int {
        (status == nil ? 0 : 1) + (format == nil ? 0 : 1) + (genre == nil ? 0 : 1) + (tag == nil ? 0 : 1)
            + (unresolvedOnly ? 1 : 0)
    }

    var isEmpty: Bool { activeCount == 0 && normalizedText == nil }
}

/// One filter-chip value with the number of books it matches.
struct FacetValue: Sendable, Hashable, Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}
