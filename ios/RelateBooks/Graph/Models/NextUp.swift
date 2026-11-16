import Foundation

/// A series the user has started, with the next book of it on the list.
struct SeriesNext: Sendable, Hashable, Identifiable {
    let name: String
    /// Books of the series the user has read.
    let readCount: Int
    /// Books of the series on the list, read or not.
    let listCount: Int
    /// Unread books of the series on the list.
    let unreadCount: Int
    /// The unread book with the lowest position.
    let book: BookSummary
    /// Its position as stored ("4", "1.5"); nil when the series has none.
    let position: String?

    var id: String { name }

    /// "Read 1 of 4 on your list · next is #2"
    var caption: String {
        var text = "Read \(readCount) of \(listCount) on your list"
        if let position { text += " · next is #\(position)" }
        return text
    }
}

/// An author the user rated highly, with their unread books on the list.
struct AuthorNext: Sendable, Hashable, Identifiable {
    /// nil for an author node without a key (never the case for imports).
    let authorKey: String?
    let authorName: String
    /// The best rating the user gave one of the author's books.
    let bestRating: Int
    /// The title that got it.
    let likedTitle: String
    let unreadCount: Int
    /// The first few unread books, by title.
    let books: [BookSummary]

    var id: String { authorKey ?? authorName }

    /// "You rated The Left Hand of Darkness 5"
    var caption: String { "You rated \(likedTitle) \(bestRating)" }
}

/// An unread book that won awards.
struct AwardNext: Sendable, Hashable, Identifiable {
    let book: BookSummary
    let awardCount: Int
    /// How many of those awards a book the user rated highly also won.
    let sharedCount: Int
    /// Up to three award names, the shared ones first.
    let awards: [String]

    var id: String { book.key }

    /// "Hugo Award for Best Novel + 2 more"
    var caption: String {
        guard let first = awards.first else { return "\(awardCount) awards" }
        let more = awardCount - 1
        return more > 0 ? "\(first) + \(more) more" : first
    }
}

/// What to read next, from the graph around what the user has already read
/// and rated. Each list is in the order it is shown.
struct NextUp: Sendable, Hashable {
    var series: [SeriesNext] = []
    var authors: [AuthorNext] = []
    var awards: [AwardNext] = []

    var isEmpty: Bool { series.isEmpty && authors.isEmpty && awards.isEmpty }
}

/// An unread book's setting near a place the user has read about.
struct NearbyReading: Sendable, Hashable, Identifiable {
    /// The place label (one map pin).
    let label: String
    let coordinate: GeoCoordinate
    /// The nearest place a read book is set in; equal to `label` when a
    /// read book is set in this very place.
    let fromLabel: String
    /// A read book set there.
    let readTitle: String
    let meters: Int
    /// Unread books set here.
    let bookCount: Int
    /// The first few, by title.
    let books: [BookSummary]

    var id: String { label }
    var isSamePlace: Bool { label == fromLabel }

    /// "You read River Song, set here" | "120 km from Butte, where River Song is set"
    var caption: String {
        if isSamePlace { return "You read \(readTitle), set here" }
        return "\(Self.distanceText(meters)) from \(fromLabel), where \(readTitle) is set"
    }

    /// Kilometres, to the nearest ten above 100 km: "8 km", "120 km".
    static func distanceText(_ meters: Int) -> String {
        let km = Double(meters) / 1000
        if km < 1 { return "under 1 km" }
        let rounded = km >= 100 ? (km / 10).rounded() * 10 : km.rounded()
        return "\(Int(rounded)) km"
    }
}
