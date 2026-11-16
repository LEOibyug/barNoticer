import AppKit
import SwiftUI

struct SummaryLibraryView: View {
    @ObservedObject var summaryStore: SummaryStore
    @State private var selectedSummaryID: UUID?
    @State private var directoryError: String?

    private var selectedSummary: SavedSummary? {
        summaryStore.summaries.first { $0.id == selectedSummaryID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = summaryStore.loadError {
                errorBanner(loadError)
            }
            if let directoryError {
                errorBanner(directoryError)
            }

            if summaryStore.summaries.isEmpty {
                emptyState
            } else {
                HSplitView {
                    summaryList
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                    summaryDetail
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("总结")
        .navigationSubtitle("仅显示新格式 JSON 总结；旧记录不会迁移。")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    summaryStore.reload()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("重新读取保存位置中的总结文件")

                Button {
                    openSummaryDirectory()
                } label: {
                    Label("打开保存位置", systemImage: "folder")
                }
            }
        }
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: summaryStore.summaries) { _, _ in
            reconcileSelection()
        }
    }

    private var summaryList: some View {
        List(selection: $selectedSummaryID) {
            Section("最近保存") {
                ForEach(summaryStore.summaries) { summary in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(summary.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(summary.periodDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("保存于 \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .tag(summary.id)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var summaryDetail: some View {
        if let summary = selectedSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(summary.title)
                        .font(.title2.weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("覆盖时段：\(summary.periodDescription)")
                        Text("保存时间：\(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Divider()
                    Text(summary.content)
                        .font(.body)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("选择一条总结查看内容")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有保存的总结")
                .font(.headline)
            Text("先在 AI 对话中生成并预览总结，再明确确认保存；保存后的总结会显示在这里。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Text("这里只读取新格式 JSON 文件，不会迁移旧总结记录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.regularMaterial)
    }

    private func reconcileSelection() {
        if let selectedSummaryID,
           summaryStore.summaries.contains(where: { $0.id == selectedSummaryID }) {
            return
        }
        selectedSummaryID = summaryStore.summaries.first?.id
    }

    private func openSummaryDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: summaryStore.directoryURL,
                withIntermediateDirectories: true
            )
            if NSWorkspace.shared.open(summaryStore.directoryURL) {
                directoryError = nil
            } else {
                directoryError = "无法打开总结保存位置：\(summaryStore.directoryURL.path)"
            }
        } catch {
            directoryError = "无法创建总结保存位置：\(error.localizedDescription)"
        }
    }
}
