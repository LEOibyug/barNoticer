import Foundation
import SwiftData

/// 日程编辑草稿：新建面板与事项设置共用。
/// 草稿持有全部多时间点，编辑提交不会截断已存数据；
/// 同时保留打开时的原始值，用于字段级变更检测与并发冲突判断。
struct TodoScheduleDraft {
    var kind: TodoScheduleKind = .none
    var deadline = Date.now.addingTimeInterval(3_600)
    var scheduledTimes: [Date] = [Date.now.addingTimeInterval(3_600), Date.now.addingTimeInterval(7_200)]
    var recurrenceRule: TodoRecurrenceRule = .daily
    var customRecurrenceDays = 2
    var recurrenceAnchor = Date.now.addingTimeInterval(3_600)
    var reminderMinutesBefore: Int?
    var automaticallyCompletes = false

    /// 打开编辑器时从模型读取的原始有效值；新建草稿没有基线。
    var baseline: Baseline?

    struct Baseline: Equatable {
        var schedule: TodoSchedulePayload
        var reminderMinutesBefore: Int?
        var automaticallyCompletes: Bool = false
    }

    init() {}

    @MainActor
    init(item: TodoItem) {
        let payload = TodoSchedulePayload(item: item)
        kind = payload.kind
        switch payload {
        case .none:
            break
        case let .single(deadline):
            self.deadline = deadline
        case let .multiple(times):
            scheduledTimes = Self.editableTimes(from: times, fallback: deadline)
            deadline = times.sorted().first ?? deadline
        case let .recurring(rule, anchor):
            recurrenceRule = rule
            customRecurrenceDays = rule.intervalDays ?? customRecurrenceDays
            recurrenceAnchor = anchor
            deadline = anchor
        }
        reminderMinutesBefore = item.reminderMinutesBefore
        automaticallyCompletes = item.automaticallyCompletes
        baseline = Baseline(schedule: payload, reminderMinutesBefore: item.reminderMinutesBefore,
            automaticallyCompletes: item.automaticallyCompletes)
    }

    var effectiveRecurrenceRule: TodoRecurrenceRule {
        if case .everyNDays = recurrenceRule {
            return .everyNDays(max(1, customRecurrenceDays))
        }
        return recurrenceRule
    }

    var effectiveAutomaticCompletion: Bool { kind == .recurring && automaticallyCompletes }

    var supportsReminder: Bool { kind == .singleDeadline || kind == .recurring }

    var effectiveReminderMinutesBefore: Int? {
        supportsReminder ? reminderMinutesBefore : nil
    }

    /// 当前类型的有效日程值；类型与有效字段作为一个整体参与比较与提交。
    var effectivePayload: TodoSchedulePayload {
        switch kind {
        case .none:
            return .none
        case .singleDeadline:
            return .single(deadline)
        case .multipleTimes:
            return .multiple(scheduledTimes)
        case .recurring:
            return .recurring(effectiveRecurrenceRule, recurrenceAnchor)
        }
    }

    var hasChanges: Bool {
        guard let baseline else { return true }
        return effectivePayload != baseline.schedule
            || effectiveReminderMinutesBefore != baseline.reminderMinutesBefore
            || effectiveAutomaticCompletion != baseline.automaticallyCompletes
    }

    /// 编辑器至少展示两个时间点；已有三项及以上时全部展示、全部保存。
    private static func editableTimes(from times: [Date], fallback: Date) -> [Date] {
        switch times.count {
        case 0:
            return [fallback, fallback.addingTimeInterval(3_600)]
        case 1:
            return [times[0], times[0].addingTimeInterval(3_600)]
        default:
            return times.sorted()
        }
    }
}

/// 日程类型与其有效字段的整体表示，用于比较和字段级合并。
enum TodoSchedulePayload: Equatable {
    case none
    case single(Date)
    case multiple([Date])
    case recurring(TodoRecurrenceRule, Date)

    var kind: TodoScheduleKind {
        switch self {
        case .none: .none
        case .single: .singleDeadline
        case .multiple: .multipleTimes
        case .recurring: .recurring
        }
    }

