import AppKit
import SwiftUI

@main
enum AIUsageBarMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") {
            dumpAndExit()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            renderAndExit(to: CommandLine.arguments[i + 1], demo: false)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
            renderAndExit(to: CommandLine.arguments[i + 1], demo: true)
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Headless check: fetch both providers, render the popover to a PNG, exit.
    /// Synthetic data for design checks without touching the APIs.
    static func demoSnapshots() -> (ProviderSnapshot, ProviderSnapshot) {
        let now = Date()
        let claude = ProviderSnapshot(windows: [
            UsageWindow(id: "session-0", kind: .claudeSession, usedPercent: 28, resetsAt: now.addingTimeInterval(2 * 3600 + 34 * 60), isPrimary: true),
            UsageWindow(id: "weekly_all-1", kind: .claudeWeeklyAll, usedPercent: 24, resetsAt: now.addingTimeInterval(13 * 3600 + 30 * 60), isPrimary: true),
            UsageWindow(id: "weekly_scoped-2", kind: .claudeWeeklyModel("Fable"), usedPercent: 47, resetsAt: now.addingTimeInterval(13 * 3600 + 30 * 60), isPrimary: true),
        ], planLabel: "Max 20x", notes: [.demo], updatedAt: now)
        let codex = ProviderSnapshot(windows: [
            UsageWindow(id: "primary", kind: .codex(seconds: 18000, limitName: nil), usedPercent: 82, resetsAt: now.addingTimeInterval(48 * 60), isPrimary: true),
            UsageWindow(id: "secondary", kind: .codex(seconds: 604800, limitName: nil), usedPercent: 61, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600), isPrimary: true),
        ], planLabel: "Pro", notes: [.demo], updatedAt: now)
        return (claude, codex)
    }

    static func renderAndExit(to path: String, demo: Bool) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            let store = UsageStore()
            Task { @MainActor in
                if demo {
                    let (c, x) = demoSnapshots()
                    store.claude = .ready(c)
                    store.codex = .ready(x)
                } else {
                    let c = ClaudeProvider(), x = CodexProvider()
                    do { store.claude = .ready(try await c.fetch()) } catch {
                        store.claude = .failed(message: (error as? ProviderError)?.text ?? LText(same: error.localizedDescription), needsLogin: true, previous: nil)
                    }
                    do { store.codex = .ready(try await x.fetch()) } catch {
                        store.codex = .failed(message: (error as? ProviderError)?.text ?? LText(same: error.localizedDescription), needsLogin: false, previous: nil)
                    }
                }
                store.lastRefresh = Date()
                // (name, appearance, background, bar height, number inside battery, two rows)
                let variants: [(String, NSAppearance, NSColor, CGFloat, Bool, Bool)] = [
                    ("2row-light", NSAppearance(named: .aqua)!, NSColor(white: 0.93, alpha: 1), 24, false, true),
                    ("2row-dark", NSAppearance(named: .darkAqua)!, NSColor(white: 0.12, alpha: 1), 24, false, true),
                    ("2row-dark-iphone", NSAppearance(named: .darkAqua)!, NSColor(white: 0.12, alpha: 1), 24, true, true),
                    ("1row-dark", NSAppearance(named: .darkAqua)!, NSColor(white: 0.12, alpha: 1), 24, false, false),
                    ("1row-light", NSAppearance(named: .aqua)!, NSColor(white: 0.93, alpha: 1), 24, false, false),
                    ("1row-dark-iphone", NSAppearance(named: .darkAqua)!, NSColor(white: 0.12, alpha: 1), 24, true, false),
                ]
                // Preview every column regardless of the user's saved toggles; restore after.
                let saved = MenuBarOptions()
                var forced = saved
                forced.glyphs = true; forced.battery = true; forced.percent = true; forced.countdown = true
                for (suffix, appearance, bg, h, inside, two) in variants {
                    forced.percentInBattery = inside
                    forced.twoRows = two
                    forced.apply()
                    let v = StatusView(frame: NSRect(x: 0, y: 0, width: 10, height: h))
                    var rows: [StatusView.Row] = []
                    if Settings.showClaude { rows.append(AppDelegate.row(glyph: ProviderGlyph.claude, state: store.claude)) }
                    if Settings.showCodex { rows.append(AppDelegate.row(glyph: ProviderGlyph.codex, state: store.codex)) }
                    v.rows = rows
                    v.frame = NSRect(x: 0, y: 0, width: v.preferredWidth(), height: h)
                    v.appearance = appearance
                    // Retina-accurate (2x) offscreen bitmap, then 2x more for inspection.
                    // Reference system-battery glyph (26x12, centered) drawn at the right for alignment checks.
                    let size = NSSize(width: v.frame.width + 16 + 40, height: h)
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    rep.size = size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    appearance.performAsCurrentDrawingAppearance {
                        bg.setFill(); NSRect(origin: .zero, size: size).fill()
                        BatteryIcon.draw(in: NSRect(x: size.width - 34, y: (h - 12) / 2, width: 27, height: 12), remaining: 80)
                        NSGraphicsContext.current?.cgContext.translateBy(x: 8, y: 0)
                        v.draw(v.bounds)
                    }
                    NSGraphicsContext.restoreGraphicsState()
                    do {
                        let big = NSImage(size: NSSize(width: size.width * 4, height: size.height * 4))
                        big.lockFocus(); NSGraphicsContext.current?.imageInterpolation = .high
                        rep.draw(in: NSRect(origin: .zero, size: big.size)); big.unlockFocus()
                        if let t2 = big.tiffRepresentation, let r2 = NSBitmapImageRep(data: t2),
                           let png = r2.representation(using: .png, properties: [:]) {
                            let out = path.replacingOccurrences(of: ".png", with: "-\(suffix).png")
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("rendered \(suffix) (\(Int(v.frame.width))pt wide) -> \(out)")
                        }
                    }
                }
                saved.apply()   // restore before exit() (defer would not run)
                // Sign-in settings window preview (probes real keychain/file availability).
                do {
                    let auth = ClaudeLoginView(provider: store.claudeProvider, done: {}, close: {})
                        .background(Color(nsColor: .windowBackgroundColor))
                    let r = ImageRenderer(content: auth)
                    r.scale = 2
                    // give onAppear's probe a moment
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let cg = r.cgImage {
                        let rep = NSBitmapImageRep(cgImage: cg)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            let out = path.replacingOccurrences(of: ".png", with: "-auth.png")
                            try? png.write(to: URL(fileURLWithPath: out))
                            print("rendered auth -> \(out)")
                        }
                    }
                }
                let view = PopoverView(store: store, quit: {}, openClaudeLogin: {}).background(Color(nsColor: .windowBackgroundColor))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                        print("rendered \(cg.width)x\(cg.height) -> \(path)")
                    }
                } else {
                    print("render failed")
                }
                exit(0)
            }
        }
        app.run()
        exit(0)
    }

    /// Headless check: fetch both providers, print what the UI would show, exit.
    static func dumpAndExit() -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task {
            func show(_ name: String, _ r: Result<ProviderSnapshot, Error>) {
                print("== \(name)")
                switch r {
                case .success(let s):
                    if let p = s.planLabel { print("  plan: \(p)") }
                    for w in s.windows {
                        var line = "  [\(w.isPrimary ? "P" : "s")] \(w.label): used \(Fmt.percent(w.usedPercent)) / \(Fmt.percent(w.remainingPercent)) 남음"
                        if let r = w.resetsAt { line += " · 리셋 \(Fmt.countdownLong(to: r)) 후 (\(Fmt.clock(r))) short=\(Fmt.countdownShort(to: r))" }
                        print(line)
                    }
                    if let h = s.headline { print("  headline: \(h.label) \(Fmt.percent(h.remainingPercent)) 남음") }
                    for n in s.notes { print("  note: \(n.text)") }
                case .failure(let e):
                    print("  ERROR: \((e as? ProviderError)?.text.s ?? e.localizedDescription) needsLogin=\((e as? ProviderError)?.needsLogin ?? false)")
                }
            }
            let c = ClaudeProvider(), x = CodexProvider()
            async let cr: Result<ProviderSnapshot, Error> = { do { return .success(try await c.fetch()) } catch { return .failure(error) } }()
            async let xr: Result<ProviderSnapshot, Error> = { do { return .success(try await x.fetch()) } catch { return .failure(error) } }()
            show("Claude", await cr)
            show("Codex", await xr)
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
