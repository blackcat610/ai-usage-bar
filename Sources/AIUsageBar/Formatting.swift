import Foundation

enum Fmt {
    /// ko: "2일 3시간", "3시간 12분", "12분", "리셋됨" — en: "2d 3h", "3h 12m", "12m", "reset"
    static func countdownLong(to date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return L.s("리셋됨", "reset") }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? L.s("\(d)일 \(h)시간", "\(d)d \(h)h") : L.s("\(d)일", "\(d)d") }
        if h > 0 { return L.s("\(h)시간 \(m)분", "\(h)h \(m)m") }
        return L.s("\(max(m, 1))분", "\(max(m, 1))m")
    }

    /// Compact form for the menu bar: "2d3h", "2h13m", "12m", "reset"
    static func countdownShort(to date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "reset" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(max(m, 1))m"
    }

    /// "14:47" when today, otherwise "9/8 14:47"
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: L.current == .ko ? "ko_KR" : "en_US_POSIX")
        f.dateFormat = cal.isDate(date, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: date)
    }

    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
