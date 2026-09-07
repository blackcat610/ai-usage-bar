import SwiftUI
import AppKit
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var quit: () -> Void

    @State private var showClaudeLogin = false
    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?
    @State private var opts = MenuBarOptions()
    @State private var language = L.setting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderSection(name: "Claude", state: store.claude, tick: store.tick,
                            loginAction: { showClaudeLogin.toggle() })
            if showClaudeLogin {
                ClaudeLoginView(provider: store.claudeProvider, done: {
                    showClaudeLogin = false
                    store.refresh()
                })
            }
            Divider()
            ProviderSection(name: "Codex", state: store.codex, tick: store.tick, loginAction: nil)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 420)
        .id(store.tick) // re-render everything (labels, countdowns) on tick or language change
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    store.refresh()
                } label: {
                    Label(L.s("새로고침", "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(store.claude.isLoading || store.codex.isLoading)
                Toggle(L.s("로그인 시 실행", "Launch at login"), isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
                Spacer()
                Button(L.s("종료", "Quit"), role: .destructive, action: quit)
            }
            .controlSize(.small)
            MenuBarOptionsView(opts: $opts)
            HStack {
                if let t = store.lastRefresh {
                    Text(L.s("마지막 갱신 \(Fmt.time(t)) · \(Int(store.refreshInterval / 60))분마다 자동",
                             "Last updated \(Fmt.time(t)) · auto every \(Int(store.refreshInterval / 60)) min"))
                } else {
                    Text(L.s("불러오는 중…", "Loading…"))
                }
                if let e = launchError { Text("· \(e)").foregroundStyle(.red) }
                Spacer()
                Picker("", selection: $language) {
                    Text(L.s("시스템 언어", "System language")).tag(Lang.system)
                    Text("한국어").tag(Lang.ko)
                    Text("English").tag(Lang.en)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
                .onChange(of: language) { _, v in
                    L.setting = v
                    Settings.notify()
                    store.tick &+= 1
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ProviderSection: View {
    let name: String
    let state: ProviderState
    let tick: Int
    let loginAction: (() -> Void)?

    private var brand: Color { Color(nsColor: name == "Claude" ? Brand.claude : Brand.codex) }
    private var symbol: String { name == "Claude" ? "asterisk" : "chevron.left.forwardslash.chevron.right" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol).font(.subheadline.bold()).foregroundStyle(brand)
                Text(name).font(.headline)
                if let plan = state.snapshot?.planLabel {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let s = state.snapshot {
                    Text(Fmt.time(s.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let snap = state.snapshot {
                let primary = snap.windows.filter { $0.isPrimary }
                let secondary = snap.windows.filter { !$0.isPrimary }
                ForEach(primary) { WindowRow(window: $0, tick: tick, compact: false, brand: brand) }
                if !secondary.isEmpty {
                    ForEach(secondary) { WindowRow(window: $0, tick: tick, compact: true, brand: brand) }
                }
                if snap.windows.isEmpty {
                    Text(L.s("표시할 사용량 정보가 없습니다.", "No usage information to show."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !snap.notes.isEmpty {
                    Text(snap.notes.map(\.text).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let err = state.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if state.needsLogin, let loginAction {
                        Button(L.s("Claude 로그인…", "Sign in to Claude…"), action: loginAction).controlSize(.small)
                    }
                }
            } else if let loginAction, name == "Claude" {
                // Always reachable, so the user can switch to the app's own login.
                HStack {
                    Spacer()
                    Button(L.s("로그인 설정…", "Sign-in settings…"), action: loginAction)
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let tick: Int
    let compact: Bool
    let brand: Color

    private var tint: Color {
        window.remainingPercent <= Settings.lowThreshold ? .red : brand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(window.label)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(compact ? .secondary : .primary)
                    .frame(width: 160, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GaugeBar(fraction: window.remainingPercent / 100, tint: tint)
                Text(L.s("\(Fmt.percent(window.remainingPercent)) 남음", "\(Fmt.percent(window.remainingPercent)) left"))
                    .font(compact ? .caption : .callout)
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
            if let r = window.resetsAt {
                let _ = tick // re-render countdown on tick
                Text(window.hasReset
                     ? L.s("\(Fmt.clock(r)) 리셋 시점 지남 · 100%로 간주, 다음 조회 시 갱신",
                           "Reset at \(Fmt.clock(r)) has passed · treated as 100%, updates on next poll")
                     : L.s("\(Fmt.countdownLong(to: r)) 후 리셋 · \(Fmt.clock(r))",
                           "Resets in \(Fmt.countdownLong(to: r)) · \(Fmt.clock(r))"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 168)
            }
        }
    }
}

struct ClaudeLoginView: View {
    let provider: ClaudeProvider
    var done: () -> Void

    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L.s("Claude 로그인 (앱 전용 토큰)", "Claude sign-in (app-specific token)")).font(.subheadline.bold())
            Text(L.s("기본은 Claude Code CLI의 로그인 정보를 그대로 읽습니다. 그게 만료·불가하면 여기서 앱 전용으로 한 번 로그인하세요. 1) 브라우저에서 승인 → 2) 표시된 코드를 붙여넣기.",
                     "By default the app reads the Claude Code CLI login. If that is unavailable or expired, sign in once here for an app-specific token. 1) Approve in the browser → 2) paste the code shown."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L.s("1. 브라우저에서 로그인", "1. Sign in in browser")) {
                    NSWorkspace.shared.open(provider.beginLogin())
                    started = true
                    message = nil
                }
                .controlSize(.small)
                if provider.hasOwnLogin() {
                    Button(L.s("앱 전용 토큰 삭제", "Remove app token")) {
                        provider.forgetOwnLogin()
                        isError = false
                        message = L.s("앱 전용 토큰을 삭제했습니다. 다시 Claude Code 로그인 정보를 사용합니다.",
                                      "App token removed. Falling back to the Claude Code login.")
                    }
                    .controlSize(.small)
                }
            }
            HStack {
                TextField(L.s("2. 인증 코드 붙여넣기 (code#state)", "2. Paste the authorization code (code#state)"), text: $code)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(submit)
                Button(L.s("연결", "Connect"), action: submit)
                    .controlSize(.small)
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty || !started)
            }
            if let m = message {
                Text(m).font(.caption2).foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        message = nil
        let pasted = code
        Task {
            do {
                try await provider.completeLogin(pasted: pasted)
                isError = false
                message = L.s("연결되었습니다.", "Connected.")
                code = ""
                done()
            } catch let e as ProviderError {
                isError = true
                message = e.text.s
            } catch {
                isError = true
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Battery-style remaining gauge: track + filled capsule for what is left.
struct GaugeBar: View {
    let fraction: Double   // 0...1 remaining
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }
}

/// Snapshot of the menu-bar settings bound to the popover checkboxes.
struct MenuBarOptions: Equatable {
    var twoRows = Settings.twoRows
    var glyphs = Settings.showGlyphs
    var battery = Settings.showBattery
    var percent = Settings.showPercent
    var percentInBattery = Settings.percentInBattery
    var percentSign = Settings.percentSign
    var countdown = Settings.showCountdown

    func apply() {
        Settings.twoRows = twoRows
        Settings.showGlyphs = glyphs
        Settings.showBattery = battery
        Settings.showPercent = percent
        Settings.percentInBattery = percentInBattery
        Settings.percentSign = percentSign
        Settings.showCountdown = countdown
        Settings.notify()
    }
}

struct MenuBarOptionsView: View {
    @Binding var opts: MenuBarOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.s("메뉴바 표시", "Menu bar")).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Toggle(L.s("2줄 (끄면 1줄)", "Two rows"), isOn: $opts.twoRows)
                    Toggle(L.s("아이콘", "Icons"), isOn: $opts.glyphs)
                    Toggle(L.s("남은 시간", "Time to reset"), isOn: $opts.countdown)
                }
                GridRow {
                    Toggle(L.s("배터리 바", "Battery gauge"), isOn: $opts.battery)
                    Toggle(L.s("잔여 숫자", "Remaining number"), isOn: $opts.percent)
                    Toggle(L.s("% 기호", "% sign"), isOn: $opts.percentSign).disabled(!opts.percent)
                }
                GridRow {
                    Toggle(L.s("숫자를 배터리 안에 (아이폰식)", "Number inside the battery (iPhone style)"), isOn: $opts.percentInBattery)
                        .disabled(!(opts.battery && opts.percent))
                        .gridCellColumns(3)
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .onChange(of: opts) { _, v in v.apply() }
    }
}
