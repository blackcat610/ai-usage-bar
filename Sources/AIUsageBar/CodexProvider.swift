import Foundation

/// Codex usage via the ChatGPT-login tokens the Codex CLI / ChatGPT desktop
/// app keep in ~/.codex/auth.json.
final class CodexProvider {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let userAgent = "AIUsageBar/1.0 (personal menu-bar usage monitor)"

    static var authPath: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    struct Tokens {
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var accountID: String?

        init?(json: [String: Any]) {
            guard let t = json["tokens"] as? [String: Any],
                  let a = t["access_token"] as? String, let r = t["refresh_token"] as? String else { return nil }
            accessToken = a
            refreshToken = r
            idToken = t["id_token"] as? String
            accountID = t["account_id"] as? String
        }

        /// JWT exp, when decodable.
        var expiresAt: Date? {
            let parts = accessToken.split(separator: ".")
            guard parts.count >= 2 else { return nil }
            var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b), let j = HTTP.json(d), let exp = j["exp"] as? Double else { return nil }
            return Date(timeIntervalSince1970: exp)
        }
    }

    func fetch() async throws -> ProviderSnapshot {
        var tokens = try loadTokens()
        if let exp = tokens.expiresAt, exp < Date().addingTimeInterval(60) {
            tokens = try await refresh(tokens)
        }
        var (status, data) = try await callUsage(tokens)
        if status == 401 {
            tokens = try await refresh(tokens)
            (status, data) = try await callUsage(tokens)
        }
        guard status == 200 else {
            if status == 401 || status == 403 {
                throw ProviderError("Codex 인증이 만료되었습니다. Codex/ChatGPT 앱에서 다시 로그인하세요.", "Codex authentication expired. Sign in again in Codex or the ChatGPT app.", needsLogin: true)
            }
            throw ProviderError("Codex 사용량 조회 실패 (HTTP \(status)): \(HTTP.errorSnippet(data))", "Codex usage request failed (HTTP \(status)): \(HTTP.errorSnippet(data))")
        }
        guard let json = HTTP.json(data) else { throw ProviderError("Codex 응답을 해석할 수 없습니다.", "Could not parse the Codex response.") }
        return Self.parse(json)
    }

    // MARK: - auth.json

    private func loadTokens() throws -> Tokens {
        guard let data = try? Data(contentsOf: Self.authPath), let json = HTTP.json(data) else {
            throw ProviderError("~/.codex/auth.json 이 없습니다. Codex에 ChatGPT 계정으로 로그인하세요.", "~/.codex/auth.json not found. Sign in to Codex with your ChatGPT account.", needsLogin: true)
        }
        guard let t = Tokens(json: json) else {
            throw ProviderError("Codex가 ChatGPT 로그인 상태가 아닙니다(API 키 모드는 사용량 조회 불가).", "Codex is not signed in with ChatGPT (API-key mode has no usage data).", needsLogin: true)
        }
        return t
    }

    private func refresh(_ t: Tokens) async throws -> Tokens {
        let body: [String: Any] = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": t.refreshToken,
            "scope": "openid profile email",
        ]
        let (status, data) = try await HTTP.request(Self.tokenURL, method: "POST",
                                                    headers: ["User-Agent": Self.userAgent], jsonBody: body)
        guard status == 200, let j = HTTP.json(data), let access = j["access_token"] as? String else {
            throw ProviderError("Codex 토큰 갱신 실패 (HTTP \(status)): \(HTTP.errorSnippet(data))", "Codex token refresh failed (HTTP \(status)): \(HTTP.errorSnippet(data))",
                                needsLogin: status == 400 || status == 401)
        }
        var next = t
        next.accessToken = access
        if let r = j["refresh_token"] as? String { next.refreshToken = r }
        if let i = j["id_token"] as? String { next.idToken = i }

        // Write back the same way codex-rs does, so the CLI/desktop keep working.
        if let data = try? Data(contentsOf: Self.authPath), var full = HTTP.json(data) {
            var tk = (full["tokens"] as? [String: Any]) ?? [:]
            tk["access_token"] = next.accessToken
            tk["refresh_token"] = next.refreshToken
            if let i = next.idToken { tk["id_token"] = i }
            full["tokens"] = tk
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            full["last_refresh"] = f.string(from: Date())
            if let out = try? JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: Self.authPath, options: .atomic)
            }
        }
        return next
    }

    private func callUsage(_ t: Tokens) async throws -> (Int, Data) {
        var h = ["Authorization": "Bearer \(t.accessToken)", "User-Agent": Self.userAgent, "Accept": "application/json"]
        if let a = t.accountID { h["ChatGPT-Account-Id"] = a }
        return try await HTTP.request(Self.usageURL, headers: h)
    }

    // MARK: - Parsing

    static func parseWindow(_ obj: [String: Any], id: String, prefix: String, primary: Bool) -> UsageWindow? {
        guard let used = obj["used_percent"] as? Double else { return nil }
        let secs = obj["limit_window_seconds"] as? Int
        var resets: Date?
        if let at = obj["reset_at"] as? Double { resets = Date(timeIntervalSince1970: at) }
        else if let after = obj["reset_after_seconds"] as? Double { resets = Date().addingTimeInterval(after) }
        return UsageWindow(id: id, kind: .codex(seconds: secs, limitName: prefix.isEmpty ? nil : prefix),
                           usedPercent: used, resetsAt: resets, isPrimary: primary)
    }

    static func parse(_ json: [String: Any]) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        if let rl = json["rate_limit"] as? [String: Any] {
            if let p = rl["primary_window"] as? [String: Any], let w = parseWindow(p, id: "primary", prefix: "", primary: true) { windows.append(w) }
            if let s = rl["secondary_window"] as? [String: Any], let w = parseWindow(s, id: "secondary", prefix: "", primary: true) { windows.append(w) }
        }
        if let extras = json["additional_rate_limits"] as? [[String: Any]] {
            for (i, e) in extras.enumerated() {
                let name = (e["limit_name"] as? String) ?? "추가"
                guard let rl = e["rate_limit"] as? [String: Any] else { continue }
                if let p = rl["primary_window"] as? [String: Any], let w = parseWindow(p, id: "extra\(i)p", prefix: name, primary: false) { windows.append(w) }
                if let s = rl["secondary_window"] as? [String: Any], let w = parseWindow(s, id: "extra\(i)s", prefix: name, primary: false) { windows.append(w) }
            }
        }
        var plan: String?
        if let p = json["plan_type"] as? String { plan = p.capitalized }
        var notes: [Note] = []
        if let c = json["credits"] as? [String: Any], (c["has_credits"] as? Bool) == true, let b = c["balance"] as? String {
            notes.append(.credits(b))
        }
        if let rl = json["rate_limit"] as? [String: Any], (rl["limit_reached"] as? Bool) == true {
            notes.append(.limitReached)
        }
        return ProviderSnapshot(windows: windows, planLabel: plan, notes: notes, updatedAt: Date())
    }
}
