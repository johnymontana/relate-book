import XCTest

/// Phase 2 user data on the simulator: status, rating, tag and note are
/// written through the UI, survive a relaunch (WAL durability, no
/// checkpoint needed), and show up in the Tags tab and the Library tag
/// filter. Only The Left Hand of Darkness is touched, and each test that
/// needs a clean slate launches with `--reset-user-data` (DEBUG only).
final class UserDataUITests: XCTestCase {
    let book = "/works/OL59800W"            // The Left Hand of Darkness
    let noteText = "Loved the winter crossing of the Gobrin Ice."

    override func setUp() {
        continueAfterFailure = false
    }

    /// Runs first (alphabetical). A leading swipe sets the status from the Library list.
    func testLibrarySwipeSetsStatus() {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-user-data"]
        app.launch()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("left hand of darkness")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Left Hand of Darkness'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Status: Want to read"), "reset did not clear the status: \(row.label)")
        row.swipeRight()
        let reading = app.buttons["Reading"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        reading.tap()
        let updated = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'The Left Hand of Darkness' AND label CONTAINS 'Status: Reading'")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 10))
        saveScreenshot("phase2-swipe", app)
    }

    /// Status + rating + tag + note survive a relaunch; the Tags tab and the
    /// Library tag filter show them.
    func testUserDataSurvivesRelaunch() {
        // Launch 1: clean slate, edit.
        var app = XCUIApplication()
        app.launchArguments = ["--reset-user-data", "--open-book", book]
        app.launch()
        XCTAssertTrue(app.navigationBars["The Left Hand of Darkness"].waitForExistence(timeout: 20))
        let picker = app.segmentedControls["status.picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(picker.buttons["Want"].isSelected, "reset did not clear the status")
        picker.buttons["Read"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Finished'")).firstMatch
            .waitForExistence(timeout: 10))

        app.buttons["rating.star.4"].tap()
        XCTAssertTrue(waitSelected(app.buttons["rating.star.4"]))
        XCTAssertFalse(app.buttons["rating.star.5"].isSelected)

        // The button's accessibility frame spans the List row, but its hit
        // area is the label at the leading edge: tap the label itself.
        let addTag = app.buttons["tag.add"]
        XCTAssertTrue(addTag.waitForExistence(timeout: 10))
        addTag.staticTexts["Add Tag"].tap()
        let field = app.textFields["tag.picker.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Favorites")
        let create = app.buttons["tag.picker.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertTrue(app.buttons["tag.picker.option.Favorites"].waitForExistence(timeout: 10))
        app.buttons["tag.picker.done"].tap()
        XCTAssertTrue(app.buttons["tag.chip.Favorites"].waitForExistence(timeout: 10))

        let addNote = app.buttons["note.add"]
        XCTAssertTrue(addNote.waitForExistence(timeout: 10))
        for _ in 0..<4 where !addNote.isHittable { app.swipeUp() }
        addNote.tap()
        let editor = app.textViews["note.editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(noteText)
        app.buttons["note.editor.save"].tap()
        XCTAssertTrue(noteElement(app).waitForExistence(timeout: 10))

        // Launch 2: no reset flag; everything must still be there.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--open-book", book]
        app.launch()
        XCTAssertTrue(app.navigationBars["The Left Hand of Darkness"].waitForExistence(timeout: 20))
        let read = app.segmentedControls["status.picker"].buttons["Read"]
        XCTAssertTrue(read.waitForExistence(timeout: 10))
        XCTAssertTrue(read.isSelected)
        XCTAssertTrue(app.buttons["rating.star.4"].isSelected)
        XCTAssertFalse(app.buttons["rating.star.5"].isSelected)
        XCTAssertTrue(app.buttons["tag.chip.Favorites"].exists)
        XCTAssertTrue(noteElement(app).waitForExistence(timeout: 10))
        saveScreenshot("phase2-book-detail", app)

        // Launch 3: --open-tab tags; the Tags tab shows the count, then the
        // Library filtered by the tag shows the book.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--open-tab", "tags"]
        app.launch()
        let favorites = app.buttons["Favorites (1)"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 20))
        saveScreenshot("phase2-tags", app)

        app.tabBars.buttons["Library"].tap()
        let tagChip = app.buttons["filter.tag"]
        XCTAssertTrue(tagChip.waitForExistence(timeout: 10))
        tagChip.tap()
        let menuItem = app.buttons["Favorites (1)"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 10))
        menuItem.tap()
        XCTAssertTrue(app.staticTexts["1 book"].waitForExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Left Hand of Darkness'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Status: Read"), row.label)
        saveScreenshot("phase2-library-tag", app)
    }

    private func noteElement(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", noteText)).firstMatch
    }

    private func waitSelected(_ element: XCUIElement) -> Bool {
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: element)
        return XCTWaiter.wait(for: [selected], timeout: 5) == .completed
    }
}
