import XCTest

/// Phase 3 semantic search on the simulator:
///
/// 1. `--reset-embeddings` removes every stored vector, so the on-device
///    MiniLM index is rebuilt from scratch and timed (budget 5 minutes).
/// 2. "lonely astronaut saves earth" finds Project Hail Mary in the top 3.
/// 3. Its Book detail shows at least 3 "More like this" books.
/// 4. A relaunch without resets embeds nothing ("0 embedded this launch").
///
/// Writes no user data (UserDataUITests runs after this class).
final class SearchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSemanticSearchIndexAndRelaunch() throws {
        var app = XCUIApplication()
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

        // 1. Fresh index.
        app.launchArguments = ["--reset-user-data", "--reset-embeddings", "--open-tab", "search", "--wait-for-index"]
        let t0 = Date()
        app.launch()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 30), "search field missing")

        // 2. Indexing-in-progress screenshot (when the banner shows up in time).
        if el("index.banner").waitForExistence(timeout: 60) {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let label = el("index.status").label
                if label.hasPrefix("Indexing"), let n = Self.firstNumber(in: label), n > 0 { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            saveScreenshot("phase3-indexing", app)
        } else {
            XCTContext.runActivity(named: "indexing finished before a screenshot") { _ in }
        }

        // 3. Wait for the whole index.
        let status = el("index.status")
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Index complete.'"),
                                                 object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 360), .completed,
                       "indexing did not complete: \(status.label)")
        let elapsed = Date().timeIntervalSince(t0)
        let line = "PHASE3_INDEX_ELAPSED_SECONDS=\(String(format: "%.1f", elapsed)) app: \(status.label)"
        print(line)
        let attachment = XCTAttachment(string: line)
        attachment.name = "index-elapsed"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(elapsed, 300, "indexing took \(elapsed) s")
        XCTAssertTrue(status.label.contains("6 of 6 books embedded"), status.label)

        // 4. Search.
        let field = app.textFields["search.field"]
        field.tap()
        field.typeText("lonely astronaut saves earth\n")
        XCTAssertTrue(app.buttons["search.result.0"].waitForExistence(timeout: 20), "no results")
        let rows = (0..<3).map { app.buttons["search.result.\($0)"] }.filter { $0.exists }
        let labels = rows.map { $0.label }
        let hit = rows.first { $0.label.hasPrefix("Project Hail Mary") }
        XCTAssertNotNil(hit, "Project Hail Mary not in the top 3: \(labels)")
        Thread.sleep(forTimeInterval: 2)   // let the covers load
        saveScreenshot("phase3-search", app)

        // 5. More like this.
        hit?.tap()
        XCTAssertTrue(app.navigationBars["Project Hail Mary"].waitForExistence(timeout: 15))
        let section = el("moreLikeThis.section")
        for _ in 0..<12 where !(section.exists && section.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(section.exists, "More like this section not found")
        let items = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'moreLikeThis.item.'"))
        let three = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 3"), object: items)
        _ = XCTWaiter.wait(for: [three], timeout: 15)
        XCTAssertGreaterThanOrEqual(items.count, 3)
        // Keep the header and covers clear of the tab bar.
        if section.frame.maxY > app.frame.maxY - 160 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
            Thread.sleep(forTimeInterval: 1)
        }
        saveScreenshot("phase3-more-like-this", app)

        // 6. Relaunch: nothing to embed.
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["--open-tab", "search", "--wait-for-index"]
        app.launch()
        let status2 = el("index.status")
        let complete2 = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Index complete.'"),
                                                  object: status2)
        XCTAssertEqual(XCTWaiter.wait(for: [complete2], timeout: 90), .completed,
                       "relaunch did not report a complete index: \(status2.label)")
        let label = status2.label
        XCTAssertTrue(label.contains(" 0 embedded this launch"), label)
        XCTAssertFalse(el("index.banner").exists)
        print("PHASE3_RELAUNCH_STATUS=\(label)")
    }

    private static func firstNumber(in text: String) -> Int? {
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }
}
