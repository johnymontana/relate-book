import Foundation

/// A validated ISBN, held as ISBN-13 (D-D). ISBN-10 input is converted.
///
/// Equality and hashing use `isbn13` only; `enteredAsISBN10` just records
/// how it was typed (for the "Valid ISBN-10 (978…)" message).
struct ISBN: Sendable, Hashable, CustomStringConvertible {
    let isbn13: String
    /// True when the text was a valid ISBN-10.
    let enteredAsISBN10: Bool

    /// The ISBN-10 form for 978 ISBNs; nil for 979.
    var isbn10: String? { Self.isbn10(from13: isbn13) }
    var description: String { isbn13 }

    private init(isbn13: String, enteredAsISBN10: Bool) {
        self.isbn13 = isbn13
        self.enteredAsISBN10 = enteredAsISBN10
    }

    /// Accepts 10 or 13 characters after removing spaces and hyphens
    /// (a lowercase x is accepted as the ISBN-10 check digit); nil unless valid.
    init?(_ text: String) {
        let s = Self.compact(text)
        if s.count == 13, Self.isValid13(s) {
            self.init(isbn13: s, enteredAsISBN10: false)
        } else if s.count == 10, Self.isValid10(s), let thirteen = Self.isbn13(from10: s) {
            self.init(isbn13: thirteen, enteredAsISBN10: true)
        } else {
            return nil
        }
    }

    static func == (a: ISBN, b: ISBN) -> Bool { a.isbn13 == b.isbn13 }
    func hash(into hasher: inout Hasher) { hasher.combine(isbn13) }

    /// A scanned barcode payload: an EAN-13 starting 978/979 with a valid
    /// check digit. EAN-8, UPC-A/E, other EAN-13 and non-digits → nil.
    static func fromBarcode(_ payload: String) -> ISBN? {
        let s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid13(s) else { return nil }
        return ISBN(isbn13: s, enteredAsISBN10: false)
    }

    /// `^97[89]\d{10}$` with a valid EAN-13 check digit (the extension's `is_isbn13`).
    static func isValid13(_ s: String) -> Bool {
        guard s.count == 13, s.hasPrefix("978") || s.hasPrefix("979") else { return false }
        let digits = s.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        guard digits.count == 13 else { return false }
        let total = digits.prefix(12).enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return (10 - total % 10) % 10 == digits[12]
    }

    /// `^\d{9}[\dX]$` with a valid mod-11 check digit (the extension's
    /// `is_isbn10`; a lowercase x is accepted).
    static func isValid10(_ s: String) -> Bool {
        let chars = Array(s.uppercased())
        guard chars.count == 10 else { return false }
        var total = 0
        for (i, c) in chars.enumerated() {
            let value: Int
            if let d = c.isASCII ? c.wholeNumberValue : nil {
                value = d
            } else if c == "X" && i == 9 {
                value = 10
            } else {
                return false
            }
            total += (10 - i) * value
        }
        return total % 11 == 0
    }

    /// The extension's `isbn10_to_13`; nil when `s` is not a valid ISBN-10.
    static func isbn13(from10 s: String) -> String? {
        guard isValid10(s) else { return nil }
        let body = "978" + s.prefix(9)
        let digits = body.compactMap(\.wholeNumberValue)
        let total = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return body + String((10 - total % 10) % 10)
    }

    /// 978 ISBN-13s only; nil otherwise (979 has no ISBN-10 form).
    static func isbn10(from13 s: String) -> String? {
        guard isValid13(s), s.hasPrefix("978") else { return nil }
        let body = String(s.dropFirst(3).prefix(9))
        let digits = body.compactMap(\.wholeNumberValue)
        let total = digits.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) }
        let check = (11 - total % 11) % 11
        return body + (check == 10 ? "X" : String(check))
    }

    /// Inline feedback for the typed field.
    static func validate(_ text: String) -> ISBNValidation {
        let s = compact(text)
        if s.isEmpty { return .empty }
        guard s.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "X" || $0 == "x" }) else { return .notISBN }
        let hasX = s.contains { $0 == "X" || $0 == "x" }
        switch s.count {
        case 13:
            if hasX || !(s.hasPrefix("978") || s.hasPrefix("979")) { return .notISBN }
            return ISBN(s).map(ISBNValidation.valid) ?? .badChecksum
        case 10:
            if hasX, !(s.last == "X" || s.last == "x") { return .notISBN }
            return ISBN(s).map(ISBNValidation.valid) ?? .badChecksum
        default:
            return .incomplete(digits: s.count)
        }
    }

    /// Spaces and hyphens removed (also non-breaking spaces and en dashes).
    static func compact(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{2010}" && $0 != "\u{2013}" })
    }
}

/// Inline feedback for the typed ISBN field (D32).
enum ISBNValidation: Equatable, Sendable {
    /// Nothing typed: no message.
    case empty
    /// Fewer than 10, 11-12, or more than 13 characters.
    case incomplete(digits: Int)
    /// 10 or 13 characters with a bad check digit.
    case badChecksum
    /// Anything but digits / X / spaces / hyphens, or 13 digits not 978/979.
    case notISBN
    case valid(ISBN)

    var message: String? {
        switch self {
        case .empty: nil
        case .incomplete: "ISBN has 10 or 13 digits"
        case .badChecksum: "Check digit doesn't match"
        case .notISBN: "Not an ISBN (book ISBNs start 978 or 979)"
        case .valid(let isbn): isbn.enteredAsISBN10 ? "Valid ISBN-10 (\(isbn.isbn13))" : "Valid ISBN-13"
        }
    }

    var isbn: ISBN? {
        if case .valid(let isbn) = self { return isbn }
        return nil
    }

    var isValid: Bool { isbn != nil }
}
