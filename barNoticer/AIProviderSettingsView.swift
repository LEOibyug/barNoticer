import SwiftUI

struct AIProviderSettingsView: View {
    @Binding var draft: AISettingsDraft
    var automaticallyDiscover = true
    @State private var models: [String] = []
    @State private var discoveryStatus = ""
    @State private var balance: String?
    @State private var isDiscovering = false
    @State private var refreshID = 0
    @State private var probe = AIProviderProbeResult()
    @State private var isTesting = false
    @State private var probeTask: Task<Void, Never>?
    @FocusState private var modelFocused: Bool

    private struct DiscoveryID: Equatable {
        let id: UUID
        let url: String
        let key: String
        let format: AIResponseFormat
        let refresh: Int
    }
    private var discoveryID: DiscoveryID {
        DiscoveryID(id: draft.provider.id, url: draft.baseURLText, key: draft.apiKey,
            format: draft.provider.responseFormat, refresh: refreshID)
    }
    private var candidates: [String] { AIProviderDiagnostics.candidates(in: models, prefix: draft.model) }

    var body: some View {
        SettingsSection(title: "模型配置", footer: "配置自动保存。按顺序模式从第一套开始，仅在请求失败时尝试下一套；测试连接只检查当前编辑配置。") {
            field("使用方式") {
                Picker("使用方式", selection: Binding(get: { draft.collection.mode }, set: { draft.setMode($0) })) {
                    ForEach(AIProviderMode.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            if draft.collection.mode == .single {
                field("使用配置") {
                    Picker("使用配置", selection: Binding(get: { draft.collection.activeID }, set: { draft.setActive($0) })) {
                        ForEach(draft.collection.providers) { Text(displayName($0)).tag($0.id) }
                    }.labelsHidden()
                }
            }
            field("编辑配置") {
                HStack {
                    Picker("编辑配置", selection: $draft.editingID) {
                        ForEach(Array(draft.collection.providers.enumerated()), id: \.element.id) { index, provider in
                            Text("\(index + 1). \(displayName(provider))").tag(provider.id)
                        }
                    }.labelsHidden()
                    Button { draft.addProvider() } label: { Image(systemName: "plus") }.help("新增供应商")
                    Button { draft.removeProvider() } label: { Image(systemName: "minus") }
                        .disabled(draft.collection.providers.count < 2).help("删除当前配置")
                }
            }
            if draft.collection.mode == .ordered {
                field("尝试顺序") {
                    HStack {
                        Text("第 \((draft.collection.providers.firstIndex { $0.id == draft.editingID } ?? 0) + 1) 顺位")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("上移") { draft.moveProvider(by: -1) }.disabled(draft.collection.providers.first?.id == draft.editingID)
                        Button("下移") { draft.moveProvider(by: 1) }.disabled(draft.collection.providers.last?.id == draft.editingID)
                    }
                }
            }
            field("供应商名") {
                TextField("供应商名", text: providerBinding(\.name), prompt: Text("例如：我的供应商").foregroundStyle(.tertiary))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("Base URL") {
                TextField("Base URL", text: $draft.baseURLText, prompt: Text("https://api.openai.com/v1").foregroundStyle(.tertiary))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("响应格式") {
                Picker("响应格式", selection: providerBinding(\.responseFormat)) {
                    ForEach(AIResponseFormat.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            field("API Key") {
                SecureField("API Key", text: $draft.apiKey, prompt: Text("sk-…").foregroundStyle(.tertiary))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("模型") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("模型", text: $draft.model, prompt: Text("例如：gpt-4o-mini").foregroundStyle(.tertiary))
                        .labelsHidden().textFieldStyle(.roundedBorder).focused($modelFocused)
                    if modelFocused, !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(candidates, id: \.self) { candidate in
                                Button {
                                    draft.model = candidate
                                    modelFocused = false
                                } label: {
                                    Text(candidate).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).padding(.horizontal, 8)
                                }.buttonStyle(.plain).focusable(false)
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            field("模型列表") {
                HStack {
                    if isDiscovering { ProgressView().controlSize(.small) }
                    Text(discoveryStatus.isEmpty ? "填写 URL 和 Key 后自动获取，也可手动输入模型名" : discoveryStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { refreshID += 1 }.disabled(!draft.provider.canDiscover)
                }
            }
            field("余额") {
                Text(balance ?? "暂无数据").foregroundStyle(balance == nil ? .secondary : .primary)
            }
            field("连接测试") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { testCurrent() } label: {
                            Label(isTesting ? "测试中…" : "测试当前配置", systemImage: "network")
                        }.disabled(isTesting || !draft.canTestConnection)
                        if isTesting { ProgressView().controlSize(.small) }
                    }
                    Text("文字：\(probe.text)").font(.caption).foregroundStyle(.secondary)
                    Text("视觉：\(probe.vision)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: discoveryID) { if automaticallyDiscover { await discover() } }
        .onChange(of: draft.provider) { _, _ in
            probeTask?.cancel()
            isTesting = false
            probe = AIProviderProbeResult()
        }
        .onDisappear { probeTask?.cancel() }
    }

    private func displayName(_ provider: AIProviderConfiguration) -> String { provider.name.isEmpty ? "未命名供应商" : provider.name }
    private func providerBinding<Value>(_ keyPath: WritableKeyPath<AIProviderConfiguration, Value>) -> Binding<Value> {
        Binding(get: { draft.provider[keyPath: keyPath] }, set: { draft.provider[keyPath: keyPath] = $0 })
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary).frame(width: 82, alignment: .leading).padding(.top, 4)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity)
    }

    @MainActor
    private func discover() async {
        let identity = discoveryID
        let provider = draft.provider
        models = []; balance = nil; discoveryStatus = ""; isDiscovering = false
        guard provider.canDiscover else { return }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        guard !Task.isCancelled, identity == discoveryID else { return }
        isDiscovering = true
        let diagnostics = AIProviderDiagnostics()
        async let balanceResult = diagnostics.balance(for: provider)
        do {
            let fetched = try await diagnostics.models(for: provider)
            guard !Task.isCancelled, identity == discoveryID else { return }
            models = fetched
            discoveryStatus = fetched.isEmpty ? "未返回模型，可手动输入" : "已获取 \(fetched.count) 个模型，输入前缀可补全"
        } catch {
            guard !Task.isCancelled, identity == discoveryID else { return }
            discoveryStatus = "暂时无法获取模型，可手动输入"
        }
        let fetchedBalance = await balanceResult
        guard !Task.isCancelled, identity == discoveryID else { return }
        balance = fetchedBalance
        isDiscovering = false
    }

    private func testCurrent() {
        let provider = draft.provider
        let challenge = AIProviderDiagnostics.visionChallenge()
        isTesting = true
        probe = AIProviderProbeResult(text: "测试中…", vision: "等待文字测试")
        probeTask = Task { @MainActor in
            let result = await AIProviderDiagnostics().probe(provider, imageURL: challenge.url, expectedCode: challenge.code)
            guard !Task.isCancelled, provider == draft.provider else { return }
            probe = result
            isTesting = false
        }
    }
}
