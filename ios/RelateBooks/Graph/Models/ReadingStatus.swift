/// `Book.reading_status`. A missing value means `.want` (phase 2 writes it;
/// phase 1 only displays and filters on it).
enum ReadingStatus: String, Sendable, Hashable, CaseIterable, Identifiable {
    case want, reading, read

    var id: String { rawValue }

    init(graphValue: String?) {
        self = graphValue.flatMap(ReadingStatus.init(rawValue:)) ?? .want
    }

    var label: String {
        switch self {
        case .want: "Want to read"
        case .reading: "Reading"
        case .read: "Read"
        }
    }

    var shortLabel: String {
        switch self {
        case .want: "Want"
        case .reading: "Reading"
        case .read: "Read"
        }
    }
}
