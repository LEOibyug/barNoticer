# 周期任务自动完成

新增按任务持久化的“到点自动完成”，默认关闭，既有任务仍按手动完成并显示逾期。新建与编辑共用控件；可通过 set_recurring_auto_completion 工具切换，遵循普通审批设置。开启后立即补齐已到期次数，显示未来一次和“自动完成”，关闭后保留已完成进度。

本地 ScheduledReminderScheduler 同时调度提醒与下一次自动完成，不依赖 AI 或提醒开关。当前提醒先投递再推进（包含零提前量）；启动、唤醒、时钟/时区变化和事项保存都会重新计算。月末周期保留原锚点日规则。自动完成只完成本次，不将整个周期任务永久标记完成。

编辑器或开关提前推进时，将当前已到期但未投递的提醒日期持久化保留，防止绕过投递。scheduler 保存去重标记与清理待投递状态，失败一起恢复。取消提醒或更换日程清除相应待投递记录。

验证：完整 257 项测试通过，最后待投递保护新增后 42 项相关测试通过；Release 与严格签名校验通过。测试覆盖无提醒/无AI定时推进、积压补齐、关闭恢复手动逾期、零提前提醒与继承、重启持久化、月末、AI工具、草稿合并和关闭开关瞬间的提醒保留。日志 /private/tmp/barNoticer-autocomplete-final.log、/private/tmp/barNoticer-autocomplete-lastcheck.log、/private/tmp/barNoticer-autocomplete-release-final.log。已替换并重新启动 Applications 版本，未提交/推送。

提交前最终复测：258 项全部通过（/private/tmp/barNoticer-allfeatures-verified.log）。修正两处提醒引擎测试遗漏的隔离 defaults 注入，以及窗口时序测试对旧窗口对象标识复用的敏感性；均为测试侧改动，已安装应用代码不变。
