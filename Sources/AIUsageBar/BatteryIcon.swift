import AppKit

/// Menu-bar display options (UserDefaults-backed).
enum Settings {
    private static func flag(_ key: String, default d: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? d
    }
    private static func set(_ key: String, _ v: Bool) { UserDefaults.standard.set(v, forKey: key) }

    /// Which providers to show (and poll).
    static var showClaude: Bool { get { flag("showClaude", default: true) } set { set("showClaude", newValue) } }
    static var showCodex: Bool { get { flag("showCodex", default: true) } set { set("showCodex", newValue) } }

    /// Two stacked rows (Claude over Codex) instead of one line.
    static var twoRows: Bool { get { flag("twoRows", default: true) } set { set("twoRows", newValue) } }
    /// Provider glyph (✳ / ‹/›) in brand color.
    static var showGlyphs: Bool { get { flag("showGlyphs", default: true) } set { set("showGlyphs", newValue) } }
    /// Battery gauge.
    static var showBattery: Bool { get { flag("showBattery", default: true) } set { set("showBattery", newValue) } }
    /// Remaining number.
    static var showPercent: Bool { get { flag("showPercent", default: true) } set { set("showPercent", newValue) } }
    /// iPhone style: draw the number inside the battery instead of beside it.
    static var percentInBattery: Bool { get { flag("percentInBattery", default: false) } set { set("percentInBattery", newValue) } }
    /// Append "%" to the number.
    static var percentSign: Bool { get { flag("percentSign", default: true) } set { set("percentSign", newValue) } }
    /// Countdown to reset.
    static var showCountdown: Bool { get { flag("showCountdown", default: true) } set { set("showCountdown", newValue) } }

    /// Remaining % at or below which the gauge and number turn red (macOS battery: ~20%).
    static let lowThreshold: Double = 20

    static let changed = Notification.Name("AIUsageBar.settingsChanged")
    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }

    /// Number goes inside the gauge only when both are on.
    static var numberInsideBattery: Bool { showBattery && showPercent && percentInBattery }
    /// Number as its own column.
    static var numberBeside: Bool { showPercent && !numberInsideBattery }

    static func percentText(_ v: Double) -> String {
        let n = "\(Int(v.rounded()))"
        return percentSign ? n + "%" : n
    }
}

/// Provider brand tints, used for the glyphs only.
enum Brand {
    /// Claude terracotta
    static let claude = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
    /// ChatGPT green
    static let codex = NSColor(srgbRed: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255, alpha: 1)
}

/// macOS-battery-style gauge: rounded body, terminal nub, fill proportional to
/// `remaining` (0...100). Label color normally, red when low (see Settings.lowThreshold).
/// empty. With `label`, the number is drawn inside the body iPhone-style over a
/// translucent fill.
enum BatteryIcon {
    static let size = NSSize(width: 27, height: 12)

    /// Body width for a given height; wider when a number sits inside.
    static func size(height h: CGFloat, wide: Bool) -> NSSize {
        NSSize(width: (wide ? h * 2.9 : h * 2.1) + 3, height: h)
    }

