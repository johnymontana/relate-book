import XCTest

/// Phase 5 "Add books" on the simulator (spec B.9). Every test launches with
/// `--reset-user-data --stub-network` (D35): the reset deletes app-added
/// books from earlier runs, and the stub serves canned Open Library
/// responses for The Perfect Storm (ISBN 9780393337013) plus a stub
/// geocoder, so nothing here depends on openlibrary.org, Apple's geocoder
/// or the camera. Covers still load from covers.openlibrary.org when the
/// Mac has network; no assertion depends on them.
///
/// Runs first (alphabetical). The typed-ISBN test is last in the class and
/// ends with a reset relaunch, so later classes see the pristine store.
final class AddBookUITests: XCTestCase {
    static let fixtureISBN = "9780393337013"
    static let fixtureTitle = "The Perfect Storm"

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-user-data", "--stub-network"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    /// Library → "+" → the given mode.
    @MainActor
    private func openAddBook(_ app: XCUIApplication, mode: String? = nil) {
        let add = app.buttons["library.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 30), "Library + button missing")
        add.tap()
        let picker = app.segmentedControls["addBook.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Add Book mode picker missing")
        if let mode {
            // No isSelected check: with --simulate-scan the Scan segment can
            // finish (and leave the screen) before the query runs.
            picker.buttons[mode].tap()
        }
    }

    @MainActor
    private func typeISBN(_ app: XCUIApplication, _ isbn: String) {
        let field = app.textFields["addBook.isbn.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "ISBN field missing")
        field.tap()
        field.typeText(isbn)
        let message = app.staticTexts["addBook.isbn.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "no ISBN validation line")
        XCTAssertEqual(message.label, "Valid ISBN-13")
    }

    /// Waits for `element`, swiping the list up (at most 5 times) while it
    /// is not on screen: List rows below the fold do not exist yet.
    @MainActor
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        if element.waitForExistence(timeout: timeout), element.isHittable { return true }
        for _ in 0..<5 {
            app.swipeUp(velocity: .slow)
            if element.waitForExistence(timeout: 2), element.isHittable { return true }
        }
        return element.exists
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ format: String, _ args: [Any] = [],
                              timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args),
                                                    object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The Library search field (Library tab, root of the stack).
    @MainActor
    private func librarySearch(_ app: XCUIApplication, _ text: String) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Library search field missing")
        search.tap()
        search.typeText(text)
    }

    /// Ends the Library search (the active search field hides the "+" and
    /// its keyboard covers the tab bar).
    @MainActor
    private func endLibrarySearch(_ app: XCUIApplication) {
        let close = app.navigationBars["Library"].buttons.matching(
            NSPredicate(format: "label IN {'Close', 'Cancel'}")).firstMatch
        if close.exists { close.tap() }
    }

    @MainActor
    private func libraryRow(_ app: XCUIApplication, beginsWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: Tests

    /// A local ISBN match (Project Hail Mary's Item.isbn13) opens the
    /// existing book with "Already in your library"; no Open Library request.
    @MainActor
    func testAlreadyInLibraryOpensExistingBook() throws {
        let app = launch()
        openAddBook(app, mode: "Scan")
        XCTAssertTrue(el(app, "addBook.scanner.unavailable").waitForExistence(timeout: 5),
                      "the simulator should show the camera-unavailable view")
        typeISBN(app, "9780593135211")
        app.buttons["addBook.isbn.submit"].tap()

        XCTAssertTrue(app.navigationBars["Project Hail Mary"].waitForExistence(timeout: 20),
                      "Project Hail Mary did not open")
        let notice = el(app, "book.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Already in your library")
        Thread.sleep(forTimeInterval: 1.5)   // cover
        saveScreenshot("phase5-already", app)
        XCTAssertTrue(reveal(app, app.buttons["Open on Amazon"].firstMatch, timeout: 3),
                      "the existing book's Amazon item is missing")
        XCTAssertFalse(el(app, "book.addedInApp").exists)
    }

    /// Manual entry: title + two authors (one of them an existing byline
    /// author); the book shows in Book detail and the Library.
    @MainActor
    func testManualEntry() throws {
        let app = launch()
        openAddBook(app, mode: "Manual")
        let title = app.textFields["addBook.manual.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Field Notes from the Bitterroot")
        let authors = app.textFields["addBook.manual.authors"]
        authors.tap()
        authors.typeText("Jane Doe, Rana Foroohar")
        let submit = app.buttons["addBook.manual.submit"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        XCTAssertTrue(app.navigationBars["Field Notes from the Bitterroot"].waitForExistence(timeout: 20),
                      "the manual book's detail did not open")
        let notice = el(app, "book.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Added to your library")
        let added = el(app, "book.addedInApp")
        XCTAssertTrue(reveal(app, added), "Added in app section missing")
        XCTAssertTrue(added.label.contains("entered manually"), added.label)
        saveScreenshot("phase5-manual", app)   // notice + Added in app, before scrolling
        for name in ["Jane Doe", "Rana Foroohar"] {
            // Author rows (NavigationLink + LabeledContent) expose their name
            // as a static text, not as the button label.
            let author = app.descendants(matching: .any).matching(
                NSPredicate(format: "(elementType == %d OR elementType == %d) AND label == %@",
                            XCUIElement.ElementType.staticText.rawValue,
                            XCUIElement.ElementType.button.rawValue, name)).firstMatch
            var found = author.waitForExistence(timeout: 3)
            for _ in 0..<5 where !found {   // the Authors section is below the fold
                app.swipeUp(velocity: .slow)
                found = author.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(found, "author row \(name) missing")
        }

        goBack(app)
        librarySearch(app, "bitterroot")
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Field Notes from the Bitterroot' AND label CONTAINS 'Added in app'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the manual book is not in the Library")
    }

    /// Open Library search → confirm → import (match 'search': no edition facts, D8).
    @MainActor
    func testSearchResultImport() throws {
        let app = launch()
        openAddBook(app)   // Search is the default mode
        XCTAssertTrue(el(app, "addBook.search.hint").waitForExistence(timeout: 5))
        let field = app.textFields["addBook.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("perfect storm")
        let first = app.buttons["addBook.result.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "no Open Library results")
        XCTAssertTrue(first.label.hasPrefix(Self.fixtureTitle), first.label)
        XCTAssertFalse(first.label.contains("In your library"), first.label)
        Thread.sleep(forTimeInterval: 2)   // covers (network only; not asserted)
        saveScreenshot("phase5-add-search", app)

        first.tap()
        let confirm = app.buttons["addBook.confirm"].firstMatch   // label "Add to Library"
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog missing")
        XCTAssertEqual(confirm.label, "Add to Library")
        confirm.tap()

        XCTAssertTrue(app.navigationBars[Self.fixtureTitle].waitForExistence(timeout: 45),
                      "The Perfect Storm did not open after the search import")
        let added = el(app, "book.addedInApp")
        XCTAssertTrue(reveal(app, added), "Added in app section missing")
        XCTAssertTrue(added.label.contains("Open Library search"), added.label)
        XCTAssertFalse(added.label.contains("ISBN"), "a search import must not show an ISBN: \(added.label)")

        goBack(app)
        librarySearch(app, "perfect storm")
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS 'Added in app'", Self.fixtureTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the search import is not in the Library")
    }

    /// The scanned-barcode path (D28): `--simulate-scan` feeds the payload
    /// through the Scan section's `onPayload` handler, the one the camera
    /// calls. Then the same book again: by scan, and from a search result
    /// marked "In your library", both open the existing book.
    @MainActor
    func testSimulatedScanAddsBook() throws {
        let app = launch(["--simulate-scan", Self.fixtureISBN])
        openAddBook(app, mode: "Scan")

        XCTAssertTrue(app.navigationBars[Self.fixtureTitle].waitForExistence(timeout: 45),
                      "the simulated scan did not import The Perfect Storm")
        let notice = el(app, "book.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Added to your library")
        let added = el(app, "book.addedInApp")
        XCTAssertTrue(reveal(app, added), "Added in app section missing")
        XCTAssertTrue(added.label.contains("ISBN scan"), added.label)
        XCTAssertTrue(added.label.contains("ISBN \(Self.fixtureISBN)"), added.label)

        goBack(app)
        librarySearch(app, "perfect storm")
        XCTAssertTrue(libraryRow(app, beginsWith: Self.fixtureTitle).waitForExistence(timeout: 10),
                      "the scanned book is not in the Library")
        endLibrarySearch(app)

        // The same barcode again: the local ISBN match finds the new book.
        openAddBook(app, mode: "Scan")
        XCTAssertTrue(app.navigationBars[Self.fixtureTitle].waitForExistence(timeout: 20),
                      "the second scan did not open The Perfect Storm")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Already in your library")
        saveScreenshot("phase5-already-fixture", app)
        XCTAssertTrue(reveal(app, el(app, "book.addedInApp")))

        // And from Open Library search: the row is badged and opens the book.
        goBack(app)
        openAddBook(app)
        let field = app.textFields["addBook.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("perfect storm")
        let first = app.buttons["addBook.result.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "no Open Library results")
        XCTAssertTrue(waitForLabel(first, "label CONTAINS 'In your library'", timeout: 5),
                      "the imported work is not badged: \(first.label)")
        first.tap()
        XCTAssertTrue(app.navigationBars[Self.fixtureTitle].waitForExistence(timeout: 15))
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Already in your library")
        XCTAssertFalse(app.buttons["addBook.confirm"].exists, "a book in the library needs no confirmation")
    }

    /// The acceptance flow (§8 row 5): a typed ISBN is imported and then
    /// appears in the Library, in Search (keyword and, after the incremental
    /// embed, semantically) and on the Map. Ends with the reset proof.
    @MainActor
    func testTypedISBNAddsBookToLibrarySearchAndMap() throws {
        var app = launch()

        // 1. Scan mode, typed ISBN.
        openAddBook(app, mode: "Scan")
        XCTAssertTrue(el(app, "addBook.scanner.unavailable").waitForExistence(timeout: 5))
        typeISBN(app, Self.fixtureISBN)
        saveScreenshot("phase5-add-scan", app)

        // 2. Look Up; the progress card when it shows in time (best effort).
        let t0 = Date()
        app.buttons["addBook.isbn.submit"].tap()
        if el(app, "addBook.progress").waitForExistence(timeout: 2) {
            saveScreenshot("phase5-importing", app)
        }

        // 3. Book detail.
        XCTAssertTrue(app.navigationBars[Self.fixtureTitle].waitForExistence(timeout: 45),
                      "The Perfect Storm did not open after the ISBN import")
        let seconds = Date().timeIntervalSince(t0)
        let line = "PHASE5_IMPORT_SECONDS=\(String(format: "%.1f", seconds))"
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "import-seconds"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 4. Notice and the Added in app section.
        let notice = el(app, "book.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Added to your library")
        let added = el(app, "book.addedInApp")
        XCTAssertTrue(reveal(app, added), "Added in app section missing")
        XCTAssertTrue(added.label.contains("ISBN scan"), added.label)
        XCTAssertTrue(added.label.contains("ISBN \(Self.fixtureISBN)"), added.label)
        print("PHASE5_ADDED_IN_APP=\(added.label)")
        Thread.sleep(forTimeInterval: 2)   // cover (network only)
        saveScreenshot("phase5-added-detail", app)

        // 5. Library.
        goBack(app)
        librarySearch(app, "perfect storm")
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS 'Added in app'", Self.fixtureTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the new book is not in the Library")
        Thread.sleep(forTimeInterval: 1.5)
        saveScreenshot("phase5-library", app)
        endLibrarySearch(app)

        // 6. Search: keyword at once; semantic once the incremental embed has
        //    written the vector (the reason reads "Semantic 0.xx + keyword").
        app.tabBars.buttons["Search"].tap()
        let searchField = app.textFields["search.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))
        var hit: XCUIElement?
        var reasons: [String] = []
        let deadline = Date().addingTimeInterval(60)
        repeat {
            if el(app, "search.clear").exists { el(app, "search.clear").tap() }
            searchField.tap()
            searchField.typeText("perfect storm\n")
            XCTAssertTrue(app.buttons["search.result.0"].waitForExistence(timeout: 20), "no search results")
            let rows = (0..<3).map { app.buttons["search.result.\($0)"] }.filter { $0.exists }
            reasons = rows.map(\.label)
            hit = rows.first { $0.label.hasPrefix(Self.fixtureTitle) }
            XCTAssertNotNil(hit, "The Perfect Storm not in the top 3: \(reasons)")
            if hit?.label.contains("Semantic") == true { break }
            Thread.sleep(forTimeInterval: 3)
        } while Date() < deadline
        let reason = hit?.label ?? ""
        print("PHASE5_SEARCH_REASON=\(reason)")
        XCTAssertTrue(reason.contains("keyword"), "no keyword match: \(reason)")
        XCTAssertTrue(reason.contains("Semantic"), "no semantic match after the incremental embed: \(reason)")
        Thread.sleep(forTimeInterval: 1.5)
        saveScreenshot("phase5-search", app)

        // 7. Map: the new place Gloucester (Mass.) → label Gloucester, 1 book.
        app.tabBars.buttons["Map"].tap()
        let mapSearch = app.textFields["map.search"]
        XCTAssertTrue(mapSearch.waitForExistence(timeout: 20))
        mapSearch.tap()
        mapSearch.typeText("glouc")
        let result = app.buttons["map.search.result.0"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "Gloucester is not a place on the map")
        result.tap()
        assertGloucesterSheet(app)
        Thread.sleep(forTimeInterval: 3)   // fly-to and tiles
        saveScreenshot("phase5-map-gloucester", app)

        // 7b. The pin persists: relaunch without the reset, `--map-place Gloucester`.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--map-place", "Gloucester"]
        app.launch()
        assertGloucesterSheet(app)

        // 8. Cleanup and reset proof: the reset deletes app-added books.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--reset-user-data"]
        app.launch()
        librarySearch(app, "perfect storm")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(libraryRow(app, beginsWith: Self.fixtureTitle).exists,
                       "--reset-user-data did not remove the app-added book")
    }

    @MainActor
    private func assertGloucesterSheet(_ app: XCUIApplication) {
        let title = app.staticTexts["place.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "place sheet missing")
        XCTAssertEqual(title.label, "Gloucester")
        let count = app.staticTexts["place.bookCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "1 book")
        let book = app.buttons["place.book.0"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "no book row in the Gloucester sheet")
        XCTAssertTrue(book.label.hasPrefix(Self.fixtureTitle), book.label)
    }
}
