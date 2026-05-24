import ServiceManagement
import XCTest
@testable import barNoticer

final class AppLaunchAtLoginTests: XCTestCase {
    func testLaunchAtLoginStatusMapsEnabledStates() {
        XCTAssertTrue(AppLaunchAtLoginStatus(status: .enabled).isEnabled)
        XCTAssertTrue(AppLaunchAtLoginStatus(status: .requiresApproval).isEnabled)
        XCTAssertFalse(AppLaunchAtLoginStatus(status: .notRegistered).isEnabled)
        XCTAssertFalse(AppLaunchAtLoginStatus(status: .notFound).isEnabled)
    }

    func testLaunchAtLoginStatusProvidesUserReadableText() {
        XCTAssertEqual(AppLaunchAtLoginStatus(status: .enabled).title, "已开启")
        XCTAssertEqual(AppLaunchAtLoginStatus(status: .requiresApproval).title, "需要系统确认")
        XCTAssertEqual(AppLaunchAtLoginStatus(status: .notRegistered).title, "未开启")
    }
}