    static func image(remaining: Double?, error: Bool = false, size: NSSize = BatteryIcon.size,
                      label: String? = nil) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, remaining: remaining, error: error, label: label)
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Snap a value to the device pixel grid (0.5pt on Retina) so 1px strokes and
    /// small glyphs land on whole pixels instead of smearing across two.
    static func snap(_ v: CGFloat, scale: CGFloat = 2) -> CGFloat { (v * scale).rounded() / scale }

    /// Draw the gauge directly into the current context (no intermediate bitmap).
    static func draw(in rect: NSRect, remaining: Double?, error: Bool = false, label: String? = nil) {
        do {
            let bodyRect = NSRect(x: snap(rect.minX) + 0.5, y: snap(rect.minY) + 0.5,
                                  width: snap(rect.width) - 4, height: snap(rect.height) - 1)
            let radius = min(3, bodyRect.height / 3)
            let body = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
            let outline = NSColor.labelColor.withAlphaComponent(0.55)
            outline.setStroke()
            body.lineWidth = 1
            body.stroke()

            let nubH = max(3, bodyRect.height / 3)
            let nub = NSRect(x: bodyRect.maxX + 1, y: rect.midY - nubH / 2, width: 2, height: nubH)
            NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill(with: outline)

            func drawCentered(_ text: String, color: NSColor, weight: NSFont.Weight = .bold, scale: CGFloat = 0.8) {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: max(6, bodyRect.height * scale), weight: weight),
                    .foregroundColor: color,
                ]
                let s = NSAttributedString(string: text, attributes: attrs)
                let sz = s.size()
                s.draw(at: NSPoint(x: snap(bodyRect.midX - sz.width / 2), y: snap(bodyRect.midY - sz.height / 2 + 0.5)))
            }

            guard let r = remaining else {
                drawCentered(error ? "!" : "?", color: NSColor.labelColor.withAlphaComponent(0.7))
                return
            }
            let inset = snap(max(1.5, bodyRect.height / 6))
            let inner = bodyRect.insetBy(dx: inset, dy: inset)
            let w = snap(max(0, min(1, r / 100)) * inner.width)
            let fillRect = NSRect(x: inner.minX, y: inner.minY, width: max(w, r > 0 ? 1.5 : 0), height: inner.height)
            let color: NSColor = r <= Settings.lowThreshold ? .systemRed : .labelColor

            if let label {
                // iPhone style: translucent fill behind, solid number on top.
                let alpha: CGFloat = (r <= Settings.lowThreshold) ? 0.6 : 0.3
                NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill(with: color.withAlphaComponent(alpha))
                drawCentered(label, color: .labelColor, weight: .heavy, scale: 0.95)
            } else {
                NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill(with: color)
            }
        }
    }
}

extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// Small provider glyphs, tinted with the brand color.
enum ProviderGlyph {
    static let size = NSSize(width: 11, height: 11)

