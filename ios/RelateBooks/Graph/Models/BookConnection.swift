import Foundation

/// The kinds of node two books can share, strongest first. A connection is
/// one such node: `(book)-[rel]->(shared)<-[rel]-(other book)`.
///
/// Each kind has a fixed relationship type (never user input), so it is safe
/// to splice into Cypher. Genres are left out on purpose: there are a
/// handful, each on a large part of the library, so sharing one says little.
enum ConnectionKind: String, Sendable, Hashable, CaseIterable {
    case series, author, award, person, place, subject, era

    var relationship: String {
        switch self {
        case .series: "PART_OF"
        case .author: "WRITTEN_BY"
        case .award: "WON"
        case .person: "FEATURES"
        case .place: "SET_IN"
        case .subject: "ABOUT"
        case .era: "SET_DURING"
        }
    }

    /// How much a shared node of this kind counts before rarity: a link's
    /// weight is `strength / degree`, the degree being the number of books
    /// on the shared node.
    var strength: Double {
        switch self {
        case .series: 4
        case .author: 3
        case .award: 2
        case .person: 1.5
        case .place, .subject: 1
        case .era: 0.5
        }
    }

    init?(relationship: String) {
        guard let kind = ConnectionKind.allCases.first(where: { $0.relationship == relationship }) else { return nil }
        self = kind
    }

    var systemImage: String {
        switch self {
        case .series: "square.stack.3d.up"
        case .author: "person"
        case .award: "rosette"
        case .person: "person.crop.square"
        case .place: "mappin.and.ellipse"
        case .subject: "tag"
        case .era: "clock"
        }
    }

    /// The term page of the shared node (an author has its own page, by key).
    var termKind: TermKind? {
        switch self {
        case .series: .series
        case .award: .award
        case .person: .person
        case .place: .place
        case .subject: .subject
        case .era: .era
        case .author: nil
        }
    }
}

/// One shared node between a book and another book.
struct BookConnection: Sendable, Hashable {
    let kind: ConnectionKind
    /// The shared node's name (a series, an author, a subject, …).
    let name: String
    /// The book at the other end.
    let otherKey: String
    let otherTitle: String
    /// `strength / degree`, possibly scaled by the query that found it.
    let weight: Double

    /// The link with the other book named: "Same series as The Dispossessed".
    var phrase: String {
        switch kind {
        case .series: "Same series as \(otherTitle)"
        case .author: "By \(name), like \(otherTitle)"
        case .award: "Won the \(name), like \(otherTitle)"
        case .person: "Features \(name), like \(otherTitle)"
        case .place: "Set in \(name), like \(otherTitle)"
        case .subject: "Shares “\(name)” with \(otherTitle)"
        case .era: "Set during \(name), like \(otherTitle)"
        }
    }

    /// The link where the other book is already on screen: "Both set in Gethen".
    var shortPhrase: String {
        switch kind {
        case .series: "Same series"
        case .author: "Same author"
        case .award: "Both won the \(name)"
        case .person: "Both feature \(name)"
        case .place: "Both set in \(name)"
        case .subject: "Both about \(name)"
        case .era: "Both set during \(name)"
        }
    }

    init(kind: ConnectionKind, name: String, otherKey: String, otherTitle: String, weight: Double = 0) {
        self.kind = kind
        self.name = name
        self.otherKey = otherKey
        self.otherTitle = otherTitle
        self.weight = weight
    }

    /// A map with `via` (relationship type), `name`, `otherKey`,
    /// `otherTitle` and the link's weight in `weightColumn`; nil when a
    /// field is missing or the relationship is not a connection kind.
    init?(row: Row, weightColumn: String = "weight") {
        guard let via = row.string("via"), let kind = ConnectionKind(relationship: via),
              let name = row.string("name"), let otherKey = row.string("otherKey") else { return nil }
        self.init(kind: kind, name: name, otherKey: otherKey, otherTitle: row.string("otherTitle") ?? otherKey,
                  weight: row.double(weightColumn) ?? 0)
    }
}

/// A connection to a book the user has read, is reading or rated highly:
/// why a book they have not read may matter to them.
struct ReadingConnection: Sendable, Hashable, Identifiable {
    let connection: BookConnection
    /// The other book's status and rating.
    let status: ReadingStatus
    let rating: Int?

    var id: String { "\(connection.kind.rawValue)|\(connection.name)|\(connection.otherKey)" }

    /// "Same series as The Dispossessed, which you rated 5".
    var phrase: String { "\(connection.phrase), \(Self.clause(status: status, rating: rating))" }

    static func clause(status: ReadingStatus, rating: Int?) -> String {
        if let rating { return "which you rated \(rating)" }
        switch status {
        case .read: return "which you read"
        case .reading: return "which you’re reading"
        case .want: return "which is on your list"
        }
    }

    init(connection: BookConnection, status: ReadingStatus, rating: Int?) {
        self.connection = connection
        self.status = status
        self.rating = rating
    }

    init?(row: Row) {
        guard let connection = BookConnection(row: row) else { return nil }
        self.init(connection: connection, status: ReadingStatus(graphValue: row.string("status")), rating: row.int("rating"))
    }
}

/// A book reached from a top search hit through the graph (the fourth
/// candidate list of hybrid search).
struct RelatedCandidate: Sendable, Hashable {
    let key: String
    /// Summed link weights, each divided by the seed's position.
    let weight: Double
    /// The strongest link; its other book is the seed.
    let connection: BookConnection
}
