import Foundation
import MuZipCore
import SwiftUI
import UIKit

/// How the iPhone app reaches the MuZip number. iOS lets no app send or read texts by itself, so SMS goes through
/// two Shortcuts the person sets up once (see SetupView): "MuZip Send" sends what MuZip hands it, and a Message
/// automation hands every text from the MuZip number back to MuZip (muzip://reply?text=...).
enum PhoneChannel: String, CaseIterable, Identifiable {
    case sms = "SMS", whatsapp = "WhatsApp", simulated = "Simulated"
    var id: String { rawValue }
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var inquiries: [Inquiry] = []
    @Published var status = "Ready"
    @Published var error: String?
    @Published var path: [UUID] = []

    @AppStorage("channel") var channel: PhoneChannel = .sms
    @AppStorage("smsNumber") var smsNumber = "+1 737 258 3742"
    @AppStorage("whatsappNumber") var whatsappNumber = "+1 415 523 8886"
    @AppStorage("macServer") var macServer = "http://your-mac.local:8765"
    @AppStorage("shortcutName") var shortcutName = "MuZip Send"
    @AppStorage("partsPerText") var partsPerText = 3

    private var channelOf: [UUID: PhoneChannel] = [:]
    private var after = Date().timeIntervalSince1970
    private var polling: Task<Void, Never>?
    static let separator = "~~~"         // between texts, for the Shortcut's "Split Text"

    var open: Inquiry? { inquiries.first { !$0.done } }
    func inquiry(_ id: UUID) -> Inquiry? { inquiries.first { $0.id == id } }
    func channelUsed(_ q: Inquiry) -> PhoneChannel { channelOf[q.id] ?? channel }

    func ask(photo: Photo, question: String) {
        let q = Inquiry(photo: photo, question: question.isEmpty ? "What is this?" : question)
        inquiries.insert(q, at: 0)
        channelOf[q.id] = channel
        path = [q.id]
        after = Date().timeIntervalSince1970
        send(q.start(), for: q)
    }

    /// A text from the MuZip number (from the Shortcuts automation's URL, a paste, or the Mac): on to the open question,
    /// and its close-ups straight back.
    func receive(_ text: String) {
        guard let q = open else { status = "No open question for that reply"; return }
        if let back = q.receive(text) {
            send(back, for: q)
        } else if q.done {
            status = "Answered: \(q.textsSent) texts, \(q.bytesSent.formatted()) bytes sent"
            polling?.cancel(); polling = nil
        }
        objectWillChange.send()
    }

    func handle(url: URL) {
        guard url.scheme == "muzip", url.host == "reply",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value
        else { return }
        receive(text)
    }

    func pasteReply() {
        if let s = UIPasteboard.general.string, !s.isEmpty { receive(s) } else { error = "The clipboard has no text." }
    }

    private func send(_ message: String, for q: Inquiry) {
        error = nil
        let how = channelOf[q.id] ?? channel
        status = "Sending \(Codes.smsParts(message)) texts by \(how.rawValue)…"
        objectWillChange.send()
        switch how {
        case .sms: sendBySMS(message)
        case .whatsapp: sendByWhatsApp(message)
        case .simulated: sendSimulated(message)
        }
    }

    /// The Shortcut gets the texts joined by "~~~" lines; it splits them and sends each to the MuZip number.
    private func sendBySMS(_ message: String) {
        var texts: [String] = [], cur: [String] = []
        for line in message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            cur.append(line)
            if line.hasPrefix("#") && cur.filter({ $0.hasPrefix("#") }).count >= max(1, partsPerText) { texts.append(cur.joined(separator: "\n")); cur = [] }
        }
        if !cur.isEmpty { texts.append(cur.joined(separator: "\n")) }
        let q = strictQuery([("name", shortcutName), ("input", "text"),
                             ("text", texts.joined(separator: "\n\(PhoneModel.separator)\n")), ("x-success", "muzip://sent")])
        open(URL(string: "shortcuts://x-callback-url/run-shortcut?" + q), else: "Couldn't open Shortcuts. Set up \"\(shortcutName)\" first (Settings → Set up SMS).")
        status = "Waiting for Muse's text…"
    }

    /// WhatsApp fills in the message; you tap send. Replies come from the bridge's log through the Mac.
    private func sendByWhatsApp(_ message: String) {
        open(URL(string: "whatsapp://send?" + strictQuery([("phone", whatsappNumber.filter(\.isNumber)), ("text", message)])),
             else: "Couldn't open WhatsApp.")
        status = "Tap send in WhatsApp, then come back"
        startPolling()
    }

    private func sendSimulated(_ message: String) {
        guard let url = URL(string: macServer)?.appendingPathComponent("api/phone/ask") else { error = "Set your Mac's address in Settings."; return }
        Task {
            do {
                var r = URLRequest(url: url)
                r.httpMethod = "POST"; r.timeoutInterval = 180
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = try JSONSerialization.data(withJSONObject: ["who": "iphone:sim", "text": message])
                let (data, _) = try await URLSession.shared.data(for: r)
                let reply = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String ?? ""
                receive(reply)
            } catch {
                self.error = "Couldn't reach the simulator on your Mac (\(error.localizedDescription))."
            }
        }
    }

    private func startPolling() {
        guard polling == nil, let base = URL(string: macServer) else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                var c = URLComponents(url: base.appendingPathComponent("api/phone/replies"), resolvingAgainstBaseURL: false)!
                c.queryItems = [URLQueryItem(name: "after", value: String(after))]
                guard let (data, _) = try? await URLSession.shared.data(from: c.url!),
                      let rs = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["replies"] as? [[String: Any]] else { continue }
                for r in rs {
                    if let at = r["at"] as? Double { after = max(after, at) }
                    if let body = r["body"] as? String { receive(body) }
                }
            }
        }
    }

    private func open(_ url: URL?, else message: String) {
        guard let url else { error = message; return }
        UIApplication.shared.open(url) { ok in if !ok { Task { @MainActor in self.error = message } } }
    }
}

/// A query string with every character outside A-Z a-z 0-9 - . _ ~ percent-encoded: URLComponents leaves "+" as it is,
/// and Shortcuts and WhatsApp read a bare "+" as a space, which breaks the codes' base64.
func strictQuery(_ items: [(String, String)]) -> String {
    let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: ok)!)" }.joined(separator: "&")
}
