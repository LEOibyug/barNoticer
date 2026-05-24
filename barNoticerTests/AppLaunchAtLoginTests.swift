import ServiceManagement
import XCTest
@testable import barNoticer

final class AppLaunchAtLoginTests: XCTestCase {
    func testGeneratedInfoPlistDeclaresAccessoryApp() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("barNoticer.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)

        XCTAssertEqual(project.components(separatedBy: "INFOPLIST_KEY_LSUIElement = YES;").count - 1, 2)
    }

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
