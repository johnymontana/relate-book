import XCTest

/// Phase 4 map on the simulator. Map content is checked through the
/// on-screen `map.count` label ("214 places in view"), not through
/// `MKMapView`'s accessibility children: XCUITest exposes markers
/// inconsistently and clusters hide most of them. Writes no user data.
final class MapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMapShowsPinsAndPlaceSheet() throws {
        let app = XCUIApplication()
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

        // 1. Overview: the initial region (continental US) has pins.
        app.launchArguments = ["--open-tab", "map"]
        app.launch()
        XCTAssertTrue(el("map.view").waitForExistence(timeout: 30), "map view missing")
        let count = app.staticTexts["map.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 20), "count label missing")
        let somePlaces = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES '^[1-9][0-9]* places? in view$'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [somePlaces], timeout: 20), .completed, "no pins: \(count.label)")
        XCTAssertFalse(el("map.empty").exists)
        let markers = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'map.pin.' OR identifier == 'map.cluster'"))
        print("PHASE4_MAP_COUNT=\(count.label) markers=\(markers.count)")
        Thread.sleep(forTimeInterval: 3)   // tiles and markers settle
        saveScreenshot("phase4-map", app)

        // The birthplace layer adds pins (count only grows).
        let before = Self.firstNumber(in: count.label) ?? 0
        el("map.birthplacesToggle").tap()
        let more = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Self.firstNumber(in: count.label) ?? 0) > before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [more], timeout: 10), .completed,
                       "birthplaces did not add pins: \(before) -> \(count.label)")
        el("map.birthplacesToggle").tap()

        // 2. --map-place San Francisco opens its sheet (Project Hail Mary is set there).
        app.terminate()
        app.launchArguments = ["--map-place", "San Francisco"]
        app.launch()
        let title = app.staticTexts["place.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "place sheet missing")
        XCTAssertEqual(title.label, "San Francisco")
        let bookCount = app.staticTexts["place.bookCount"]
        XCTAssertTrue(bookCount.waitForExistence(timeout: 15))
        XCTAssertEqual(bookCount.label, "1 book")
        XCTAssertTrue(app.staticTexts["Books set here (1)"].waitForExistence(timeout: 10))
        let first = app.buttons["place.book.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "no book rows")
        Thread.sleep(forTimeInterval: 3)   // covers and the fly-to
        saveScreenshot("phase4-place-san-francisco", app)

        // 3. A book row pushes Book detail inside the sheet.
        let rowTitle = first.label.components(separatedBy: ",").first ?? first.label
        first.tap()
        let detail = app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                              String(rowTitle.prefix(12)))).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15), "Book detail did not open for \(rowTitle)")
        Thread.sleep(forTimeInterval: 1)
        saveScreenshot("phase4-place-book", app)

        // 4. Back, Done closes the sheet; place search flies elsewhere.
        detail.buttons.element(boundBy: 0).tap()
        let close = app.buttons["place.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Done missing after going back")
        close.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "sheet did not close")
        let field = app.textFields["map.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("sahara")
        let result = app.buttons["map.search.result.0"]
        XCTAssertTrue(result.waitForExistence(timeout: 15), "no place search results")
        XCTAssertTrue(result.label.hasPrefix("Sahara"), result.label)
        saveScreenshot("phase4-map-search", app)
        result.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertTrue(title.label.hasPrefix("Sahara"), title.label)
    }

    @MainActor
    func testShowOnMapFromTermPage() throws {
        let app = XCUIApplication()

        // A located place: the button lands on the map with its sheet.
        app.launchArguments = ["--open-term", "place=San Francisco"]
        app.launch()
        XCTAssertTrue(app.navigationBars["San Francisco"].waitForExistence(timeout: 30))
        let button = app.buttons["term.showOnMap"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Show on map missing")
        saveScreenshot("phase4-term-show-on-map", app)
        button.tap()
        let title = app.staticTexts["place.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "place sheet missing")
        XCTAssertEqual(title.label, "San Francisco")
        XCTAssertTrue(app.descendants(matching: .any)["map.view"].exists, "not on the map")

        // A fictional place says why it has no pin.
        app.terminate()
        app.launchArguments = ["--open-term", "place=Gethen"]
        app.launch()
        let notOnMap = app.staticTexts["term.notOnMap"]
        XCTAssertTrue(notOnMap.waitForExistence(timeout: 30))
        XCTAssertEqual(notOnMap.label, "Not on the map: fictional or not a real place")
        XCTAssertFalse(app.buttons["term.showOnMap"].exists)
    }

    static func firstNumber(in text: String) -> Int? {
        let digits = text.prefix { $0.isNumber }
        return Int(digits)
    }
}
