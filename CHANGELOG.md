# 更新日志

本文件记录 barNoticer 的主要功能演进、重构与稳定性修复。

## 2026-11-17

### 安全性与数据可靠性
- **API Key 隔离存储与旧版迁移**：[`AIAPIKeyStore`](barNoticer/AIAPIKeyStore.swift) 与 [`AIProviderCollection`](barNoticer/AIProviderConfiguration.swift) 不再将密钥明文保存在 `UserDefaults`。签名支持时优先使用 Data Protection Keychain；本地 ad-hoc 构建自动回退到权限为 `0600`（目录 `0700`）且标记排除 Time Machine 备份的独立凭据文件，并在读取时自动迁移和清理历史明文 Key。移除供应商时同步清理对应密钥。
- **标题/备注并发冲突基线与保存错误反馈**：新增 `TodoItemEditDraft` 与 `TodoEditCommitter`，在事项设置 Sheet 中将标题、备注与日程统一纳入基线冲突检测，并发修改时不会覆盖或部分写入未提交字段；主窗口、待办行与岛面板的持久化写入统一通过 `ModelContextPersistence` 记录日志并在主面板弹窗提示错误。

### 多显示器、性能与工程质量
- **多显示器统一屏选与低功耗轮询**：提取 [`ScreenTargeting`](barNoticer/ScreenTargeting.swift) 统一鼠标所在屏幕定位和 `NSScreenNumber` 锚定；待办岛在收起态按鼠标所在屏幕检测热区，展开后锁定目标屏幕；指针静止且岛处于空闲收起态时跳过重复的屏幕遍历与坐标计算。
- **降低主线程同步 I/O 与重复编解码**：移除 AI 输入框逐字按键写盘日志，将 [`AppDebugLogStore`](barNoticer/AppDebugLogStore.swift) 改为线程安全并将过期日志目录扫描节流至每 30 分钟一次；缓存 [`AIImageAttachment`](barNoticer/AIImageAttachment.swift) 的 `dataURL` 与 `NSImage` 预览，并将文件选择器选图后的降采样/JPEG 编码移入后台任务执行。
- **沙盒单元测试路径与编译警告清理**：修复测试中向仓库 `tmp/` 写文件导致 App Sandbox 下失败的问题，统一使用系统沙盒临时目录；清理主应用目标的 Swift 并发隔离编译警告。

### AI 助手与总结系统（同期功能合入）
- **三协议流式输出与推理强度**：聊天支持 OpenAI Chat Completions、OpenAI Responses 与 Anthropic Messages 流式输出，支持按供应商配置 `reasoning_effort` / `reasoning.effort`、推理摘要展示与 Responses 同源加密推理项回传。
- **活动区与工具自纠**：输入框下方新增固定高度透明活动区，实时展示思考摘要与工具进度；工具参数校验错误按调用 ID 自动反馈给模型并支持最多 6 轮自纠，保留同批已执行或待确认操作。
- **AI 全字段修改事项**：`update_todo` 支持修改进行中与已完成事项的标题、备注、重要性、分组、日程、提醒、自动完成、完成状态、历史时间及重复任务进度。
- **独立 JSON 总结档案与确认边界**：主面板新增“记录 → 总结”，改用独立 `<UUID>.json` 存储新总结（旧版 SwiftData `DailySummary` 保留仅作兼容）；总结保存始终需在聊天中逐份点击确认，与普通审批开关解耦。
- **面板与交互细节**：统一聊天、新建事项和提醒弹窗的材质、圆角与层级，修复回复完成后被旧收起动画压缩的问题；支持 `Esc` 在有内容时先新对话、空会话时再关闭；提醒高度随文案与关联事项自适应收紧。

---

## 2026-10-15

- 宽体岛按自定义分组超过 3 列时支持横向滚动，并在底部提示“共 N 个分组 · 左右滚动查看 · 拖动调整顺序”。
- 补充后台创建事项在独立上下文中的持久化回归测试。

## 2026-10-13

- 精简待办岛头部标题，突出进行中数量与核心操作入口。
- 支持使用 `Esc` 优先重置当前 AI 会话、在空白会话时关闭面板，并避开输入法组字与选图弹窗。

## 2026-10-08

- **多供应商 AI 与周期任务自动完成**：支持多套供应商配置及单选/顺序回退模式、模型列表自动获取补全、余额探测与视觉能力测试；新增重复任务到点自动完成（`automaticallyCompletes`）及周期提醒继承。
- **全项目重构与原生视觉升级**：引入 `SettingsPage`、`TodoScheduleDraft`、`TodoScheduleEditor`、`AITodoLookup`、`ReminderHaloView` 等共享组件，将用户定时提醒拆分为事件驱动单次计时器（[`ScheduledReminderScheduler`](barNoticer/ScheduledReminderScheduler.swift)），优化先光晕后内容呈现队列与辅助功能支持。

## 2026-10-07

- **按需全局记忆**：支持跨会话、跨重启的本地全局记忆，采用 `read_global_memory` 按需查阅并在每轮后过期替换，明确区分用户指定与自动记录优先级，清空记忆强制二次确认。
- **图文 AI 与后台回复**：支持最多 4 张图片输入与 `⌘V` 粘贴截图；关闭 AI 面板后请求继续在后台执行并通过提醒窗口通知结果；新增独立单次 DDL 提前提醒。
- **中文输入法与悬停体验修复**：使用 AppKit 原生占位与 `hasMarkedText()` 保护中文拼音组字过程；修复岛面板悬停与提醒布局对齐。

## 2026-06-11 ~ 2026-06-21

- 支持配置提醒弹窗持续时间（1~15 秒）。
- 优化主面板与岛面板分组拖动排序交互，改为专用拖动把手减少误触。
- 新增事项备注（岛内点击展开、主面板可折叠查看）与独立全局快捷键新建事项面板（默认 `⌘⌥N`），支持无时间、单次 DDL、多时间点与重复规则。
