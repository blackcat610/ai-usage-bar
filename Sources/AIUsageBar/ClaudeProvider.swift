import Foundation

/// Claude usage via the Claude Code CLI login. No login of its own.
///
/// Credentials come from where Claude Code keeps them: the Keychain item
/// "Claude Code-credentials", or `$CLAUDE_CONFIG_DIR/.credentials.json` when the
/// Keychain is unavailable. When the access token has expired we refresh it the
/// same way Claude Code does — under Claude Code's own refresh lock, with the
/// stored scopes, writing the rotated tokens back in place — so the CLI login
/// keeps working and the two never race each other.
final class ClaudeProvider {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let userAgent = "AIUsageBar/1.0 (personal menu-bar usage monitor)"
    static let cliService = "Claude Code-credentials"

    struct Creds: Equatable {
        var accessToken: String
        var refreshToken: String
        var expiresAtMs: Double
        var scopes: [String]
        var subscriptionType: String?
        var rateLimitTier: String?

        var isExpired: Bool { expiresAtMs / 1000 < Date().timeIntervalSince1970 + 60 }

        init?(json: [String: Any]) {
            guard let a = json["accessToken"] as? String, let r = json["refreshToken"] as? String else { return nil }
            accessToken = a
            refreshToken = r
            expiresAtMs = (json["expiresAt"] as? Double) ?? 0
            scopes = (json["scopes"] as? [String]) ?? []
            subscriptionType = json["subscriptionType"] as? String
            rateLimitTier = json["rateLimitTier"] as? String
        }

        func merged(into json: [String: Any]) -> [String: Any] {
            var j = json
            j["accessToken"] = accessToken
            j["refreshToken"] = refreshToken
            j["expiresAt"] = Int64(expiresAtMs)
            if !scopes.isEmpty { j["scopes"] = scopes }
            if let s = subscriptionType { j["subscriptionType"] = s }
            if let t = rateLimitTier { j["rateLimitTier"] = t }
            return j
        }
    }

    enum Source { case keychain, file }

    // MARK: - Paths

