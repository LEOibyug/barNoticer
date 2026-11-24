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
        let keySource: AIAPIKeySource
        let key: String
        let format: AIResponseFormat
        let refresh: Int
    }
    private var discoveryID: DiscoveryID {
        DiscoveryID(
            id: draft.provider.id,
            url: draft.baseURLText,
            keySource: draft.provider.effectiveAPIKeySource,
            key: draft.resolvedAPIKey,
            format: draft.provider.responseFormat,
            refresh: refreshID
        )
    }
    private var candidates: [String] { AIProviderDiagnostics.candidates(in: models, query: draft.model) }

    var body: some View {
        overviewSection
        editorSection
    }

    private var overviewSection: some View {
        SettingsSection(
            title: "供应商",
            footer: "仅使用指定配置时只有当前使用项会参与请求；按列表顺序尝试时，将从第 1 顺位开始并在失败后依次回退。点击列表项即可编辑，不会改变当前使用配置。"
        ) {
            field("使用方式") {
                Picker("使用方式", selection: Binding(get: { draft.collection.mode }, set: { draft.setMode($0) })) {
                    ForEach(AIProviderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(spacing: 6) {
                ForEach(Array(draft.collection.providers.enumerated()), id: \.element.id) { index, item in
                    providerRow(item, index: index)
                }
            }

            HStack {
                Menu {
                    Button("自定义供应商") {
                        modelFocused = false
                        draft.addProvider()
                    }
                    Button("Google AI Studio (Gemini)") {
                        modelFocused = false
                        draft.addGoogleAIStudioProvider()
                    }
                } label: {
                    Label("新增供应商", systemImage: "plus")
                }
                .fixedSize()

                Spacer()

                Text("共 \(draft.collection.providers.count) 套配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var editorSection: some View {
        SettingsSection(
            title: "编辑配置 · \(displayName(draft.provider))",
            footer: "配置修改自动保存；测试连接仅检查当前正在编辑的这套配置。"
        ) {
            HStack(spacing: 10) {
                if draft.collection.mode == .single {
                    if draft.provider.id == draft.collection.activeID {
                        Label("当前正在使用此配置", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                    } else {
                        Text("当前为备用配置")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("设为当前使用") {
                            draft.setActive(draft.provider.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    let rank = (draft.collection.providers.firstIndex { $0.id == draft.provider.id } ?? 0) + 1
                    Text("当前位于第 \(rank) 顺位（按列表顺序尝试）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("删除配置", role: .destructive) {
                    modelFocused = false
                    draft.removeProvider(id: draft.provider.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(draft.collection.providers.count < 2)
            }

            field("供应商名") {
                TextField("供应商名", text: providerBinding(\.name), prompt: Text("例如：我的供应商").foregroundStyle(.tertiary))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("Base URL") {
                TextField("Base URL", text: $draft.baseURLText, prompt: Text(draft.provider.responseFormat.defaultBaseURL).foregroundStyle(.tertiary))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            field("响应格式") {
                Picker("响应格式", selection: Binding(
                    get: { draft.provider.responseFormat },
                    set: { draft.setResponseFormat($0) }
                )) {
                    ForEach(AIResponseFormat.allCases) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            field("API Key") {
                VStack(alignment: .leading, spacing: 6) {
                    if draft.provider.responseFormat == .gemini {
                        Picker("Key 来源", selection: providerBinding(\.apiKeySource)) {
                            ForEach(AIAPIKeySource.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if draft.provider.effectiveAPIKeySource == .environment {
                        if draft.hasEnvironmentGeminiAPIKey {
                            Text("已从环境变量 \(AIEnvironmentAPIKey.geminiVariableName) 读取，不会写入本机配置文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未检测到环境变量 \(AIEnvironmentAPIKey.geminiVariableName)。启动应用前注入该变量，或切换为手动输入。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        SecureField(
                            "API Key",
                            text: $draft.apiKey,
                            prompt: Text(draft.provider.responseFormat == .gemini ? "AIza…" : "sk-…").foregroundStyle(.tertiary)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            field("模型") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("模型", text: $draft.model, prompt: Text("例如：\(draft.provider.responseFormat.defaultModel)").foregroundStyle(.tertiary))
                        .labelsHidden().textFieldStyle(.roundedBorder).focused($modelFocused)
                    if modelFocused, !candidates.isEmpty {
                        let list = VStack(alignment: .leading, spacing: 0) {
                            ForEach(candidates, id: \.self) { candidate in
                                Button {
                                    draft.model = candidate
                                    modelFocused = false
                                } label: {
                                    Text(candidate)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 5)
                                        .padding(.horizontal, 8)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                            }
                        }
                        Group {
                            if candidates.count > 6 {
                                ScrollView { list }
                                    .frame(maxHeight: 200)
                            } else {
                                list
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if draft.provider.responseFormat.supportsReasoningEffort {
                field("推理强度") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("推理强度", selection: providerBinding(\.reasoningEffort)) {
                            Text("供应商默认（不发送）").tag(nil as AIReasoningEffort?)
                            ForEach(AIReasoningEffort.allCases) { effort in
                                Text(effort.rawValue).tag(Optional(effort))
                            }
                        }.labelsHidden()
                        Text(draft.provider.responseFormat == .responses
                            ? "Responses 使用 reasoning.effort，并请求自动推理摘要（none 除外）；仅展示实际返回的摘要。"
                            : "Chat Completions 使用 reasoning_effort；默认不发送此参数。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("支持的强度取决于模型和供应商；不支持的参数可能导致请求失败。none 与默认不发送不同。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            field("模型列表") {
                HStack {
                    if isDiscovering { ProgressView().controlSize(.small) }
                    Text(discoveryStatus.isEmpty ? "填写 URL 和 Key 后自动获取，也可手动输入模型名" : discoveryStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !models.isEmpty {
                        Menu("选择") {
                            ForEach(models, id: \.self) { model in
                                Button(model) {
                                    draft.model = model
                                    modelFocused = false
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Button("刷新") { refreshID += 1 }.disabled(!draft.canDiscover)
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
        .onChange(of: draft.editingID) { _, _ in
            modelFocused = false
        }
        .onChange(of: draft.provider) { _, _ in
            probeTask?.cancel()
            isTesting = false
            probe = AIProviderProbeResult()
        }
        .onDisappear { probeTask?.cancel() }
    }

    private func providerRow(_ item: AIProviderConfiguration, index: Int) -> some View {
        let isEditing = item.id == draft.editingID
        let isActive = item.id == draft.collection.activeID
        let isReady = item.isReady(environment: draft.environment)
        let modelText = item.model.trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 10) {
            if draft.collection.mode == .single {
                Button {
                    draft.setActive(item.id)
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help(isActive ? "当前使用配置" : "设为当前使用")
            } else {
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.secondary.opacity(0.14)))
            }

            Button {
                modelFocused = false
                draft.editingID = item.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName(item))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if draft.collection.mode == .single, isActive {
                            statusTag("当前使用", tint: .accentColor)
                        }
                        if isEditing {
                            statusTag("编辑中", tint: .secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("\(item.responseFormat.title) · \(modelText.isEmpty ? "未设置模型" : modelText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !isReady {
                            Text("· 待完善配置")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if draft.collection.mode == .single {
                if !isActive {
                    Button("使用") {
                        draft.setActive(item.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 4) {
                    Button { draft.moveProvider(id: item.id, by: -1) } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("上移")

                    Button { draft.moveProvider(id: item.id, by: 1) } label: {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == draft.collection.providers.count - 1)
                    .help("下移")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEditing ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isEditing ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }

    private func statusTag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
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
        let environment = draft.environment
        models = []; balance = nil; discoveryStatus = ""; isDiscovering = false
        guard provider.canDiscover(environment: environment) else { return }
        do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
        guard !Task.isCancelled, identity == discoveryID else { return }
        isDiscovering = true
        let diagnostics = AIProviderDiagnostics(environment: environment)
        async let balanceResult = diagnostics.balance(for: provider)
        do {
            let fetched = try await diagnostics.models(for: provider)
            guard !Task.isCancelled, identity == discoveryID else { return }
            models = fetched
            discoveryStatus = fetched.isEmpty ? "未返回模型，可手动输入" : "已获取 \(fetched.count) 个模型，输入关键词可筛选补全"
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
        let environment = draft.environment
        let challenge = AIProviderDiagnostics.visionChallenge()
        isTesting = true
        probe = AIProviderProbeResult(text: "测试中…", vision: "等待文字测试")
        probeTask = Task { @MainActor in
            let result = await AIProviderDiagnostics(environment: environment).probe(provider, imageURL: challenge.url, expectedCode: challenge.code)
            guard !Task.isCancelled, provider == draft.provider else { return }
            probe = result
            isTesting = false
        }
    }
}
