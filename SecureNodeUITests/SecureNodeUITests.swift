import XCTest

final class SecureNodeUITests: XCTestCase {
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["SecureNode"].waitForExistence(timeout: 2))
    }
}