    @MainActor
    init(item: TodoItem) {
        switch item.scheduleKind {
        case .none:
            self = .none
        case .singleDeadline:
            self = .single(item.deadlineAt ?? .now)
        case .multipleTimes:
            self = .multiple(item.scheduledTimes)
        case .recurring:
            self = .recurring(item.recurrenceRule ?? .daily, item.recurrenceAnchor ?? .now)
        }
    }
}

@MainActor
enum TodoScheduleCommitter {
    enum Outcome: Equatable {
        case saved
        /// 同一有效字段被并发修改且结果不同；提供重新载入或覆盖选择。
        case conflict(fields: [String])
        case itemDeleted
        case saveFailed(String)
    }

    /// 把草稿提交到模型：只写用户实际编辑的字段，未变更字段不写回。
    /// `force` 为 true 时跳过冲突检测，用草稿覆盖用户编辑的字段，
    /// 但仍保留用户未编辑字段上的外部变化。
    static func commit(_ draft: inout TodoScheduleDraft, into item: TodoItem, context: ModelContext, force: Bool = false) -> Outcome {
        guard !item.isDeleted, item.modelContext != nil else {
            return .itemDeleted
        }

        if !force, let baseline = draft.baseline {
            let conflicts = conflictingFields(draft: draft, baseline: baseline, item: item)
            if !conflicts.isEmpty {
                return .conflict(fields: conflicts)
            }
        }

        applyUserEdits(draft, to: item)
        do {
            try context.save()
        } catch {
            return .saveFailed(error.localizedDescription)
        }
        draft = TodoScheduleDraft(item: item)
        return .saved
    }

    private static func conflictingFields(draft: TodoScheduleDraft, baseline: TodoScheduleDraft.Baseline, item: TodoItem) -> [String] {
        var fields: [String] = []
        let itemSchedule = TodoSchedulePayload(item: item)

        if draft.effectivePayload != baseline.schedule,
           itemSchedule != baseline.schedule,
           draft.effectivePayload != itemSchedule {
            fields.append("日程")
        }
        if draft.effectiveReminderMinutesBefore != baseline.reminderMinutesBefore,
           item.reminderMinutesBefore != baseline.reminderMinutesBefore,
           draft.effectiveReminderMinutesBefore != item.reminderMinutesBefore {
            fields.append("提醒时间")
        }
        if draft.effectiveAutomaticCompletion != baseline.automaticallyCompletes,
           item.automaticallyCompletes != baseline.automaticallyCompletes,
           draft.effectiveAutomaticCompletion != item.automaticallyCompletes {
            fields.append("自动完成")
        }
        return fields
    }

    private static func applyUserEdits(_ draft: TodoScheduleDraft, to item: TodoItem) {
        if let baseline = draft.baseline, draft.effectivePayload == baseline.schedule {
            // 日程未被用户编辑：不写回，保留外部变化和重复推进记录。
        } else {
            switch draft.effectivePayload {
            case .none:
                item.clearSchedule()
            case let .single(deadline):
                item.updateSchedule(deadlineAt: deadline)
            case let .multiple(times):
                item.updateSchedule(scheduledTimes: times)
            case let .recurring(rule, anchor):
                item.updateSchedule(recurrenceRule: rule, recurrenceAnchor: anchor)
            }
        }

        let autoWasEdited = draft.baseline.map {
            draft.effectiveAutomaticCompletion != $0.automaticallyCompletes
        } ?? true
        if autoWasEdited, draft.effectiveAutomaticCompletion != item.automaticallyCompletes {
            item.updateAutomaticCompletion(draft.effectiveAutomaticCompletion)
        }

        let reminderWasEdited = draft.baseline.map {
            draft.effectiveReminderMinutesBefore != $0.reminderMinutesBefore
        } ?? true
        if reminderWasEdited, draft.effectiveReminderMinutesBefore != item.reminderMinutesBefore {
            item.updateReminder(minutesBefore: draft.effectiveReminderMinutesBefore)
        }
    }
}
