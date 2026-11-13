/// The facet node kinds a book links to by `name`. Each has a fixed label
/// and relationship (never user input), so they are safe to splice into
/// Cypher; the name is always a parameter.
enum TermKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case subject, genre, series, place, person, era, publisher, award, country

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subject: "Subject"
        case .genre: "Genre"
        case .series: "Series"
        case .place: "Place"
        case .person: "Person"
        case .era: "Era"
        case .publisher: "Publisher"
        case .award: "Award"
        case .country: "Country"
        }
    }

    /// The `(b:Book)…(t)` pattern that links a book to the term node `t`.
    var bookPattern: String {
        switch self {
        case .subject: "(b:Book)-[:ABOUT]->(t:Subject {name: $name})"
        case .genre: "(b:Book)-[:IN_GENRE]->(t:Genre {name: $name})"
        case .series: "(b:Book)-[:PART_OF]->(t:Series {name: $name})"
        case .place: "(b:Book)-[:SET_IN]->(t:Place {name: $name})"
        case .person: "(b:Book)-[:FEATURES]->(t:Person {name: $name})"
        case .era: "(b:Book)-[:SET_DURING]->(t:Era {name: $name})"
        case .publisher: "(b:Book)-[:PUBLISHED_BY]->(t:Publisher {name: $name})"
        case .award: "(b:Book)-[:WON]->(t:Award {name: $name})"
        // Countries link to authors, so a country's books are its citizens' books.
        case .country: "(b:Book)-[:WRITTEN_BY]->(:Author)-[:CITIZEN_OF]->(t:Country {name: $name})"
        }
    }

    /// The `(a:Author)…(t)` pattern for kinds that also link authors.
    var authorPattern: String? {
        switch self {
        case .place: "(a:Author)-[:BORN_IN]->(t:Place {name: $name})"
        case .country: "(a:Author)-[:CITIZEN_OF]->(t:Country {name: $name})"
        case .award: "(a:Author)-[:WON]->(t:Award {name: $name})"
        default: nil
        }
    }

    /// Heading for the author section on the term page.
    var authorSectionTitle: String {
        switch self {
        case .place: "Authors born here"
        case .country: "Citizens"
        case .award: "Authors who won"
        default: "Authors"
        }
    }

    /// Sorted books on the term page: series in reading order.
    var ordersBySeriesPosition: Bool { self == .series }
}

/// Header facts for a term page.
struct TermSummary: Sendable, Hashable {
    let kind: TermKind
    let name: String
    let bookCount: Int
    let authorCount: Int
}
