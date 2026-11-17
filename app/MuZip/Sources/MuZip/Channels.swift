import AppKit
import Foundation

/// How texts reach the MuZip number and how its replies come back. Every channel carries the same text codes.
protocol Channel: AnyObject {
    var label: String { get }
    func send(_ text: String) async throws
    func poll() async throws -> [String]     // texts from the MuZip number since the last poll
}

enum ChannelKind: String, CaseIterable, Identifiable {
    case sms = "SMS", simulated = "Simulated"
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

// MARK: - SMS: real texts from your number through the Messages app (your iPhone relays them); Muse's replies are read
// from the bridge's log on this Mac (sim/server.py), found by the photo's id, so MuZip needs no Full Disk Access

final class SMSChannel: Channel {
    let label = "SMS"
    let number: String          // the MuZip number, +1...
    let partsPerText: Int
    let server: URL
    var pic = ""                // the open question's photo id: how the bridge's log finds your number
    private var after = Date().timeIntervalSince1970

    init(number: String, partsPerText: Int, server: URL) {
        let digits = number.filter(\.isNumber)
        self.number = "+" + (digits.count == 10 ? "1" + digits : digits)
        self.partsPerText = max(1, partsPerText)
        self.server = server
    }

    /// A long message goes as several texts of a few code parts each (one long SMS can turn into an MMS on the way).
    func send(_ text: String) async throws {
        var texts: [String] = [], cur: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            cur.append(line)
            if line.hasPrefix("#") && cur.filter({ $0.hasPrefix("#") }).count >= partsPerText { texts.append(cur.joined(separator: "\n")); cur = [] }
        }
        if !cur.isEmpty { texts.append(cur.joined(separator: "\n")) }
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
        guard !pic.isEmpty else { return [] }
        var c = URLComponents(url: server.appendingPathComponent("api/phone/replies"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "pic", value: pic), URLQueryItem(name: "after", value: String(after))]
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: c.url!) }
        catch { throw ChannelError("Can't reach the MuZip simulator on this Mac for Muse's replies (is sim/server.py running?).") }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rs = j["replies"] as? [[String: Any]] else { return [] }
        if let last = rs.last?["at"] as? Double { after = last }
        return rs.compactMap { $0["body"] as? String }
    }
}

func onMain(_ source: String) async throws { try await MainActor.run { try runAppleScript(source) } }

func runAppleScript(_ source: String) throws {
    var err: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { throw ChannelError((err[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed") }
}

