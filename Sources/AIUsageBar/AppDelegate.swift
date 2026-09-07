import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let statusView = StatusView(frame: .zero)
    private let popover = NSPopover()
    private let store = UsageStore()
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var lastToggle = Date.distantPast
    private var loginWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.attributedTitle = NSAttributedString(string: "…")
        }

        let root = PopoverView(store: store, quit: { NSApp.terminate(nil) },
                               openClaudeLogin: { [weak self] in self?.showClaudeLogin() })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        store.start()
    }

    /// Accessory apps get no main menu, so standard edit key equivalents (⌘V, ⌘C, ⌘A…)
    /// do nothing in the popover's text field unless we provide one.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.s("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Status item

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        // Rapid re-clicks would race the open/close animation and activation; ignore them.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.25 else { return }
        lastToggle = now

        if popover.isShown {
            closePopover()
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make sure the popover window is key even if activation lagged behind.
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            installOutsideClickMonitor()
            store.refreshIfStale()
        }
    }

    /// The login needs a browser round-trip, which deactivates the app and closes the
    /// transient popover — so it lives in its own small window instead.
    private func showClaudeLogin() {
        closePopover()
        if let w = loginWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = ClaudeLoginView(provider: store.claudeProvider,
                                   done: { [weak self] in
                                       self?.store.refresh()
                                       DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.loginWindow?.close() }
                                   },
                                   close: { [weak self] in self?.loginWindow?.close() })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = L.s("Claude 로그인", "Claude sign-in")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        w.delegate = self
        loginWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    /// `.transient` only dismisses when our app is active. A global monitor sees
    /// clicks in other apps regardless, so a click anywhere outside always closes it.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === loginWindow { loginWindow = nil }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L.s("새로고침", "Refresh"), action: #selector(menuRefresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L.s("종료", "Quit"), action: #selector(menuQuit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { store.refresh() }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { closePopover() }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Title

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        if statusView.superview !== button {
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }
        var rows: [StatusView.Row] = []
        if Settings.showClaude { rows.append(Self.row(glyph: ProviderGlyph.claude, state: store.claude)) }
        if Settings.showCodex { rows.append(Self.row(glyph: ProviderGlyph.codex, state: store.codex)) }
        statusView.rows = rows
        statusView.frame = button.bounds
        statusItem.length = statusView.preferredWidth()
        statusView.frame = button.bounds
        statusView.needsDisplay = true
        button.toolTip = Self.tooltip(claude: store.claude, codex: store.codex)
    }

    static func row(glyph: NSImage, state: ProviderState) -> StatusView.Row {
        let h = state.snapshot?.headline
        let countdown = h?.resetsAt.map { Fmt.countdownShort(to: $0) }
        return .init(glyph: glyph, remaining: h?.remainingPercent,
                     error: state.errorMessage != nil, countdown: countdown)
    }

    private static func tooltip(claude: ProviderState, codex: ProviderState) -> String {
        func lines(_ name: String, _ st: ProviderState) -> [String] {
            var out = [name]
            if let snap = st.snapshot {
                for w in snap.windows where w.isPrimary {
                    var l = "  \(w.label): " + L.s("\(Fmt.percent(w.remainingPercent)) 남음", "\(Fmt.percent(w.remainingPercent)) left")
                    if let r = w.resetsAt {
                        l += w.hasReset ? L.s(" · 리셋 지남(다음 조회 시 갱신)", " · reset passed (updates on next poll)")
                                        : L.s(" · \(Fmt.countdownLong(to: r)) 후 리셋", " · resets in \(Fmt.countdownLong(to: r))")
                    }
                    out.append(l)
                }
            }
            if let e = st.errorMessage { out.append("  ⚠︎ \(e)") }
            return out
        }
        var out: [String] = []
        if Settings.showClaude { out += lines("Claude", claude) }
        if Settings.showCodex { out += lines("Codex", codex) }
        if out.isEmpty { out = [L.s("표시할 서비스가 선택되지 않았습니다.", "No service selected.")] }
        return out.joined(separator: "\n")
    }
}
