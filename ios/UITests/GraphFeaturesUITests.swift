import XCTest

/// The graph features on the simulator, on the six-book sample:
///
/// 1. Next Up lists the unread award winners; reading and rating one
///    removes it from the list.
/// 2. Another book's detail then shows "Connected to your reading", naming
///    what the two share and the rating, and links to the rated book.
/// 3. Search rows carry the same reason.
/// 4. The Map's "Near your reading" sheet opens and, with nothing read,
///    explains itself.
///
/// The first test leaves a status and a rating behind; the classes that run
/// after it and care (Search, UserData) start with `--reset-user-data`.
final class GraphFeaturesUITests: XCTestCase {
    private let leftHand = "/works/OL59800W"
    private let redMars = "/works/OL81665W"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testNextUpConnectionsAndSearchReasons() {
        var app = XCUIApplication()
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

        // 1. Next Up on an untouched library: the two award winners, most awarded first.
        app.launchArguments = ["--reset-user-data"]
        app.launch()
        let nextUp = app.buttons["library.nextUp"]
        XCTAssertTrue(nextUp.waitForExistence(timeout: 30), "Next Up button missing")
        nextUp.tap()
        let first = app.buttons["nextUp.award.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), "no award winners listed")
        XCTAssertTrue(first.label.contains("The Left Hand of Darkness"), first.label)
        XCTAssertTrue(app.buttons["nextUp.award.1"].label.contains("Project Hail Mary"))
        XCTAssertFalse(app.buttons["nextUp.series.0"].exists)
        Thread.sleep(forTimeInterval: 2)   // let the covers load
        saveScreenshot("graph-next-up", app)

        // Read and rate The Left Hand of Darkness; back on Next Up it is gone.
        first.tap()
        let picker = app.segmentedControls["status.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["Read"].tap()
        let star = app.buttons["rating.star.5"]
        XCTAssertTrue(star.waitForExistence(timeout: 10))
        star.tap()
        XCTAssertTrue(waitSelected(star), "rating not saved")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let remaining = app.buttons["nextUp.award.0"]
        let onlyHailMary = NSPredicate(format: "label CONTAINS 'Project Hail Mary'")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: onlyHailMary, object: remaining)], timeout: 15),
                       .completed, "Next Up did not refresh: \(remaining.label)")
        XCTAssertFalse(app.buttons["nextUp.award.1"].exists)
        app.terminate()

        // 2. Red Mars shares a subject with the rated book.
        app = XCUIApplication()
        app.launchArguments = ["--open-book", redMars]
        app.launch()
        let link = app.buttons["connected.link.0"]
        var swipes = 0
        while !(link.waitForExistence(timeout: 3) && link.isHittable) && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(link.exists, "no 'Connected to your reading' section")
        // Bring the section clear of the tab bar for the screenshot.
        if link.frame.maxY > app.frame.height * 0.75 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(link.label.contains("The Left Hand of Darkness") && link.label.contains("which you rated 5"), link.label)
        saveScreenshot("graph-connected", app)
        link.tap()
        XCTAssertTrue(app.segmentedControls["status.picker"].buttons["Read"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["rating.star.5"].isSelected, "the link did not open the rated book")
        app.terminate()

        // 3. Search: a row explains itself with the same link.
        app = XCUIApplication()
        app.launchArguments = ["--search", "left hand darkness", "--wait-for-index"]
        app.launch()
        XCTAssertTrue(app.buttons["search.result.0"].waitForExistence(timeout: 60), "no results")
        let status = el("index.status")
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Index complete.'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 180), .completed, "indexing did not complete: \(status.label)")
        let explained = NSPredicate(format: "label CONTAINS 'which you rated 5'")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).matching(explained).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no search row names the link to the rated book")
        XCTAssertTrue(app.buttons["search.result.0"].label.hasPrefix("The Left Hand of Darkness"), app.buttons["search.result.0"].label)
        Thread.sleep(forTimeInterval: 2)
        saveScreenshot("graph-search", app)
    }

    @MainActor
    func testNearYourReadingSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-user-data", "--open-tab", "map"]
        app.launch()
        let button = app.buttons["map.nearReading"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Near your reading button missing")
        button.tap()
        let empty = app.descendants(matching: .any)["nearReading.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 15), "the empty state did not show")
        saveScreenshot("graph-near-reading", app)
        app.buttons["nearReading.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["map.count"].waitForExistence(timeout: 10))
    }

    private func waitSelected(_ element: XCUIElement) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        return XCTWaiter.wait(for: [selected], timeout: 10) == .completed
    }
}
