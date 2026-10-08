# 多供应商配置与诊断

用户确认支持 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages 三种协议。新增配置集合、统一协议适配器、模型与余额发现服务及供应商编辑组件。既有确认策略、全局记忆规则和周期提醒保留。

- 配置独立保存名称、URL、协议、Key、模型，保留原有单配置数据；新增、删除、重排及单配置/顺序模式持久化。编辑备用项不会改变实际使用项。
- 三种协议支持图片、工具调用、工具结果；聊天和只读提醒共用传输层，各供应商使用自己的凭据。请求失败后按配置顺序尝试，取消不重试。工具仅在成功解析后由本地执行，不在供应商失败重试环节执行。
- Responses 的原始输出项绑定来源配置，只在同源续轮时保留加密推理和内部ID；跨供应商重建通用消息与工具结果。
- 输入框统一布局，labelsHidden 避免 macOS Form 将示例再次显示到右侧。空值使用显式灰色 prompt。模型列表异步读取并提供前缀点击补全，切换配置或编辑连接信息取消旧查询并丢弃过期结果。
- 余额尝试兼容 user/balance 与 dashboard/billing/credit_grants 结构；DeepSeek 兼容版本化 URL。无标准或失败时只显示“暂无数据”，不推断额度。
- 连接测试固定当前编辑项，不回退其他供应商。发送普通文字和独立生成的随机四位数字PNG，识别匹配才报告视觉已验证。网络/API/识别失败显示未通过，不宣称模型一定无视觉能力。

验证：完整 250 项测试通过；最终请求构造去重后 32 项相关测试通过；Release 构建成功，严格签名校验通过。日志 /private/tmp/barNoticer-providers-final.log、/private/tmp/barNoticer-providers-lastcheck.log、/private/tmp/barNoticer-providers-release-final.log。UI 离屏检查深浅色、有值/空值，真实供应商在线能力和余额未作全平台实测；测试使用隔离模拟HTTP，不消耗用户API额度。已替换并重启 Applications 版本，本次未提交/推送。

协议参考：
- https://developers.openai.com/api/reference/resources/responses/methods/create/
- https://platform.claude.com/docs/en/api/messages/create
