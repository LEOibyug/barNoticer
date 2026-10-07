import SwiftUI

/// 绑定 TodoScheduleDraft 的日程控件：类型、日期、多时间点、周期。
/// 新建面板与事项设置共用同一套规则，布局可用 layout 区分。
struct TodoScheduleEditor: View {
    enum Layout {
        /// 事项设置表单：标签在左的 Grid 行。
        case form
        /// 新建面板：单行紧凑排列。
        case compact
    }

    @Binding var draft: TodoScheduleDraft
    var layout: Layout = .form
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch layout {
        case .form:
            formEditor
        case .compact:
            compactEditor
        }
    }

    private var formEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("类型").foregroundStyle(.secondary)
                kindPicker.frame(width: 150, alignment: .leading)
            }

            switch draft.effectivePayload {
            case .none:
                EmptyView()
            case .single:
                GridRow {
                    Text("DDL").foregroundStyle(.secondary)
                    formDatePicker($draft.deadline)
                }
            case .multiple:
                ForEach(draft.scheduledTimes.indices, id: \.self) { index in
                    GridRow {
                        Text("时间 \(index + 1)").foregroundStyle(.secondary)
                        formDatePicker($draft.scheduledTimes[index])
                    }
                }
            case .recurring:
                GridRow {
                    Text("周期").foregroundStyle(.secondary)
                    recurrencePicker
                }
                GridRow {
                    Text("开始").foregroundStyle(.secondary)
                    formDatePicker($draft.recurrenceAnchor)
                }
            }
        }
    }

    private var compactEditor: some View {
        HStack(spacing: 10) {
            switch draft.effectivePayload {
            case .none:
                Label("不设置时间计划", systemImage: "calendar.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .single:
                compactDatePicker("DDL", selection: $draft.deadline)
            case .multiple:
                ForEach(draft.scheduledTimes.indices, id: \.self) { index in
                    compactDatePicker("时间 \(index + 1)", selection: $draft.scheduledTimes[index])
                }
            case .recurring:
                recurrencePicker
                compactDatePicker("开始", selection: $draft.recurrenceAnchor)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 30, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: draft.kind)
    }

    private var kindPicker: some View {
        Picker("时间", selection: $draft.kind) {
            ForEach(TodoScheduleKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.menu)
    }

    private var recurrencePicker: some View {
        HStack(spacing: 10) {
            Picker("重复", selection: Binding(
                get: { draft.recurrenceRule },
                set: { rule in
                    draft.recurrenceRule = rule
                    if let days = rule.intervalDays {
                        draft.customRecurrenceDays = days
                    }
                }
            )) {
                ForEach(recurrencePickerRules) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .pickerStyle(.menu)

            if case .everyNDays = draft.recurrenceRule {
                Stepper(
                    value: Binding(
                        get: { draft.customRecurrenceDays },
                        set: { days in
                            draft.customRecurrenceDays = max(1, days)
                            draft.recurrenceRule = .everyNDays(draft.customRecurrenceDays)
                        }
                    ),
                    in: 1...365
                ) {
                    Text("\(draft.customRecurrenceDays)天")
                        .frame(width: 44, alignment: .leading)
                }
            }
        }
    }

    private var recurrencePickerRules: [TodoRecurrenceRule] {
        [.daily, .weekly, .monthly, .everyNDays(draft.customRecurrenceDays)]
    }

    private func formDatePicker(_ selection: Binding<Date>) -> some View {
        DatePicker("", selection: selection, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
    }

    private func compactDatePicker(_ title: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            DatePicker("", selection: selection, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
    }
}
