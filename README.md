# barNoticer

barNoticer 是一个面向 macOS Apple Silicon 的轻量待办应用。它利用屏幕顶部摄像头/刘海附近的空间做一个类似“灵动岛”的悬浮入口：鼠标靠近顶部热区时展开，离开后收起，用来快速查看、添加和完成事项。

应用默认不常驻 Dock，主窗口用于管理事项和设置；岛面板用于快速操作。

## 功能概览

- 顶部岛面板：从刘海热区自然展开，支持普通模式和宽体模式。
- 待办管理：新增、完成、删除、修改标题、优先级、分组和 DDL。
- 展示方式：岛内可按重要性分组，也可按自定义分组展示。
- 宽体模式：三倍宽岛面板，可并排展示多列内容；分组超过三列时支持横向滚动。
- 自定义布局：可在设置中调整唤起区域和展开区域位置，不同显示模式独立保存。
- AI 助手：支持 OpenAI 兼容 API，自定义 Base URL、模型和 API Key。
- AI 操作：AI 可以读取当前事项上下文，创建/修改/完成/删除事项，保存当日总结，并可按设置要求用户确认。
- 快捷键输入：通过全局快捷键在屏幕中心调出类似 Spotlight 的 AI 输入框。
- 调试日志：应用维护自己的日志文件，便于排查 AI 对话和运行问题。
- 开机自启：应用设置中提供登录启动开关。

## 系统要求

- macOS
- Apple Silicon Mac
- Xcode 26.5 SDK 或兼容的本机 Xcode 环境
- SwiftUI / SwiftData 支持

当前项目使用 Xcode 工程：

```bash
barNoticer.xcodeproj
```

## 本地运行

使用 Xcode 打开项目：

```bash
open barNoticer.xcodeproj
```

选择 `barNoticer` scheme，然后运行。

也可以用命令行构建：

```bash
xcodebuild build \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -configuration Debug \
  -destination 'platform=macOS'
```

## Release 构建与本机安装

生成 Release 版本：

```bash
xcodebuild build \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/barNoticerRelease
```

构建产物位于：

```bash
/private/tmp/barNoticerRelease/Build/Products/Release/barNoticer.app
```

安装到本机应用目录：

```bash
ditto /private/tmp/barNoticerRelease/Build/Products/Release/barNoticer.app /Applications/barNoticer.app
```

启动：

```bash
open /Applications/barNoticer.app
```

当前本机构建默认使用 Xcode 的 `Sign to Run Locally` / ad-hoc 签名，适合本机使用。若要分发给其他用户，需要配置 Developer ID 签名、Hardened Runtime 和公证流程。

## AI 配置

在主窗口侧边栏进入 `AI 设置`：

- `Base URL`：默认使用 OpenAI 兼容的 `/v1` 地址。
- `模型`：填写兼容 Chat Completions 的模型名称。
- `API Key`：应用保存在本地 UserDefaults，不使用系统钥匙串。
- `快捷键`：选择唤起 AI 输入框的全局快捷键。
- `AI 操作需要手动确认`：关闭后，AI 提出的事项操作会直接执行。
- `测试连接`：使用当前配置发送一次轻量请求。

AI 会收到当前日期、时区、待办事项、分组、DDL 和完成情况等上下文，以便理解“今天”“明天”“下周”等相对日期。

## 日志

日志路径可在 `岛设置 -> 调试日志` 中查看并打开。默认位于应用容器内：

```bash
~/Library/Containers/com.LEOibyug.barNoticer/Data/Library/Application Support/barNoticer/Logs/barNoticer.log
```

日志会记录关键运行事件和 AI 对话摘要，主要用于本地调试。

## 测试

运行完整测试：

```bash
xcodebuild test \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -destination 'platform=macOS'
```

## 数据说明

应用使用 SwiftData 存储：

- `TodoItem`：事项
- `TodoGroup`：自定义分组
- `DailySummary`：当日总结

内置默认分组为 `默认分组`，不可删除。删除其他分组时，组内事项会回到默认分组。

## 开发备注

- 应用启动后设置为 accessory activation policy，不常驻 Dock。
- 顶部岛面板由 AppKit 控制器管理窗口位置、热区和展开动画。
- 主窗口负责完整管理，岛面板负责高频快速操作。
- AI 接口按 OpenAI Chat Completions 工具调用格式组织请求。
