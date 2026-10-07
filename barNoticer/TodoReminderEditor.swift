import SwiftUI

struct TodoReminderEditor: View {
    @Binding var minutesBefore: Int?
    @State private var unit = 1

    var body: some View {
        HStack(spacing: 8) {
            Toggle("DDL 提前提醒", isOn: Binding(
                get: { minutesBefore != nil },
                set: { minutesBefore = $0 ? 30 : nil; unit = 1 }
            ))
            .toggleStyle(.checkbox)
            .fixedSize()
            if minutesBefore != nil {
                TextField("提前", value: Binding(
                    get: { (minutesBefore ?? 30) / unit },
                    set: { minutesBefore = min(TodoScheduledReminder.maximumMinutes / unit, max(0, $0)) * unit }
                ), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 65)
                .accessibilityLabel("提前提醒数值")
                Picker("单位", selection: Binding(
                    get: { unit },
                    set: { newUnit in
                        let amount = (minutesBefore ?? 30) / unit
                        unit = newUnit
                        minutesBefore = min(TodoScheduledReminder.maximumMinutes / unit, amount) * unit
                    }
                )) {
                    Text("分钟").tag(1)
                    Text("小时").tag(60)
                    Text("天").tag(1_440)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 72)
                .accessibilityLabel("提前提醒单位")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .help("定时提醒不受 AI 轮询开关影响；填 0 表示 DDL 到点提醒，最多提前 365 天。")
        .onAppear {
            if let minutes = minutesBefore, minutes > 0 {
                unit = minutes % 1_440 == 0 ? 1_440 : (minutes % 60 == 0 ? 60 : 1)
            }
        }
    }
}
