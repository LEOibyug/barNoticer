import AppKit
import Foundation

struct AIProviderDiagnostics {
    var session: URLSession = .shared

    func models(for provider: AIProviderConfiguration) async throws -> [String] {
        guard let base = provider.url, provider.canDiscover else { throw AIClientError.invalidSettings }
        var models: [String] = []
        var after: String?
        for _ in 0..<10 {
            var url = AIProviderTransport.endpoint(base: base, format: provider.responseFormat, path: "models")
            if provider.responseFormat == .anthropic {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                parts.queryItems = [URLQueryItem(name: "limit", value: "100")]
                if let after { parts.queryItems?.append(URLQueryItem(name: "after_id", value: after)) }
                url = parts.url!
            }
            let root = try await get(url, provider: provider)
            guard let data = root["data"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
            models += data.compactMap { $0["id"] as? String }
            guard root["has_more"] as? Bool == true, let next = root["last_id"] as? String,
                  after != next else { break }
            after = next
        }
        return Array(Set(models)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func candidates(in models: [String], prefix: String) -> [String] {
        let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Array(models.filter { $0.lowercased().hasPrefix(prefix) && $0 != prefix }.prefix(8))
    }

    func balance(for provider: AIProviderConfiguration) async -> String? {
        guard let base = provider.url, provider.canDiscover else { return nil }
        // There is no standard balance endpoint. Probe known compatible schemas only.
        var urls = ["user/balance", "dashboard/billing/credit_grants"].map {
            AIProviderTransport.endpoint(base: base, format: provider.responseFormat, path: $0)
        }
        // DeepSeek accepts a versioned inference URL but documents balance at the origin.
        if base.host == "api.deepseek.com", var origin = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            origin.path = "/user/balance"
            if let url = origin.url, !urls.contains(url) { urls.insert(url, at: 0) }
        }
        for url in urls {
            guard !Task.isCancelled else { return nil }
            if let root = try? await get(url, provider: provider), let balance = Self.parseBalance(root) { return balance }
        }
        return nil
    }

    static func parseBalance(_ root: [String: Any]) -> String? {
        func amount(_ value: Any?) -> String? {
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue
            guard let text, let number = Double(text), number.isFinite else { return nil }
            return number.formatted(.number.precision(.fractionLength(0...4)))
        }
        if let infos = root["balance_infos"] as? [[String: Any]] {
            let values = infos.compactMap { entry -> String? in
                guard let currency = entry["currency"] as? String, let value = amount(entry["total_balance"]) else { return nil }
                return "\(value) \(currency)"
            }
            return values.isEmpty ? nil : values.joined(separator: " · ")
        }
        if let value = amount(root["total_available"]) { return "\(value) USD" }
        return nil
    }

    private func get(_ url: URL, provider: AIProviderConfiguration) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        AIProviderTransport.authorize(&request, key: provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), format: provider.responseFormat)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIClientError.invalidResponse }
        return root
    }

    func probe(_ provider: AIProviderConfiguration, imageURL: String, expectedCode: String) async -> AIProviderProbeResult {
        let client = AIClient(session: session)
        var result = AIProviderProbeResult()
        do {
            let response = try await client.send(messages: [.init(role: "user", content: "请只回复 OK。")],
                settings: provider.settings, apiKey: provider.apiKey, tools: [], timeout: 20)
            result.text = response.content.isEmpty ? "未通过：没有文字响应" : "连接可用"
        } catch {
            result.text = "未通过：\(error.localizedDescription)"
            return result
        }
        guard !Task.isCancelled else { return result }
        do {
            let response = try await client.send(messages: [.init(role: "user", content: "读取图片中的四位数字，只回复数字。",
                imageURLs: [imageURL])], settings: provider.settings, apiKey: provider.apiKey, tools: [], timeout: 25)
            let digits = response.content.filter(\.isNumber)
            result.vision = digits == expectedCode ? "已验证，可识别图片" : "未通过：未正确识别测试图片"
        } catch {
            result.vision = "未通过：\(error.localizedDescription)"
        }
        return result
    }

    @MainActor
    static func visionChallenge() -> (url: String, code: String) {
        let code = String(Int.random(in: 1000...9999))
        let image = NSImage(size: NSSize(width: 240, height: 100))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 240, height: 100)).fill()
        (code as NSString).draw(at: NSPoint(x: 38, y: 20), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = bitmap.representation(using: .png, properties: [:])!
        return ("data:image/png;base64," + png.base64EncodedString(), code)
    }
}

struct AIProviderProbeResult: Equatable {
    var text = "未测试"
    var vision = "未测试"
}
