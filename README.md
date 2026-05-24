# barNoticer

barNoticer 是一个轻量的 macOS 待办工具。它利用 MacBook 屏幕顶部摄像头刘海附近的空白区域，把待办事项、快速输入和 AI 辅助整理做成一个类似“灵动岛”的常驻入口。

这个项目主要面向带刘海的 Apple Silicon Mac。应用默认不常驻 Dock，当鼠标移动到顶部热区时，岛会从刘海位置自然展开；需要更完整的管理能力时，可以打开主面板进行编辑和设置。

## 功能特性

- 从屏幕顶部刘海区域展开的待办岛面板。
- 支持窄体和宽体两种岛模式。
- 支持按重要性分组，也支持按自定义分组展示。
- 岛内可快速新增、完成事项。
- 事项支持重要性、完成状态、自定义分组、可选截止时间和多时间点安排。
- 支持一次性多时间点事项，也支持每天、每周、每月重复事项。
- 带时间安排的事项会显示最近一次未到来时间点的剩余时间。
- 可在设置中手动调整唤起热区和展开区域位置。
- 支持 OpenAI 兼容格式的 AI 接口。
- 支持全局快捷键唤起类似 Spotlight 的 AI 输入框。
- 可设置 AI 操作是否需要用户确认。
- 支持 AI 批量操作，关闭确认后会直接执行并返回结果。
- 支持智能提醒：截止时间临近提醒、可选 AI 后台轮询提醒、系统通知和岛式提醒面板。
- 本地保存调试日志，包含 AI 请求、回复和应用事件。
- 支持开机自启开关。

## 使用方式

barNoticer 主要由两个界面组成：

- 岛面板：用于快速查看、创建、完成事项，适合高频轻量操作。
- 主面板：用于完整管理事项、分组、AI 设置、岛位置设置和应用偏好。

岛面板可以按重要性或自定义分组展示事项。宽体模式会横向展示更多内容；当分组数量超过可显示范围时，宽体分组视图支持横向滚动。

事项可以只设置一个截止时间，也可以设置多个具体时间点。多时间点事项会优先展示最近一次还没到来的时间点；重复事项在完成当前周期后会自动滚动到下一次出现时间，而不是直接结束整个事项。

## AI 助手

barNoticer 的 AI 能力使用 OpenAI 兼容的 Chat Completions 接口。用户可以在设置中配置：

- API Base URL
- 模型名称
- API Key
- 全局快捷键
- AI 执行操作前是否需要确认

AI 助手只围绕待办管理工作：总结未完成事项、总结已完成事项、分析完成习惯、给出任务建议、创建事项、修改事项、完成事项、删除事项、管理分组、设置时间安排和重复规则，以及保存每日总结。

应用会把本地结构化上下文提供给 AI，包括未完成事项、已完成事项、分组、截止时间、多时间点、重复规则、创建时间、每日总结、当前日期和时区。这样用户使用“今天”“明天”“下周三”等相对日期时，模型可以根据当前上下文理解。

AI 操作支持批量执行。开启“需要确认”时，用户可以整体确认或逐项处理；关闭确认时，AI 会直接执行允许的待办操作，并用一条简洁回复说明结果。

API Key 只保存在本机应用配置中，不会提交到仓库。

## 智能提醒

barNoticer 的提醒系统包含两类触发方式：

- 截止时间或安排时间临近时触发。默认在提前 1 天和 12 小时进入检查窗口。
- 可选的 AI 后台轮询提醒。该功能默认关闭，避免安装后自动产生 API 成本。

提醒触发后，应用会结合当前时间、时区、全部事项、分组、时间安排、重复规则和近期提醒历史进行判断。AI 只负责决定是否提醒、生成文案和引用相关事项，不会在后台提醒流程中修改任务数据。

提醒呈现支持两种渠道：

- 系统通知：默认开启，可在提醒设置中关闭。
- 岛式提醒：热区附近先出现光晕闪烁，然后从刘海区域展开提醒面板。面板会把相关事项统一渲染在文案下方，并支持完成或稍后提醒。

如果 AI API 不可用，截止时间提醒会使用本地兜底文案，避免错过重要事项。

## 仓库结构

```text
barNoticer/
  应用入口、SwiftUI 视图、SwiftData 模型、控制器、AI 客户端、岛逻辑和资源文件
barNoticer.xcodeproj/
  Xcode 工程文件
barNoticerTests/
  单元测试
README.md
.gitignore
```

仓库包含从源码构建所需的 Xcode 工程和测试文件。`xcuserdata`、DerivedData、构建产物、运行日志和本机配置不会提交。

## 从源码构建

克隆仓库后可以直接用 Xcode 打开：

```bash
git clone git@github.com:LEOibyug/barNoticer.git
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

## 运行测试

```bash
xcodebuild test \
  -project barNoticer.xcodeproj \
  -scheme barNoticer \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/barNoticerTests
```

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

事项时间安排由 `TodoSchedule` 相关逻辑处理，支持单次截止时间、多时间点和每天/每周/每月重复规则。

内置默认分组名为 `默认分组`，不能删除。删除自定义分组时，该分组下的事项会回到默认分组。

## 项目状态

这是一个个人实验性质的 macOS 工具。核心功能已经可以本机使用，但公开分发、正式签名、公证和更广泛设备兼容仍保持轻量处理。
