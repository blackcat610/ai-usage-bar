import Foundation

/// What a rate-limit window is, kept symbolic so its label follows the UI language.
enum WindowKind: Equatable {
    /// Claude `limits[]` kinds.
    case claudeSession
    case claudeWeeklyAll
    case claudeWeeklyModel(String?)
    /// Claude legacy top-level keys (five_hour, seven_day, ...).
    case claudeLegacy(String)
    case claudeExtra
    /// Codex window by length, optionally prefixed with an add-on limit name.
    case codex(seconds: Int?, limitName: String?)
    case raw(String)

    var label: String {
        switch self {
        case .claudeSession: return L.s("5시간 세션", "5-hour session")
        case .claudeWeeklyAll: return L.s("7일 전체", "7-day, all models")
        case .claudeWeeklyModel(let m):
            return L.s("7일 \(m ?? "모델별")", "7-day \(m ?? "per-model")")
        case .claudeLegacy(let key):
            switch key {
            case "five_hour": return L.s("5시간", "5-hour")
            case "seven_day": return L.s("7일 전체", "7-day, all models")
            case "seven_day_opus": return L.s("7일 Opus", "7-day Opus")
            case "seven_day_sonnet": return L.s("7일 Sonnet", "7-day Sonnet")
            case "seven_day_oauth_apps": return L.s("7일 OAuth 앱", "7-day OAuth apps")
            default: return key.replacingOccurrences(of: "_", with: " ")
            }
        case .claudeExtra: return L.s("추가 사용량", "Extra usage")
        case .codex(let seconds, let name):
            let w = Self.codexWindowLabel(seconds)
            return name.map { "\($0) \(w)" } ?? w
        case .raw(let s): return s
        }
    }

    static func codexWindowLabel(_ seconds: Int?) -> String {
        switch seconds {
        case .some(let s) where s % 86400 == 0 && s >= 86400:
            let d = s / 86400
            return d == 7 ? L.s("주간", "Weekly") : L.s("\(d)일", "\(d)-day")
        case .some(let s) where s % 3600 == 0:
            return L.s("\(s / 3600)시간", "\(s / 3600)-hour")
        case .some(let s):
            return L.s("\(s / 60)분", "\(s / 60)-min")
        case .none:
            return L.s("기간", "Window")
        }
    }
}

/// One rate-limit window (e.g. Claude "5-hour session", Codex "Weekly").
struct UsageWindow: Identifiable, Equatable {
    let id: String
    let kind: WindowKind
    /// 0...100, how much of the window has been consumed.
    let usedPercent: Double
    let resetsAt: Date?
    /// Primary windows drive the menu-bar summary; secondary ones (model-specific
    /// or add-on limits) only show in the popover.
    let isPrimary: Bool

    var label: String { kind.label }

    /// True once the window's reset time has passed. Between polls the API
    /// value is stale, so the window is treated as fully replenished.
    var hasReset: Bool {
        guard let r = resetsAt else { return false }
        return r <= Date()
    }

    var effectiveUsedPercent: Double { hasReset ? 0 : usedPercent }
    var remainingPercent: Double { hasReset ? 100 : min(100, max(0, 100 - usedPercent)) }
}

/// Small informational lines under a provider's windows.
enum Note: Equatable {
    case usingCLILogin
    case usingCLIFileLogin
    case extraUsage(used: Double, limit: Double)
    case credits(String)
    case limitReached
    case demo

    var text: String {
        switch self {
        case .usingCLILogin: return L.s("Claude Code 로그인 정보 사용 (키체인)", "Using Claude Code login (Keychain)")
        case .usingCLIFileLogin: return L.s("Claude Code 로그인 정보 사용 (~/.claude/.credentials.json)", "Using Claude Code login (~/.claude/.credentials.json)")
        case .extraUsage(let used, let limit):
            return String(format: L.s("추가 사용량 $%.2f / $%.2f", "Extra usage $%.2f / $%.2f"), used, limit)
        case .credits(let b): return L.s("크레딧 잔액 \(b)", "Credit balance \(b)")
        case .limitReached: return L.s("한도 도달", "Limit reached")
        case .demo: return L.s("데모 데이터", "Demo data")
        }
    }
}

struct ProviderSnapshot: Equatable {
    var windows: [UsageWindow]
    var planLabel: String?
    var notes: [Note]
    var updatedAt: Date

    /// The most constrained primary window (least remaining). Ties go to the
    /// one that resets soonest.
    var headline: UsageWindow? {
        let primary = windows.filter { $0.isPrimary }
        let pool = primary.isEmpty ? windows : primary
        return pool.min { a, b in
            if a.remainingPercent != b.remainingPercent { return a.remainingPercent < b.remainingPercent }
            return (a.resetsAt ?? .distantFuture) < (b.resetsAt ?? .distantFuture)
        }
    }
}

enum ProviderState: Equatable {
    case idle
    case loading(previous: ProviderSnapshot?)
    case ready(ProviderSnapshot)
    case failed(message: LText, needsLogin: Bool, previous: ProviderSnapshot?)

    var snapshot: ProviderSnapshot? {
        switch self {
        case .idle: return nil
        case .loading(let p): return p
        case .ready(let s): return s
        case .failed(_, _, let p): return p
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let m, _, _) = self { return m.s }
        return nil
    }

    var needsLogin: Bool {
        if case .failed(_, let n, _) = self { return n }
        return false
    }
}

struct ProviderError: LocalizedError {
    let text: LText
    var needsLogin: Bool = false
    init(_ ko: String, _ en: String, needsLogin: Bool = false) {
        text = LText(ko, en)
        self.needsLogin = needsLogin
    }
    var errorDescription: String? { text.s }
}
