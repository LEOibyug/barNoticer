import AppKit
import Foundation

struct AIProviderDiagnostics {
    var session: URLSession = .shared
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func models(for provider: AIProviderConfiguration) async throws -> [String] {
        guard let base = provider.url, provider.canDiscover(environment: environment) else { throw AIClientError.invalidSettings }
        var models: [String] = []
        if provider.responseFormat == .gemini {
            var pageToken: String?
            for _ in 0..<10 {
                var url = AIProviderTransport.endpoint(base: base, format: .gemini, path: "models")
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                var items = [URLQueryItem(name: "pageSize", value: "100")]
                if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                parts.queryItems = items
                url = parts.url!
                let root = try await get(url, provider: provider)
                guard let entries = root["models"] as? [[String: Any]] else { throw AIClientError.invalidResponse }
                for entry in entries {
                    if let methods = entry["supportedGenerationMethods"] as? [String],
                       !methods.contains("generateContent") {
                        continue
                    }
                    guard var name = entry["name"] as? String, !name.isEmpty else { continue }
                    if name.hasPrefix("models/") { name.removeFirst("models/".count) }
                    models.append(name)
                }
                guard let next = root["nextPageToken"] as? String, !next.isEmpty, next != pageToken else { break }
                pageToken = next
            }
            return Array(Set(models)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
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
        candidates(in: models, query: prefix)
    }

    static func candidates(in models: [String], query: String, limit: Int = 12) -> [String] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return Array(models.prefix(limit))
        }

        let separators = Set<Character>(["-", "/", "_", ".", ":"])
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let compactChars = Array(trimmed.filter { !$0.isWhitespace })

        struct ScoredCandidate {
            let model: String
            let tier: Int
            let primary: Int
            let secondary: Int
        }

        func isSegmentBoundary(in text: String, at index: String.Index) -> Bool {
            guard index > text.startIndex else { return false }
            let prev = text[text.index(before: index)]
            return separators.contains(prev) || prev.isWhitespace
        }

        func earliestBoundaryOffset(in text: String, substring: String) -> Int? {
            var searchStart = text.startIndex
            while let range = text.range(of: substring, range: searchStart..<text.endIndex) {
                if isSegmentBoundary(in: text, at: range.lowerBound) {
                    return text.distance(from: text.startIndex, to: range.lowerBound)
                }
                searchStart = text.index(after: range.lowerBound)
            }
            return nil
        }

        func subsequenceSpan(in text: String, chars: [Character]) -> (span: Int, start: Int)? {
            guard !chars.isEmpty else { return nil }
            var charIndex = 0
            var firstPos: Int?
            var lastPos = 0
            for (offset, ch) in text.enumerated() where ch == chars[charIndex] {
                if firstPos == nil { firstPos = offset }
                lastPos = offset
                charIndex += 1
                if charIndex == chars.count {
                    return (lastPos - (firstPos ?? 0), firstPos ?? 0)
                }
            }
            return nil
        }

        func score(_ model: String) -> ScoredCandidate? {
            let lower = model.lowercased()
            if lower == trimmed { return nil }

            // Tier 0: Prefix match
            if lower.hasPrefix(trimmed) {
                return ScoredCandidate(model: model, tier: 0, primary: 0, secondary: lower.count)
            }

            // Tier 1: Segment-boundary match (after -, /, _, ., :, or whitespace)
            if let offset = earliestBoundaryOffset(in: lower, substring: trimmed) {
                return ScoredCandidate(model: model, tier: 1, primary: offset, secondary: lower.count)
            }

            // Tier 2: General substring match
            if let range = lower.range(of: trimmed) {
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                return ScoredCandidate(model: model, tier: 2, primary: offset, secondary: lower.count)
            }

            // Tier 3: Multi-token match (all whitespace-separated tokens appear)
            if tokens.count > 1 {
                var tokenOffsets: [Int] = []
                tokenOffsets.reserveCapacity(tokens.count)
                var searchFrom = lower.startIndex
                var inOrder = true
                var allFound = true
                for token in tokens {
                    if let orderedRange = lower.range(of: token, range: searchFrom..<lower.endIndex) {
                        tokenOffsets.append(lower.distance(from: lower.startIndex, to: orderedRange.lowerBound))
                        searchFrom = orderedRange.upperBound
                    } else if let anyRange = lower.range(of: token) {
                        inOrder = false
                        tokenOffsets.append(lower.distance(from: lower.startIndex, to: anyRange.lowerBound))
                    } else {
                        allFound = false
                        break
                    }
                }
                if allFound, let firstOffset = tokenOffsets.min() {
                    return ScoredCandidate(
                        model: model,
                        tier: 3,
                        primary: inOrder ? 0 : 1,
                        secondary: firstOffset
                    )
                }
            }

            // Tier 4: Ordered subsequence (fuzzy) match
            if let match = subsequenceSpan(in: lower, chars: compactChars) {
                return ScoredCandidate(model: model, tier: 4, primary: match.span, secondary: match.start)
            }

            return nil
        }

        let ranked = models.compactMap(score).sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
            if lhs.secondary != rhs.secondary { return lhs.secondary < rhs.secondary }
            return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
        }
        return Array(ranked.prefix(limit).map(\.model))
    }

    func balance(for provider: AIProviderConfiguration) async -> String? {
        guard provider.responseFormat != .gemini, let base = provider.url, provider.canDiscover(environment: environment) else { return nil }
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
        let apiKey = provider.resolvedAPIKey(environment: environment)
        AIProviderTransport.authorize(&request, key: apiKey, format: provider.responseFormat)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw AIClientError.requestFailed(http.statusCode, AIProviderTransport.failureMessage(data, apiKey: apiKey))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIClientError.invalidResponse }
        return root
    }

    func probe(_ provider: AIProviderConfiguration, imageURL: String, expectedCode: String) async -> AIProviderProbeResult {
        let client = AIClient(session: session, environment: environment)
        let apiKey = provider.resolvedAPIKey(environment: environment)
        var result = AIProviderProbeResult()
        do {
            let response = try await client.send(messages: [.init(role: "user", content: "请只回复 OK。")],
                settings: provider.settings, apiKey: apiKey, tools: [], timeout: 20)
            result.text = response.content.isEmpty ? "未通过：没有文字响应" : "连接可用"
        } catch {
            result.text = "未通过：\(error.localizedDescription)"
            return result
        }
        guard !Task.isCancelled else { return result }
        do {
            let response = try await client.send(messages: [.init(role: "user", content: "读取图片中的四位数字，只回复数字。",
                imageURLs: [imageURL])], settings: provider.settings, apiKey: apiKey, tools: [], timeout: 25)
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
