import XCTest
@testable import SecureNodeSDK

final class SecureNodeSDKTests: XCTestCase {
    func testConfigDefaultBaseURL() {
        XCTAssertEqual(SecureNodeConfig.defaultBaseURL.host, "api.securenode.io")
    }
}
