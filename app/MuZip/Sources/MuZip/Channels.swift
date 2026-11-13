import AppKit
import Foundation
import SQLite3

/// How texts reach the MuZip number and how its replies come back. Every channel carries the same text codes.
protocol Channel: AnyObject {
    var label: String { get }
    func send(_ text: String) async throws
    func poll() async throws -> [String]     // texts from the MuZip number since the last poll
}

enum ChannelKind: String, CaseIterable, Identifiable {
    case sms = "SMS", whatsapp = "WhatsApp", simulated = "Simulated"
    var id: String { rawValue }
}

struct ChannelError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

// MARK: - Simulated: straight to the router on this Mac (sim/server.py), no texts

final class SimulatedChannel: Channel {
    let label = "Simulated"
    let server: URL
    private var inbox: [String] = []
    init(server: URL) { self.server = server }

    func send(_ text: String) async throws {
        var r = URLRequest(url: server.appendingPathComponent("api/phone/ask"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["who": "mac:sim", "text": text])
        r.timeoutInterval = 180
        let (data, _) = try await URLSession.shared.data(for: r)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let reply = j["text"] as? String else {
            throw ChannelError("The simulator didn't answer (is sim/server.py running?)")
        }
        inbox.append(reply)
    }

    func poll() async throws -> [String] { defer { inbox = [] }; return inbox }
}

// MARK: - WhatsApp: from your WhatsApp Desktop to the sandbox; replies read from the bridge's log on this Mac

final class WhatsAppChannel: Channel {
    let label = "WhatsApp"
    let number: String          // the Muse number, digits only
    let server: URL
    private var after = Date().timeIntervalSince1970

    init(number: String, server: URL) { self.number = number.filter(\.isNumber); self.server = server }

    func send(_ text: String) async throws {
        guard let url = URL(string: "whatsapp://send?" + strictQuery([("phone", number), ("text", text)])), NSWorkspace.shared.open(url) else { throw ChannelError("Couldn't open WhatsApp Desktop.") }
        // WhatsApp fills in the message; macOS only sends a key press to the front app, so bring it forward for a moment.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let previous = NSWorkspace.shared.frontmostApplication
        try await onMain("""
            tell application "WhatsApp" to activate
            delay 0.6
            tell application "System Events" to keystroke return
            """)
        try await Task.sleep(nanoseconds: 400_000_000)
        previous?.activate()
    }

    func poll() async throws -> [String] {
        var c = URLComponents(url: server.appendingPathComponent("api/phone/replies"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "after", value: String(after))]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rs = j["replies"] as? [[String: Any]] else { return [] }
        if let last = rs.last?["at"] as? Double { after = last }
        return rs.compactMap { $0["body"] as? String }
    }
}

// MARK: - SMS: real texts from your number through the Messages app (your iPhone relays them)

final class SMSChannel: Channel {
    let label = "SMS"
    let number: String          // the MuZip number, +1...
    let partsPerText: Int
    private var lastRow: Int64 = -1

    init(number: String, partsPerText: Int) {
        let digits = number.filter(\.isNumber)
        self.number = "+" + (digits.count == 10 ? "1" + digits : digits)
        self.partsPerText = max(1, partsPerText)
    }

    /// A long message goes as several texts of a few code parts each (one long SMS can turn into an MMS on the way).
    func send(_ text: String) async throws {
        var texts: [String] = [], cur: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            cur.append(line)
            if line.hasPrefix("#") && cur.filter({ $0.hasPrefix("#") }).count >= partsPerText { texts.append(cur.joined(separator: "\n")); cur = [] }
        }
        if !cur.isEmpty { texts.append(cur.joined(separator: "\n")) }
        if lastRow < 0 { lastRow = try latestRow() }
        for t in texts {
            let esc = t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            try await onMain("""
                tell application "Messages"
                    set svc to first account whose service type is SMS
                    send "\(esc)" to participant "\(number)" of svc
                end tell
                """)
            try await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    func poll() async throws -> [String] {
        if lastRow < 0 { lastRow = try latestRow(); return [] }
        var out: [String] = []
        try withChatDB { db in
            let sql = """
                SELECT m.ROWID, m.text, m.attributedBody FROM message m JOIN handle h ON m.handle_id = h.ROWID
                WHERE h.id = ? AND m.is_from_me = 0 AND m.ROWID > ? ORDER BY m.ROWID
                """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw ChannelError("Couldn't read Messages.") }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_text(st, 1, number, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(st, 2, lastRow)
            while sqlite3_step(st) == SQLITE_ROW {
                lastRow = sqlite3_column_int64(st, 0)
                if let c = sqlite3_column_text(st, 1), case let s = String(cString: c), !s.isEmpty { out.append(s); continue }
                if let b = sqlite3_column_blob(st, 2) {
                    let data = Data(bytes: b, count: Int(sqlite3_column_bytes(st, 2)))
                    if let a = NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString { out.append(a.string) }
                }
            }
        }
        return out
    }

    private func latestRow() throws -> Int64 {
        var row: Int64 = 0
        try withChatDB { db in
            var st: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT MAX(ROWID) FROM message", -1, &st, nil)
            defer { sqlite3_finalize(st) }
            if sqlite3_step(st) == SQLITE_ROW { row = sqlite3_column_int64(st, 0) }
        }
        return row
    }

    private func withChatDB(_ body: (OpaquePointer) throws -> Void) throws {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ChannelError("MuZip can't read Messages. Give it Full Disk Access in System Settings → Privacy & Security.")
        }
        defer { sqlite3_close(db) }
        try body(db)
    }
}

func onMain(_ source: String) async throws { try await MainActor.run { try runAppleScript(source) } }

func runAppleScript(_ source: String) throws {
    var err: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { throw ChannelError((err[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed") }
}

/// A query string with every character outside A-Z a-z 0-9 - . _ ~ percent-encoded: URLComponents leaves "+" as it is,
/// and Shortcuts and WhatsApp read a bare "+" as a space, which breaks the codes' base64.
func strictQuery(_ items: [(String, String)]) -> String {
    let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: ok)!)" }.joined(separator: "&")
}
