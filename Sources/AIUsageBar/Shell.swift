import Foundation

enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run a binary synchronously. Never call on the main thread.
    static func run(_ path: String, _ args: [String]) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(status: p.terminationStatus,
                      stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }
}

/// Generic-password keychain access through /usr/bin/security. Using the CLI
/// (rather than SecItem*) means reading Claude Code's own item does not trip an
/// access-control prompt, because `security` is what created that item.
enum Keychain {
    static func read(service: String, account: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        let r = Shell.run("/usr/bin/security", args)
        guard r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        let r = Shell.run("/usr/bin/security",
                          ["add-generic-password", "-U", "-s", service, "-a", account, "-w", value])
        return r.status == 0
    }

    static func delete(service: String, account: String) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account])
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                        jsonBody: Any? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Anthropic-style `error.details.error_code`, when present.
    static func errorCode(_ data: Data) -> String? {
        guard let j = json(data), let e = j["error"] as? [String: Any] else { return nil }
        if let d = e["details"] as? [String: Any], let c = d["error_code"] as? String { return c }
        return nil
    }

    static func errorSnippet(_ data: Data) -> String {
        if let j = json(data) {
            if let e = j["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let d = j["detail"] as? String { return d }
        }
        let s = String(decoding: data.prefix(160), as: UTF8.self)
        return s.isEmpty ? "(빈 응답)" : s
    }
}

extension Date {
    static func fromISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
