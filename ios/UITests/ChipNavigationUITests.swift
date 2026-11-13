import XCTest

/// Drives the real app on the simulator to prove the chip facets (genres,
/// subjects, places, people, eras, publishers) navigate by tap: chips push
/// `Route.term` through the `openRoute` environment action, which no unit
/// test can reach. Set `TEST_RUNNER_SCREENSHOT_DIR` on `xcodebuild test`
/// to also save each screen as a PNG there.
final class ChipNavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testGenreChipOpensTermPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-book", "/works/OL59800W"]   // The Left Hand of Darkness
        app.launch()

        XCTAssertTrue(app.navigationBars["The Left Hand of Darkness"].waitForExistence(timeout: 20))
        let chip = app.buttons["science fiction"]
        for _ in 0..<6 where !(chip.exists && chip.isHittable) { app.swipeUp() }
        XCTAssertTrue(chip.isHittable, "genre chip not found")
        saveScreenshot("phase1-chip-before", app)
        chip.tap()

        XCTAssertTrue(app.navigationBars["science fiction"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["GENRE"].waitForExistence(timeout: 10))
        // The term page lists the genre's books (title order, so this book may be below the fold).
        let count = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'books on the list'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Project Hail Mary'")).firstMatch.waitForExistence(timeout: 10))
        saveScreenshot("phase1-chip-genre", app)
    }

    func testPlaceChipOpensPlacePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-book", "/works/OL59800W"]
        app.launch()

        XCTAssertTrue(app.navigationBars["The Left Hand of Darkness"].waitForExistence(timeout: 20))
        let chip = app.buttons["Gethen"]
        for _ in 0..<6 where !(chip.exists && chip.isHittable) { app.swipeUp() }
        XCTAssertTrue(chip.isHittable, "place chip not found")
        chip.tap()

        XCTAssertTrue(app.navigationBars["Gethen"].waitForExistence(timeout: 10))
        // Phase 4: Gethen is fictional, so the page says why it has no pin.
        let notOnMap = app.staticTexts["term.notOnMap"]
        XCTAssertTrue(notOnMap.waitForExistence(timeout: 10))
        XCTAssertEqual(notOnMap.label, "Not on the map: fictional or not a real place")
        XCTAssertFalse(app.buttons["term.showOnMap"].exists)
        saveScreenshot("phase1-chip-place", app)
    }
}
