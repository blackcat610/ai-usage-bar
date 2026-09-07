import Foundation
import CryptoKit

/// Claude usage via the Claude Code OAuth token.
///
/// Token sources, in order:
///  1. The app's own OAuth credentials (obtained through the in-app login flow,
///     stored in the app's own keychain item) — refreshed freely by us.
///  2. Claude Code CLI's keychain item ("Claude Code-credentials"). If its
///     access token is expired we refresh it and write the rotated tokens back
///     exactly the way Claude Code does, so the CLI keeps working.
final class ClaudeProvider {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let authorizeURL = "https://platform.claude.com/oauth/authorize"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    static let loginScopes = "user:profile user:inference"
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "AIUsageBar/1.0 (personal menu-bar usage monitor)"

    static let ownService = "AIUsageBar"
    static let ownAccount = "claude-oauth"
    static let cliService = "Claude Code-credentials"

    struct Creds {
        var accessToken: String
        var refreshToken: String
        var expiresAtMs: Double
        var subscriptionType: String?
        var rateLimitTier: String?

        var isExpired: Bool { expiresAtMs / 1000 < Date().timeIntervalSince1970 + 60 }

        init?(json: [String: Any]) {
            guard let a = json["accessToken"] as? String, let r = json["refreshToken"] as? String else { return nil }
            accessToken = a
            refreshToken = r
            expiresAtMs = (json["expiresAt"] as? Double) ?? 0
            subscriptionType = json["subscriptionType"] as? String
            rateLimitTier = json["rateLimitTier"] as? String
        }

        func merged(into json: [String: Any]) -> [String: Any] {
            var j = json
            j["accessToken"] = accessToken
            j["refreshToken"] = refreshToken
            j["expiresAt"] = Int64(expiresAtMs)
            if let s = subscriptionType { j["subscriptionType"] = s }
            if let t = rateLimitTier { j["rateLimitTier"] = t }
            return j
        }
    }

    private enum Source { case own, cli, cliFile }

    // MARK: - Public

    private var usageBlockedUntil: Date = .distantPast

    func fetch() async throws -> ProviderSnapshot {
        if Date() < usageBlockedUntil {
            let mins = max(1, Int(usageBlockedUntil.timeIntervalSinceNow / 60))
            throw ProviderError("Claude 사용량 API 호출 제한(429). \(mins)분 후 재시도합니다.", "Claude usage API rate-limited (429). Retrying in \(mins) min.")
        }
        var (creds, source) = try await loadCreds()
        if creds.isExpired {
            creds = try await refresh(creds, source: source)
        }
        var (status, data) = try await callUsage(creds.accessToken)
        if status == 401 {
            creds = try await refresh(creds, source: source)
            (status, data) = try await callUsage(creds.accessToken)
        }
        guard status == 200 else {
            if status == 403, HTTP.errorCode(data) == "oauth_not_allowed_for_organization" {
                throw ProviderError(
                    source == .own
                        ? "앱 전용 토큰이 Claude 구독이 없는 조직으로 발급되었습니다. '로그인 설정…'에서 앱 전용 토큰을 삭제하고, 구독이 있는 조직을 선택해 다시 로그인하세요."
                        : "이 로그인의 조직에는 Claude 구독이 없어 사용량을 조회할 수 없습니다.",
                    source == .own
                        ? "The app token belongs to an organization without a Claude subscription. Remove it in 'Sign-in settings…' and sign in again choosing the subscribed organization."
                        : "This login's organization has no Claude subscription, so usage cannot be read.",
                    needsLogin: true)
            }
            if status == 401 || status == 403 {
                throw ProviderError("Claude 인증이 만료되었습니다. 아래에서 다시 로그인하세요.", "Claude authentication expired. Sign in again below.", needsLogin: true)
            }
            if status == 429 {
                usageBlockedUntil = Date().addingTimeInterval(10 * 60)
                throw ProviderError("Claude 사용량 API 호출 제한(429). 10분 후 재시도합니다.", "Claude usage API rate-limited (429). Retrying in 10 min.")
            }
            throw ProviderError("Claude 사용량 조회 실패 (HTTP \(status)): \(HTTP.errorSnippet(data))", "Claude usage request failed (HTTP \(status)): \(HTTP.errorSnippet(data))")
        }
        guard let json = HTTP.json(data) else {
            throw ProviderError("Claude 응답을 해석할 수 없습니다.", "Could not parse the Claude response.")
        }
        var snap = Self.parse(json)
        snap.planLabel = Self.planLabel(creds)
        switch source {
        case .cli: snap.notes.append(.usingCLILogin)
        case .cliFile: snap.notes.append(.usingCLIFileLogin)
        case .own: break
        }
        return snap
    }

