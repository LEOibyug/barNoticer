# barNoticer

barNoticer 是一个轻量的 macOS 待办工具。它利用 MacBook 屏幕顶部摄像头刘海附近的空白区域，把待办事项、快速输入和 AI 辅助整理做成一个类似“灵动岛”的常驻入口。

这个项目主要面向带刘海的 Apple Silicon Mac。应用默认不常驻 Dock，当鼠标移动到顶部热区时，岛会从刘海位置自然展开；需要更完整的管理能力时，可以打开主面板进行编辑和设置。

> 仓库默认分支 `main` 更偏源码浏览和开源展示；如果你希望直接用 Xcode 构建可运行程序，请使用 `xcode-project` 分支。

## 功能特性

- 从屏幕顶部刘海区域展开的待办岛面板。
- 支持窄体和宽体两种岛模式。
- 支持按重要性分组，也支持按自定义分组展示。
- 岛内可快速新增、完成事项。
- 事项支持重要性、完成状态、自定义分组和可选截止时间。
- 带截止时间的事项会显示剩余时间。
- 可在设置中手动调整唤起热区和展开区域位置。
- 支持 OpenAI 兼容格式的 AI 接口。
- 支持全局快捷键唤起类似 Spotlight 的 AI 输入框。
- 可设置 AI 操作是否需要用户确认。
- 本地保存调试日志，包含 AI 请求、回复和应用事件。
- 支持开机自启开关。

## 使用方式

barNoticer 主要由两个界面组成：

- 岛面板：用于快速查看、创建、完成事项，适合高频轻量操作。
- 主面板：用于完整管理事项、分组、AI 设置、岛位置设置和应用偏好。

岛面板可以按重要性或自定义分组展示事项。宽体模式会横向展示更多内容；当分组数量超过可显示范围时，宽体分组视图支持横向滚动。

## AI 助手

barNoticer 的 AI 能力使用 OpenAI 兼容的 Chat Completions 接口。用户可以在设置中配置：

- API Base URL
- 模型名称
- API Key
- 全局快捷键
- AI 执行操作前是否需要确认

AI 助手只围绕待办管理工作：总结未完成事项、总结已完成事项、分析完成习惯、给出任务建议、创建事项、修改事项、完成事项、删除事项、管理分组，以及保存每日总结。

应用会把本地结构化上下文提供给 AI，包括未完成事项、已完成事项、分组、截止时间、创建时间、每日总结、当前日期和时区。这样用户使用“今天”“明天”“下周三”等相对日期时，模型可以根据当前上下文理解。

API Key 只保存在本机应用配置中，不会提交到仓库。

## 仓库结构

```text
barNoticer/
  应用入口、SwiftUI 视图、SwiftData 模型、控制器、AI 客户端、岛逻辑和资源文件
README.md
.gitignore
```

`main` 分支刻意不跟踪 Xcode 工程文件和测试目录，使仓库首页更像一个开源工具的源码展示。可直接构建的工程文件和测试位于 `xcode-project` 分支。

## 从源码构建

如果你希望直接克隆后用 Xcode 打开并运行：

```bash
git clone -b xcode-project git@github.com:LEOibyug/barNoticer.git
cd barNoticer
open barNoticer.xcodeproj
```

在 Xcode 中选择 `barNoticer` scheme，然后运行即可。

也可以使用命令行构建 Release 版本：

```bash
xcodebuild build \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/barNoticerRelease
```

安装到本机：

```bash
ditto /private/tmp/barNoticerRelease/Build/Products/Release/barNoticer.app /Applications/barNoticer.app
open /Applications/barNoticer.app
```

本地构建默认使用 Xcode 的本地签名。若要公开分发，需要自行配置 Developer ID 签名、Hardened Runtime 和 notarization。

## 环境要求

- macOS
- Apple Silicon Mac
- 带较新 macOS SDK 的 Xcode
- SwiftUI 与 SwiftData 支持

## 日志

应用会维护轻量级本地日志，便于调试 AI 请求、回复和窗口行为。日志位置可在应用设置中查看，通常位于应用容器内：

```text
~/Library/Containers/com.LEOibyug.barNoticer/Data/Library/Application Support/barNoticer/Logs/barNoticer.log
```

运行日志、用户配置、API Key 和本机数据都不会作为仓库内容提交。

## 数据模型

barNoticer 使用 SwiftData 保存数据，核心模型包括：

- `TodoItem`
- `TodoGroup`
- `DailySummary`

内置默认分组名为 `默认分组`，不能删除。删除自定义分组时，该分组下的事项会回到默认分组。

## 分支说明

- `main`：源码浏览和开源展示分支，不包含 Xcode 工程和测试目录。
- `xcode-project`：可直接构建分支，包含 `barNoticer.xcodeproj` 和 `barNoticerTests`。

## 项目状态

这是一个个人实验性质的 macOS 工具。核心功能已经可以本机使用，但公开分发、正式签名、公证和更广泛设备兼容仍保持轻量处理。