    static func image(symbol: String, fallback: String, tint: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let img = NSImage(size: size, flipped: false) { rect in
            if let sym = symbolImage {
                let sz = sym.size
                let scale = min(rect.width / sz.width, rect.height / sz.height, 1)
                let drawSize = NSSize(width: sz.width * scale, height: sz.height * scale)
                let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
                sym.draw(in: NSRect(origin: origin, size: drawSize))
                tint.set()
                rect.fill(using: .sourceAtop)
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: tint,
                ]
                let s = NSAttributedString(string: fallback, attributes: attrs)
                let sz = s.size()
                s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    static let claude = image(symbol: "asterisk", fallback: "✳", tint: Brand.claude)
    static let codex = image(symbol: "chevron.left.forwardslash.chevron.right", fallback: "</>", tint: Brand.codex)
    /// Shown when no provider is enabled, so the item stays visible and clickable.
    static let placeholder = image(symbol: "gauge.with.dots.needle.50percent", fallback: "◔", tint: .labelColor)
}

/// The status-item content view. Two stacked rows (Claude over Codex) with
/// aligned columns, or one line with both providers side by side. Drawing
/// directly (instead of an attributed title) lets us center on the menu bar's
/// exact vertical middle, in line with the system battery icon.
final class StatusView: NSView {
    struct Row {
        let glyph: NSImage
        let remaining: Double?
        let error: Bool
        let countdown: String?
    }

    var rows: [Row] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private let padding: CGFloat = 2
    private let gap: CGFloat = 2
    private let providerGap: CGFloat = 10
    /// Two rows only make sense with two providers; a single row centers itself.
    private var twoRows: Bool { Settings.twoRows && rows.count >= 2 }

    // Metrics: two-row mode scales to half the bar height; one-row mode matches
    // the system battery glyph (about 26x12pt) and 12pt menu-bar text.
    private var rowHeight: CGFloat { twoRows ? bounds.height / 2 : 16 }
    private var fontSize: CGFloat { twoRows ? max(9, min(13, rowHeight - 0.5)) : 12.5 }
    private var batterySize: NSSize {
        let inside = Settings.numberInsideBattery
        if twoRows { return BatteryIcon.size(height: rowHeight - (inside ? 1 : 2.5), wide: inside) }
        return BatteryIcon.size(height: inside ? 14 : 12, wide: inside)
    }
    private var glyphSize: CGFloat { twoRows ? rowHeight - 1.5 : 11 }

    /// If every column is off, still show the glyph so the item is visible.
    private var showGlyphs: Bool {
        Settings.showGlyphs || !(Settings.showBattery || Settings.showPercent || Settings.showCountdown)
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // let the button take clicks

    private func percentFont() -> NSFont { .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold) }
    private func dimFont() -> NSFont { .monospacedDigitSystemFont(ofSize: fontSize - 0.5, weight: .regular) }
    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    private var percentColumnWidth: CGFloat { width(Settings.percentText(100), percentFont()) }
    private func percentText(_ row: Row) -> String {
        row.remaining.map { Settings.percentText($0) } ?? (row.error ? "!" : "…")
    }

    /// Width of one provider's columns. In two-row mode the number column is a
    /// fixed width (right-aligned) and the countdown column is the widest one.
    private func rowWidth(_ row: Row, aligned: Bool) -> CGFloat {
        var cols: [CGFloat] = []
        if showGlyphs { cols.append(glyphSize) }
        if Settings.showBattery { cols.append(batterySize.width) }
        if Settings.numberBeside { cols.append(aligned ? percentColumnWidth : width(percentText(row), percentFont())) }
        if Settings.showCountdown {
            if aligned {
                let longest = rows.compactMap { $0.countdown }.map { width($0, dimFont()) }.max() ?? 0
                if longest > 0 { cols.append(longest) }
            } else if let c = row.countdown {
                cols.append(width(c, dimFont()))
            }
        }
        return cols.reduce(0, +) + gap * CGFloat(max(0, cols.count - 1))
    }

    func preferredWidth() -> CGFloat {
        guard !rows.isEmpty else { return 22 }
        if twoRows {
            return ceil(padding * 2 + (rows.map { rowWidth($0, aligned: true) }.max() ?? 0))
        }
        let total = rows.map { rowWidth($0, aligned: false) }.reduce(0, +)
        return ceil(padding * 2 + total + providerGap * CGFloat(max(0, rows.count - 1)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else {
            let g: CGFloat = 14
            ProviderGlyph.placeholder.draw(in: NSRect(x: BatteryIcon.snap(bounds.midX - g / 2), y: BatteryIcon.snap(bounds.midY - g / 2), width: g, height: g))
            return
        }
        if twoRows {
            let rh = rowHeight
            for (i, row) in rows.prefix(2).enumerated() {
                let top = bounds.height - CGFloat(i) * rh   // row i occupies [top - rh, top]
                _ = drawRow(row, x: padding, midY: top - rh / 2, aligned: true)
            }
        } else {
            var x = padding
            for row in rows {
                x = drawRow(row, x: x, midY: bounds.midY, aligned: false) + providerGap
            }
        }
    }

    /// Draws one provider's columns starting at `x`, centered on `midY`; returns the end x.
    private func drawRow(_ row: Row, x start: CGFloat, midY: CGFloat, aligned: Bool) -> CGFloat {
        var x = start
        let pctText = percentText(row)
        let snap: (CGFloat) -> CGFloat = { BatteryIcon.snap($0) }

        if showGlyphs {
            let g = glyphSize
            row.glyph.draw(in: NSRect(x: snap(x), y: snap(midY - g / 2), width: g, height: g))
            x += g + gap
        }
        if Settings.showBattery {
            let bs = batterySize
            BatteryIcon.draw(in: NSRect(x: snap(x), y: snap(midY - bs.height / 2), width: bs.width, height: bs.height),
                             remaining: row.remaining, error: row.error,
                             label: Settings.numberInsideBattery ? pctText : nil)
            x += bs.width + gap
        }
        if Settings.numberBeside {
            let pctColor: NSColor = (row.remaining ?? 100) <= Settings.lowThreshold ? .systemRed : .labelColor
            let pct = NSAttributedString(string: pctText, attributes: [.font: percentFont(), .foregroundColor: pctColor])
            let ps = pct.size()
            let colW = aligned ? percentColumnWidth : ps.width
            pct.draw(at: NSPoint(x: snap(x + colW - ps.width), y: snap(midY - ps.height / 2)))   // right-aligned column
            x += colW + gap
        }
        if Settings.showCountdown, let c = row.countdown {
            let cs = NSAttributedString(string: c, attributes: [.font: dimFont(), .foregroundColor: NSColor.secondaryLabelColor])
            let sz = cs.size()
            cs.draw(at: NSPoint(x: snap(x), y: snap(midY - sz.height / 2)))
            x += sz.width + gap
        }
        return x - gap
    }
}
