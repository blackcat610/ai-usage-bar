import SwiftUI
import AppKit
import ServiceManagement

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var quit: () -> Void
    var openClaudeLogin: () -> Void

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?
    @State private var opts = MenuBarOptions()
    @State private var language = L.setting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !Settings.showClaude && !Settings.showCodex {
                Text(L.s("메뉴바에 표시할 서비스를 하나 이상 선택하세요.", "Select at least one service to show in the menu bar."))
                    .font(.caption).foregroundStyle(.orange)
            }
            ProviderSection(name: "Claude", state: store.claude, tick: store.tick,
                            enabled: Binding(get: { Settings.showClaude }, set: { Settings.showClaude = $0; providerToggled() }),
                            loginAction: openClaudeLogin)
            Divider()
            ProviderSection(name: "Codex", state: store.codex, tick: store.tick,
                            enabled: Binding(get: { Settings.showCodex }, set: { Settings.showCodex = $0; providerToggled() }),
                            loginAction: nil)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 420)
    }

    private func providerToggled() {
        Settings.notify()
        store.tick &+= 1
        store.refresh()
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
            MenuBarOptionsView(opts: $opts).id(language)
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
    @Binding var enabled: Bool
    let loginAction: (() -> Void)?

    private var brand: Color { Color(nsColor: name == "Claude" ? Brand.claude : Brand.codex) }
    private var symbol: String { name == "Claude" ? "asterisk" : "chevron.left.forwardslash.chevron.right" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("", isOn: $enabled).toggleStyle(.checkbox).labelsHidden()
                    .help(L.s("메뉴바에 표시", "Show in the menu bar"))
                Image(systemName: symbol).font(.subheadline.bold()).foregroundStyle(enabled ? brand : .secondary)
                Text(name).font(.headline).foregroundStyle(enabled ? .primary : .secondary)
                if !enabled {
                    Text(L.s("숨김", "hidden")).font(.caption).foregroundStyle(.tertiary)
                }
                if enabled, let plan = state.snapshot?.planLabel {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if !enabled {
                    EmptyView()
                } else if state.isLoading {
                    ProgressView().controlSize(.mini)
                } else if let s = state.snapshot {
                    Text(Fmt.time(s.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if enabled, let snap = state.snapshot {
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
            if enabled, let err = state.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if state.needsLogin, let loginAction {
                        Button(L.s("인증 설정…", "Sign-in settings…"), action: loginAction).controlSize(.small)
                    }
                }
            } else if enabled, let loginAction, name == "Claude" {
                // Always reachable, so the user can switch to the app's own login.
                HStack {
                    Spacer()
                    Button(L.s("인증 설정…", "Sign-in settings…"), action: loginAction)
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
    var close: () -> Void

    /// Seed for previews (the live window probes in `onAppear`).
    var initialSources: [ClaudeProvider.SourceInfo] = []

    @State private var probed: [ClaudeProvider.SourceInfo] = []
    @State private var selection: String = Settings.claudeSource
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    private var sources: [ClaudeProvider.SourceInfo] { probed.isEmpty ? initialSources : probed }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Source picker
            VStack(alignment: .leading, spacing: 6) {
                Text(L.s("사용할 Claude 인증", "Claude credential to use")).font(.headline)
                Picker("", selection: $selection) {
                    Text(L.s("자동 — 사용 가능한 것 중 Claude Code CLI 우선", "Automatic — prefer the Claude Code CLI login")).tag("auto")
                    ForEach(sources) { info in
                        HStack(spacing: 6) {
                            Text(info.source.title)
                            Text("· " + info.detail).foregroundStyle(info.available ? .secondary : .tertiary)
                        }
                        .tag(info.source.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: selection) { _, v in
                    Settings.claudeSource = v
                    Settings.notify()
                    done()   // re-fetch with the chosen source
                }
                Text(L.s("CLI 로그인이 있으면 별도 설정 없이 그것을 쓰는 것이 가장 간단합니다. 만료된 토큰은 사용 시 자동 갱신되어 같은 자리에 저장됩니다.",
                         "If a CLI login exists, using it needs no setup. Expired tokens are refreshed on use and stored back in place."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // App-specific login
            VStack(alignment: .leading, spacing: 8) {
                Text(L.s("앱 전용 토큰 로그인", "App-specific token sign-in")).font(.headline)
                Text(L.s("Claude Code CLI 로그인이 없을 때 쓰는 방법입니다. 1) 브라우저에서 승인 → 2) 표시된 코드를 붙여넣기 → 3) 연결. (\"Claude Code에 붙여넣으세요\"라고 나와도 여기에 넣으면 됩니다.)",
                         "For when there is no Claude Code CLI login. 1) Approve in the browser → 2) paste the code shown → 3) Connect. (Paste it here even if the page says to paste it into Claude Code.)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L.s("1. 브라우저에서 로그인", "1. Sign in in browser")) {
                        NSWorkspace.shared.open(provider.beginLogin())
                        message = nil
                    }
                    if sources.first(where: { $0.source == .own })?.available == true {
                        Button(L.s("앱 전용 토큰 삭제", "Remove app token")) {
                            provider.forgetOwnLogin()
                            isError = false
                            message = L.s("앱 전용 토큰을 삭제했습니다.", "App token removed.")
                            if selection == "own" { selection = "auto" }
                            reload()
                            done()
                        }
                    }
                }
                HStack {
                    TextField(L.s("2. 인증 코드 붙여넣기", "2. Paste the authorization code"), text: $code)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button(L.s("3. 연결", "3. Connect"), action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack(alignment: .top) {
                if busy { ProgressView().controlSize(.small) }
                if let m = message {
                    Text(m).font(.caption).foregroundStyle(isError ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(L.s("닫기", "Close"), action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear(perform: reload)
    }

    private func reload() {
        Task.detached(priority: .userInitiated) {
            let result = ClaudeProvider.probeSources()
            await MainActor.run { probed = result }
        }
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
                message = L.s("연결되었습니다. 앱 전용 토큰이 저장되었습니다.", "Connected. The app-specific token is saved.")
                code = ""
                reload()
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