    static var configDir: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }
    static var credentialsFile: URL { configDir.appendingPathComponent(".credentials.json") }
    /// Claude Code's refresh lock (proper-lockfile: a directory, stale after 10 s).
    static var refreshLock: URL { configDir.appendingPathComponent(".oauth_refresh.lock") }

    // MARK: - Fetch

    private var usageBlockedUntil: Date = .distantPast
    private var refreshBlockedUntil: Date = .distantPast
    private var lastRefreshError: ProviderError?

    func fetch() async throws -> ProviderSnapshot {
        if Date() < usageBlockedUntil {
            let mins = max(1, Int(usageBlockedUntil.timeIntervalSinceNow / 60))
            throw ProviderError("Claude 사용량 API 호출 제한(429). \(mins)분 후 재시도합니다.",
                                "Claude usage API rate-limited (429). Retrying in \(mins) min.")
        }
        var (creds, source) = try await loadCreds()
        if creds.isExpired {
            creds = try await refreshUnderLock(creds, source: source)
        }
        var (status, data) = try await callUsage(creds.accessToken)
        if status == 401 {
            creds = try await refreshUnderLock(creds, source: source, force: true)
            (status, data) = try await callUsage(creds.accessToken)
        }
        guard status == 200 else {
            if status == 403, HTTP.errorCode(data) == "oauth_not_allowed_for_organization" {
                throw ProviderError("이 Claude Code 로그인의 조직에는 Claude 구독이 없어 사용량을 조회할 수 없습니다.",
                                    "This Claude Code login's organization has no Claude subscription, so usage cannot be read.",
                                    needsLogin: true)
            }
            if status == 401 || status == 403 {
                throw Self.reloginError()
            }
            if status == 429 {
                usageBlockedUntil = Date().addingTimeInterval(10 * 60)
                throw ProviderError("Claude 사용량 API 호출 제한(429). 10분 후 재시도합니다.",
                                    "Claude usage API rate-limited (429). Retrying in 10 min.")
            }
            throw ProviderError("Claude 사용량 조회 실패 (HTTP \(status)): \(HTTP.errorSnippet(data))",
                                "Claude usage request failed (HTTP \(status)): \(HTTP.errorSnippet(data))")
        }
        guard let json = HTTP.json(data) else {
            throw ProviderError("Claude 응답을 해석할 수 없습니다.", "Could not parse the Claude response.")
        }
        var snap = Self.parse(json)
        snap.planLabel = Self.planLabel(creds)
        snap.notes.append(source == .keychain ? .usingCLILogin : .usingCLIFileLogin)
        return snap
    }

    static func reloginError() -> ProviderError {
        ProviderError("Claude Code 로그인이 만료되었습니다. 터미널에서 `claude`를 실행해 다시 로그인하면 자동으로 이어집니다.",
                      "The Claude Code login has expired. Run `claude` in a terminal and sign in again; the app picks it up automatically.",
                      needsLogin: true)
    }

    // MARK: - Credentials

    private func loadCreds() async throws -> (Creds, Source) {
        try await Task.detached(priority: .utility) { () -> (Creds, Source) in
            if let c = Self.load(.keychain) { return (c, .keychain) }
            if let c = Self.load(.file) { return (c, .file) }
            throw ProviderError("Claude Code 로그인 정보가 없습니다. 터미널에서 `claude`를 실행해 로그인하세요.",
                                "No Claude Code login found. Run `claude` in a terminal and sign in.", needsLogin: true)
        }.value
    }

    private static func load(_ source: Source) -> Creds? {
        (loadJSON(source)?["claudeAiOauth"] as? [String: Any]).flatMap(Creds.init)
    }

    private static func loadJSON(_ source: Source) -> [String: Any]? {
        switch source {
        case .keychain:
            guard let s = Keychain.read(service: cliService, account: NSUserName()) ?? Keychain.read(service: cliService),
                  let d = s.data(using: .utf8) else { return nil }
            return HTTP.json(d)
        case .file:
            guard let d = try? Data(contentsOf: credentialsFile) else { return nil }
            return HTTP.json(d)
        }
    }

    private static func save(_ creds: Creds, to source: Source) throws {
        guard var full = loadJSON(source), let o = full["claudeAiOauth"] as? [String: Any] else {
            throw ProviderError("Claude Code 로그인 정보를 다시 읽을 수 없어 갱신 토큰을 저장하지 못했습니다.",
                                "Could not re-read the Claude Code credentials; the refreshed token was not saved.")
        }
        full["claudeAiOauth"] = creds.merged(into: o)
        let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        switch source {
        case .keychain:
            guard Keychain.write(service: cliService, account: NSUserName(), value: String(decoding: data, as: UTF8.self)) else {
                throw ProviderError("Claude Code 키체인 항목 쓰기 실패.", "Failed to write the Claude Code Keychain item.")
            }
        case .file:
            try data.write(to: credentialsFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)
        }
    }

    // MARK: - Refresh (Claude Code's lock + protocol)

    /// Refresh under Claude Code's `.oauth_refresh.lock`. After taking the lock the
    /// stored credentials are re-read: if another process already refreshed them,
    /// those are used and no refresh request is made (refresh tokens are single-use).
    private func refreshUnderLock(_ creds: Creds, source: Source, force: Bool = false) async throws -> Creds {
        if Date() < refreshBlockedUntil, let e = lastRefreshError {
            if e.needsLogin { throw e }
            let mins = max(1, Int(refreshBlockedUntil.timeIntervalSinceNow / 60))
            throw ProviderError("\(e.text.ko) (\(mins)분 후 재시도)", "\(e.text.en) (retry in \(mins) min)")
        }
        let lock = try await Task.detached(priority: .utility) { try RefreshLock.acquire(Self.refreshLock) }.value
        defer { lock.release() }

        if let fresh = await Task.detached(priority: .utility, operation: { Self.load(source) }).value,
           fresh.accessToken != creds.accessToken, !fresh.isExpired || !force {
            if !fresh.isExpired { return fresh }
        }
        let next = try await requestRefresh(creds)
        try await Task.detached(priority: .utility) { try Self.save(next, to: source) }.value
        return next
    }

    private func requestRefresh(_ creds: Creds) async throws -> Creds {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "client_id": Self.clientID,
        ]
        if !creds.scopes.isEmpty { body["scope"] = creds.scopes.joined(separator: " ") }
        let (status, data) = try await HTTP.request(Self.tokenURL, method: "POST", headers: Self.headers(), jsonBody: body)
        guard status == 200, let j = HTTP.json(data), let access = j["access_token"] as? String else {
            let snippet = HTTP.errorSnippet(data)
            let err: ProviderError
            if status == 400 || status == 401 {
                // invalid_grant: the refresh token is expired or revoked — only a new CLI login fixes it.
                err = Self.reloginError()
            } else if status == 429 {
                err = ProviderError("토큰 갱신이 잠시 제한되었습니다(429). \(snippet)", "Token refresh is rate-limited (429). \(snippet)")
            } else {
                err = ProviderError("토큰 갱신 실패 (HTTP \(status)). \(snippet)", "Token refresh failed (HTTP \(status)). \(snippet)")
            }
            lastRefreshError = err
            refreshBlockedUntil = Date().addingTimeInterval(status == 429 ? 15 * 60 : 5 * 60)
            throw err
        }
        lastRefreshError = nil
        refreshBlockedUntil = .distantPast
        var next = creds
        next.accessToken = access
        if let r = j["refresh_token"] as? String { next.refreshToken = r }
        next.expiresAtMs = (Date().timeIntervalSince1970 + ((j["expires_in"] as? Double) ?? 3600)) * 1000
        if let s = j["scope"] as? String, !s.isEmpty { next.scopes = s.split(separator: " ").map(String.init) }
        return next
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

/// proper-lockfile compatible lock: the lock is a directory; a holder older than
/// `stale` seconds is considered abandoned. Matches Claude Code's settings
/// (stale: 10 s) so both sides respect each other.
final class RefreshLock {
    private let url: URL
    private init(url: URL) { self.url = url }

    static func acquire(_ url: URL, stale: TimeInterval = 10, wait: TimeInterval = 8) throws -> RefreshLock {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(wait)
        while true {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return RefreshLock(url: url)
            } catch {
                let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                if Date().timeIntervalSince(mtime) > stale {
                    try? fm.removeItem(at: url)          // abandoned by a crashed holder
                    continue
                }
                if Date() > deadline {
                    throw ProviderError("다른 프로세스가 Claude 토큰을 갱신 중입니다. 잠시 후 다시 시도합니다.",
                                        "Another process is refreshing the Claude token. Retrying shortly.")
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    func release() { try? FileManager.default.removeItem(at: url) }
}
