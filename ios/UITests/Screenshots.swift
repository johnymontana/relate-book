import XCTest

extension XCTestCase {
    /// Attaches a screenshot to the test result and, when
    /// `TEST_RUNNER_SCREENSHOT_DIR` is set on `xcodebuild test` (the runner
    /// sees it as `SCREENSHOT_DIR`), also writes `<name>.png` there.
    func saveScreenshot(_ name: String, _ app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
