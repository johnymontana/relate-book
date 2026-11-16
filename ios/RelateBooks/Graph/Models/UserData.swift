import Foundation

// User data written by the app (plan §4, phase 2): reading status and dates,
// rating, tags and notes. Decoded from query rows through `Row`.

/// A calendar day with no time zone: `Book.started_on` / `finished_on`
/// (Cypher DATE). It is the user's local day when the change was made.
struct LocalDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar` (and its time zone).
    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// "2026-11-08".
    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The start of that day in `calendar`.
    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    var description: String { iso }

    static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Parses "yyyy-MM-dd"; nil for anything else.
    init?(iso text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }
}

/// The fixed tag palette, stored as the raw string in `Tag.color`. Unknown
/// or missing colours decode as nil and display as gray (not stored, not
/// selectable).
enum TagColor: String, Sendable, Hashable, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// nil for a missing or unknown stored value.
    init?(graphValue: String?) {
        guard let graphValue, let color = TagColor(rawValue: graphValue.lowercased()) else { return nil }
        self = color
    }

    /// A stable colour for a new tag: FNV-1a 32-bit over the lowercased
    /// name's UTF-8, modulo the palette size. (`hashValue` is randomized
    /// per process, so it is not used.)
    static func automatic(for name: String) -> TagColor {
        var hash: UInt32 = 2_166_136_261
        for byte in Array(name.lowercased().utf8) {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return allCases[Int(hash % UInt32(allCases.count))]
    }
}

/// A row of the Tags tab.
struct TagSummary: Sendable, Hashable, Identifiable {
    let name: String
    let color: TagColor?
    let bookCount: Int
    let createdOn: Date?
    var id: String { name }
}

extension TagSummary {
    /// Columns: name, color, createdOn, bookCount.
    init(row: Row) throws {
        self.init(name: try row.requiredString("name"),
                  color: TagColor(graphValue: row.string("color")),
                  bookCount: row.int("bookCount") ?? 0,
                  createdOn: row.instant("createdOn"))
    }
}

/// A tag on one book.
struct BookTag: Sendable, Hashable, Identifiable {
    let name: String
    let color: TagColor?
    /// `TAGGED.on`; nil in an optimistic (not yet written) value.
    let taggedOn: Date?
    var id: String { name }
}

extension BookTag {
    /// Columns: name, color, and `taggedOn` (tagsForBook) or `on` (maps
    /// collected in the detail and user-data queries).
    init(row: Row) throws {
        self.init(name: try row.requiredString("name"),
                  color: TagColor(graphValue: row.string("color")),
                  taggedOn: row.instant("taggedOn") ?? row.instant("on"))
    }

    /// Picker and chip order: name, case-insensitive, then exact name.
    static func sorted(_ tags: [BookTag]) -> [BookTag] {
        tags.sorted { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
    }
}

/// A plain-text, multi-line note on a book.
struct BookNote: Sendable, Hashable, Identifiable {
    let id: String
    let text: String
    let createdOn: Date
    let updatedOn: Date
    var wasEdited: Bool { updatedOn > createdOn }
}

extension BookNote {
    /// Columns: id, text, createdOn, updatedOn; all required.
    init(row: Row) throws {
        guard let created = row.instant("createdOn") else { throw GraphError.missingColumn("createdOn") }
        guard let updated = row.instant("updatedOn") else { throw GraphError.missingColumn("updatedOn") }
        guard let text = row["text"].stringValue else { throw GraphError.missingColumn("text") }
        self.init(id: try row.requiredString("id"), text: text, createdOn: created, updatedOn: updated)
    }

    /// Newest first: updatedOn desc, createdOn desc, id.
    static func sorted(_ notes: [BookNote]) -> [BookNote] {
        notes.sorted { a, b in
            if a.updatedOn != b.updatedOn { return a.updatedOn > b.updatedOn }
            if a.createdOn != b.createdOn { return a.createdOn > b.createdOn }
            return a.id < b.id
        }
    }
}

/// Everything the user wrote about one book.
struct BookUserData: Sendable, Hashable {
    var key: String
    var status: ReadingStatus
    var rating: Int?
    var startedOn: LocalDay?
    var finishedOn: LocalDay?
    var statusChangedOn: Date?
    var tags: [BookTag]
    var notes: [BookNote]

    init(key: String, status: ReadingStatus = .want, rating: Int? = nil, startedOn: LocalDay? = nil,
         finishedOn: LocalDay? = nil, statusChangedOn: Date? = nil, tags: [BookTag] = [], notes: [BookNote] = []) {
        self.key = key
        self.status = status
        self.rating = rating
        self.startedOn = startedOn
        self.finishedOn = finishedOn
        self.statusChangedOn = statusChangedOn
        self.tags = tags
        self.notes = notes
    }

    /// Columns: key, status, myRating, startedOn, finishedOn,
    /// statusChangedOn, tags (maps name/color/on), notes (maps
    /// id/text/createdOn/updatedOn).
    init(row: Row) throws {
        self.init(
            key: try row.requiredString("key"),
            status: ReadingStatus(graphValue: row.string("status")),
            rating: row.int("myRating"),
            startedOn: row.day("startedOn"),
            finishedOn: row.day("finishedOn"),
            statusChangedOn: row.instant("statusChangedOn"),
            tags: BookTag.sorted(try row.rows("tags").map(BookTag.init(row:))),
            notes: BookNote.sorted(try row.rows("notes").map(BookNote.init(row:))))
    }

    /// The dates the UI shows for the current status: want shows none,
    /// reading shows Started, read shows Started (if any) and Finished.
    /// Dates of earlier statuses stay stored as history.
    var visibleDates: (started: LocalDay?, finished: LocalDay?) {
        switch status {
        case .want: (nil, nil)
        case .reading: (startedOn, nil)
        case .read: (startedOn, finishedOn)
        }
    }

    /// "Started Nov 1, 2026 · Finished Nov 8, 2026"; nil when nothing is visible.
    func datesLine(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        func text(_ day: LocalDay?) -> String? {
            guard let day else { return nil }
            return day.date(in: calendar).map { $0.formatted(style) } ?? day.iso
        }
        let (started, finished) = visibleDates
        let parts = [text(started).map { "Started \($0)" }, text(finished).map { "Finished \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum UserDataError: Error, Equatable, LocalizedError {
    case bookNotFound(String)
    case emptyTagName
    case tagNameTooLong
    case tagNameTaken(String)
    case tagNotFound(String)
    case emptyNote
    case noteNotFound(String)
    case invalidRating(Int)

    var errorDescription: String? {
        switch self {
        case .bookNotFound: "That book is no longer in the library"
        case .emptyTagName: "Tag names can't be empty"
        case .tagNameTooLong: "Tag names are limited to \(TagName.maxLength) characters"
        case .tagNameTaken(let name): "A tag named “\(name)” already exists"
        case .tagNotFound(let name): "The tag “\(name)” no longer exists"
        case .emptyNote: "Notes can't be empty"
        case .noteNotFound: "That note no longer exists"
        case .invalidRating: "Ratings are 1 to 5 stars"
        }
    }
}

enum TagName {
    static let maxLength = 40

    /// Trimmed, Unicode NFC; 1...40 characters. NFC matters because Cypher's
    /// `toLower(a) = toLower(b)` compares code points while Swift's `==` uses
    /// canonical equivalence, so a pasted NFD "Été" would otherwise create a
    /// second Tag that Swift then treats as the same id.
    static func normalize(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        if name.isEmpty { throw UserDataError.emptyTagName }
        if name.count > maxLength { throw UserDataError.tagNameTooLong }
        return name
    }
}

enum NoteText {
    /// Trimmed of leading and trailing whitespace and newlines; inner
    /// newlines are kept. All-whitespace text is refused.
    static func normalize(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw UserDataError.emptyNote }
        return text
    }
}
