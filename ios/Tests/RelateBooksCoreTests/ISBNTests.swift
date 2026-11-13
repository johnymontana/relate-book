import Testing
import Foundation
@testable import RelateBooksCore

@Suite("ISBN")
struct ISBNTests {
    @Test("ISBN-13 and ISBN-10 check digits (the extension's is_isbn13 / is_isbn10)")
    func checkDigits() {
        #expect(ISBN.isValid13("9780393337013"))
        #expect(!ISBN.isValid13("9780393337014"))
        #expect(!ISBN.isValid13("4006381333931"))   // valid EAN, not 978/979
        #expect(ISBN.isValid10("0393337014"))
        #expect(!ISBN.isValid10("039333701X"))
        #expect(ISBN.isValid10("080442957X"))
        #expect(ISBN.isValid10("080442957x"))
        #expect(!ISBN.isValid10("X804429570"))
    }

    @Test("10 ↔ 13 conversion")
    func conversion() {
        #expect(ISBN.isbn13(from10: "0393337014") == "9780393337013")
        #expect(ISBN.isbn10(from13: "9780393337013") == "0393337014")
        #expect(ISBN.isbn10(from13: "9780804429573") == "080442957X")
        #expect(ISBN.isbn13(from10: ISBN.isbn10(from13: "9780593135204")!) == "9780593135204")
        #expect(ISBN.isbn10(from13: "9798999999993") == nil)
        #expect(ISBN.isbn13(from10: "039333701X") == nil)
    }

    @Test("parsing typed text: hyphens, spaces, lowercase x")
    func parsing() throws {
        #expect(ISBN("978-0-393-33701-3")?.isbn13 == "9780393337013")
        let ten = try #require(ISBN(" 0 393 33701 4 "))
        #expect(ten.isbn13 == "9780393337013" && ten.isbn10 == "0393337014" && ten.enteredAsISBN10)
        #expect(ISBN("080442957x")?.isbn13 == "9780804429573")
        #expect(ISBN("12345") == nil)
        #expect(ISBN("9780393337014") == nil)
        #expect(ISBN("9798999999993")?.isbn10 == nil)
        // Equality is by ISBN-13, however it was typed.
        #expect(ISBN("0393337014") == ISBN("9780393337013"))
    }

    @Test("barcodes: only EAN-13 978/979 with a valid check digit")
    func barcodes() {
        #expect(ISBN.fromBarcode("9780393337013")?.isbn13 == "9780393337013")
        #expect(ISBN.fromBarcode("9798999999993") != nil)
        #expect(ISBN.fromBarcode("4006381333931") == nil)   // a non-book EAN-13
        #expect(ISBN.fromBarcode("96385074") == nil)        // EAN-8
        #expect(ISBN.fromBarcode("012345678905") == nil)    // UPC-A
        #expect(ISBN.fromBarcode("978039333701") == nil)
        #expect(ISBN.fromBarcode("97803933370AB") == nil)
    }

    @Test("validation states and messages (D32)")
    func validation() {
        #expect(ISBN.validate("") == .empty && ISBN.validate("  ").message == nil)
        #expect(ISBN.validate("97803") == .incomplete(digits: 5))
        #expect(ISBN.validate("97803").message == "ISBN has 10 or 13 digits")
        #expect(ISBN.validate("978039333701") == .incomplete(digits: 12))
        #expect(ISBN.validate("9780393337014") == .badChecksum)
        #expect(ISBN.validate("9780393337014").message == "Check digit doesn't match")
        #expect(ISBN.validate("0393337015") == .badChecksum)
        #expect(ISBN.validate("978-0-393-3370a-3") == .notISBN)
        #expect(ISBN.validate("4006381333931") == .notISBN)
        #expect(ISBN.validate("4006381333931").message != nil)
        let valid = ISBN.validate("978-0-393-33701-3")
        #expect(valid.isbn?.isbn13 == "9780393337013")
        #expect(valid.message == "Valid ISBN-13")
        #expect(ISBN.validate("0393337014").message == "Valid ISBN-10 (9780393337013)")
        #expect(ISBN.validate("0393337014").isValid)
    }
}