    // MARK: - Login (PKCE, manual code paste)

    private var pendingVerifier: String?
    /// After a failed refresh, hold off retrying for a while so a rate-limited
    /// token endpoint is not hammered every polling cycle.
    private var refreshBlockedUntil: Date = .distantPast
    private var lastRefreshError: ProviderError?

    func beginLogin() -> URL {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL()
        pendingVerifier = verifier
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
        var c = URLComponents(string: Self.authorizeURL)!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.loginScopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: verifier),
        ]
        return c.url!
    }

    func completeLogin(pasted: String) async throws {
        guard let verifier = pendingVerifier else {
            throw ProviderError("먼저 '브라우저에서 로그인'을 눌러 주세요.", "Click 'Sign in in browser' first.")
        }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else {
            throw ProviderError("인증 코드가 비어 있습니다.", "The authorization code is empty.")
        }
        let state = parts.count > 1 ? parts[1] : verifier
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": Self.clientID,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]
        let (status, data) = try await HTTP.request(Self.tokenURL, method: "POST",
                                                    headers: Self.headers(), jsonBody: body)
        guard status == 200, let j = HTTP.json(data),
              let access = j["access_token"] as? String,
              let refreshTok = j["refresh_token"] as? String else {
            throw ProviderError("코드 교환 실패 (HTTP \(status)): \(HTTP.errorSnippet(data))", "Code exchange failed (HTTP \(status)): \(HTTP.errorSnippet(data))")
        }
        let expiresIn = (j["expires_in"] as? Double) ?? 3600
        var stored: [String: Any] = [
            "accessToken": access,
            "refreshToken": refreshTok,
            "expiresAt": Int64((Date().timeIntervalSince1970 + expiresIn) * 1000),
        ]
        if let acct = j["account"] as? [String: Any], let s = acct["subscription_type"] as? String {
            stored["subscriptionType"] = s
        }

        // The approval page may bind the token to an API/Console organization, which has no
        // Claude subscription and is refused by the usage endpoint. Check before saving.
        let (pStatus, pData) = try await HTTP.request(Self.profileURL, headers: Self.headers(token: access))
        if pStatus == 200, let prof = HTTP.json(pData) {
            let org = prof["organization"] as? [String: Any]
            let orgName = (org?["name"] as? String) ?? "?"
            let orgType = (org?["organization_type"] as? String) ?? ""
            let acct = prof["account"] as? [String: Any]
            if !orgType.hasPrefix("claude") {
                throw ProviderError(
                    "승인된 조직 '\(orgName)'(\(orgType))에는 Claude 구독이 없어 사용량을 조회할 수 없습니다. 브라우저 승인 화면에서 Claude Pro/Max 구독이 있는 조직(보통 개인 계정)을 선택해 다시 로그인하세요.",
                    "The approved organization '\(orgName)' (\(orgType)) has no Claude subscription, so usage cannot be read. Sign in again and pick the organization that holds your Claude Pro/Max subscription (usually your personal one) on the approval page.")
            }
            if stored["subscriptionType"] == nil {
                if (acct?["has_claude_max"] as? Bool) == true { stored["subscriptionType"] = "max" }
                else if (acct?["has_claude_pro"] as? Bool) == true { stored["subscriptionType"] = "pro" }
            }
        }
        try Self.saveOwn(stored)
        pendingVerifier = nil
    }

    func hasOwnLogin() -> Bool { Self.loadOwnJSON() != nil }

    func forgetOwnLogin() { Keychain.delete(service: Self.ownService, account: Self.ownAccount) }

    // MARK: - Credentials

    /// Claude Code stores credentials in the Keychain on macOS, or in
    /// `$CLAUDE_CONFIG_DIR/.credentials.json` (default ~/.claude) when the Keychain is unavailable.
    static var cliCredentialsFile: URL {
        let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return dir.appendingPathComponent(".credentials.json")
    }

    private func loadCreds() async throws -> (Creds, Source) {
        try await Task.detached(priority: .utility) { () -> (Creds, Source) in
            if let own = Self.loadOwnJSON(), let c = Creds(json: own) { return (c, .own) }
            if let cli = Self.loadCLIJSON(), let o = cli["claudeAiOauth"] as? [String: Any], let c = Creds(json: o) {
                return (c, .cli)
            }
            if let file = Self.loadCLIFileJSON(), let o = file["claudeAiOauth"] as? [String: Any], let c = Creds(json: o) {
                return (c, .cliFile)
            }
            throw ProviderError("Claude 로그인 정보가 없습니다. 터미널에서 `claude`로 로그인하거나 아래에서 로그인하세요.",
                                "No Claude login found. Sign in with the `claude` CLI, or sign in below.", needsLogin: true)
        }.value
    }

    private func refresh(_ creds: Creds, source: Source) async throws -> Creds {
        if Date() < refreshBlockedUntil, let e = lastRefreshError {
            let mins = max(1, Int(refreshBlockedUntil.timeIntervalSinceNow / 60))
            throw ProviderError("\(e.text.ko) (\(mins)분 후 재시도)", "\(e.text.en) (retry in \(mins) min)", needsLogin: e.needsLogin)
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
        ]
        let (status, data) = try await HTTP.request(Self.tokenURL, method: "POST",
                                                    headers: Self.headers(), jsonBody: body)
        guard status == 200, let j = HTTP.json(data), let access = j["access_token"] as? String else {
            let snippet = HTTP.errorSnippet(data)
            let err = status == 429
                ? ProviderError("토큰 갱신이 잠시 제한되었습니다(429). \(snippet)", "Token refresh is rate-limited (429). \(snippet)")
                : ProviderError("토큰 갱신 실패 (HTTP \(status)). \(snippet)", "Token refresh failed (HTTP \(status)). \(snippet)",
                                needsLogin: status == 400 || status == 401)
            lastRefreshError = err
            // Back off so a stuck refresh does not get hammered every poll.
            refreshBlockedUntil = Date().addingTimeInterval(status == 429 ? 15 * 60 : 5 * 60)
            throw err
        }
        lastRefreshError = nil
        refreshBlockedUntil = .distantPast

        var next = creds
        next.accessToken = access
        if let r = j["refresh_token"] as? String { next.refreshToken = r }
        next.expiresAtMs = (Date().timeIntervalSince1970 + ((j["expires_in"] as? Double) ?? 3600)) * 1000

        try await Task.detached(priority: .utility) {
            switch source {
            case .own:
                var json = Self.loadOwnJSON() ?? [:]
                json = next.merged(into: json)
                try Self.saveOwn(json)
            case .cli:
                // Write the rotated tokens back so Claude Code CLI keeps working.
                guard var full = Self.loadCLIJSON(), let o = full["claudeAiOauth"] as? [String: Any] else {
                    throw ProviderError("Claude Code 키체인 항목을 다시 읽을 수 없어 갱신 토큰을 저장하지 못했습니다.",
                                        "Could not re-read the Claude Code Keychain item; the refreshed token was not saved.")
                }
                full["claudeAiOauth"] = next.merged(into: o)
                let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
                guard Keychain.write(service: Self.cliService, account: NSUserName(), value: String(decoding: data, as: UTF8.self)) else {
                    throw ProviderError("Claude Code 키체인 항목 쓰기 실패.", "Failed to write the Claude Code Keychain item.")
                }
            case .cliFile:
                guard var full = Self.loadCLIFileJSON(), let o = full["claudeAiOauth"] as? [String: Any] else {
                    throw ProviderError("Claude Code 자격증명 파일을 다시 읽을 수 없어 갱신 토큰을 저장하지 못했습니다.",
                                        "Could not re-read the Claude Code credentials file; the refreshed token was not saved.")
                }
                full["claudeAiOauth"] = next.merged(into: o)
                let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
                try data.write(to: Self.cliCredentialsFile, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.cliCredentialsFile.path)
            }
        }.value
        return next
    }

    private static func loadCLIFileJSON() -> [String: Any]? {
        guard let d = try? Data(contentsOf: cliCredentialsFile) else { return nil }
        return HTTP.json(d)
    }

    private static func loadOwnJSON() -> [String: Any]? {
        guard let s = Keychain.read(service: ownService, account: ownAccount), let d = s.data(using: .utf8) else { return nil }
        return HTTP.json(d)
    }

    private static func loadCLIJSON() -> [String: Any]? {
        guard let s = Keychain.read(service: cliService), let d = s.data(using: .utf8) else { return nil }
        return HTTP.json(d)
    }

    private static func saveOwn(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        guard Keychain.write(service: ownService, account: ownAccount, value: String(decoding: data, as: UTF8.self)) else {
            throw ProviderError("키체인 저장 실패.", "Failed to save to the Keychain.")
        }
    }

    // MARK: - HTTP

    private static func headers(token: String? = nil) -> [String: String] {
        var h = ["anthropic-beta": betaHeader, "User-Agent": userAgent, "Accept": "application/json"]
        if let token { h["Authorization"] = "Bearer \(token)" }
        return h
    }

    private func callUsage(_ token: String) async throws -> (Int, Data) {
        try await HTTP.request(Self.usageURL, headers: Self.headers(token: token))
    }

    // MARK: - Parsing

    static let knownWindows: [(key: String, primary: Bool)] = [
        ("five_hour", true), ("seven_day", true),
        ("seven_day_opus", false), ("seven_day_sonnet", false), ("seven_day_oauth_apps", false),
    ]

    static func parse(_ json: [String: Any]) -> ProviderSnapshot {
        var windows: [UsageWindow] = []

        // Preferred: the `limits` array, which also carries model-scoped weekly
        // limits (e.g. a per-model 7-day cap) that the legacy top-level keys omit.
        if let limits = json["limits"] as? [[String: Any]], !limits.isEmpty {
            for (i, l) in limits.enumerated() {
                guard let pct = l["percent"] as? Double else { continue }
                let kindKey = (l["kind"] as? String) ?? "limit\(i)"
                let resets = (l["resets_at"] as? String).flatMap(Date.fromISO8601)
                let kind: WindowKind
                switch kindKey {
                case "session": kind = .claudeSession
                case "weekly_all": kind = .claudeWeeklyAll
                case "weekly_scoped":
                    let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                    kind = .claudeWeeklyModel(model)
                default: kind = .raw(kindKey.replacingOccurrences(of: "_", with: " "))
                }
                windows.append(UsageWindow(id: "\(kindKey)-\(i)", kind: kind, usedPercent: pct, resetsAt: resets, isPrimary: true))
            }
        } else {
            for w in knownWindows {
                guard let obj = json[w.key] as? [String: Any], let util = obj["utilization"] as? Double else { continue }
                let resets = (obj["resets_at"] as? String).flatMap(Date.fromISO8601)
                windows.append(UsageWindow(id: w.key, kind: .claudeLegacy(w.key), usedPercent: util, resetsAt: resets, isPrimary: w.primary))
            }
        }

        var notes: [Note] = []
        if let extra = json["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
            if let util = extra["utilization"] as? Double {
                windows.append(UsageWindow(id: "extra_usage", kind: .claudeExtra, usedPercent: util, resetsAt: nil, isPrimary: false))
            }
            if let used = extra["used_credits"] as? Double, let limit = extra["monthly_limit"] as? Double {
                notes.append(.extraUsage(used: used / 100, limit: limit / 100))
            }
        }
        return ProviderSnapshot(windows: windows, planLabel: nil, notes: notes, updatedAt: Date())
    }

    static func planLabel(_ c: Creds) -> String? {
        var parts: [String] = []
        if let s = c.subscriptionType { parts.append(s.capitalized) }
        if let t = c.rateLimitTier {
            // e.g. "default_claude_max_20x" -> "20x"
            if let r = t.range(of: #"\d+x"#, options: .regularExpression) { parts.append(String(t[r])) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
