import SwiftData
import XCTest
@testable import barNoticer

/// 测试共用设施：仅内存 ModelContainer。重启持久化验证仍使用临时磁盘库。
enum TestSupport {
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TodoItem.self, TodoGroup.self, DailySummary.self,
            configurations: configuration
        )
    }
}
