import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude: ProviderState = .idle
    @Published var codex: ProviderState = .idle
    @Published var lastRefresh: Date?
    /// Bumped every 30s (and on language/setting changes) so text re-renders.
    @Published var tick: Int = 0

    let claudeProvider = ClaudeProvider()
    let codexProvider = CodexProvider()

    var refreshInterval: TimeInterval = 300
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var inFlight = false

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick &+= 1 }
        }
    }

    /// Refresh only if the last one is older than `minAge` (used when the popover opens).
    func refreshIfStale(minAge: TimeInterval = 60) {
        if let t = lastRefresh, Date().timeIntervalSince(t) < minAge { return }
        refresh()
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let doClaude = Settings.showClaude, doCodex = Settings.showCodex
        if doClaude { claude = .loading(previous: claude.snapshot) }
        if doCodex { codex = .loading(previous: codex.snapshot) }
        Task {
            async let c: Void = doClaude ? refreshClaude() : ()
            async let x: Void = doCodex ? refreshCodex() : ()
            _ = await (c, x)
            lastRefresh = Date()
            inFlight = false
        }
    }

    private func refreshClaude() async {
        let prev = claude.snapshot
        do {
            claude = .ready(try await claudeProvider.fetch())
        } catch let e as ProviderError {
            claude = .failed(message: e.text, needsLogin: e.needsLogin, previous: prev)
        } catch {
            claude = .failed(message: LText(same: error.localizedDescription), needsLogin: false, previous: prev)
        }
    }

    private func refreshCodex() async {
        let prev = codex.snapshot
        do {
            codex = .ready(try await codexProvider.fetch())
        } catch let e as ProviderError {
            codex = .failed(message: e.text, needsLogin: e.needsLogin, previous: prev)
        } catch {
            codex = .failed(message: LText(same: error.localizedDescription), needsLogin: false, previous: prev)
        }
    }
}
