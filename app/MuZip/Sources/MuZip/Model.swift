import Foundation
import MuZipCore
import SwiftUI

/// The app's state: the questions asked, the channel, and the loop that passes texts between a channel and the open
/// question (automatic: every close-up Muse asks for is cropped and sent without asking).
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var inquiries: [Inquiry] = []
    @Published var selected: Inquiry.ID?
    @Published var status = "Ready"
    @Published var error: String?
    @Published var busy = false

    @AppStorage("channel") var channelKind: ChannelKind = .simulated
    @AppStorage("smsNumber") var smsNumber = ""   // empty: SMS_FROM from .env, through the simulator server
    @AppStorage("server") var server = "http://127.0.0.1:8765"
    @AppStorage("partsPerText") var partsPerText = 3

    private var channel: Channel?
    private var channelKey = ""
    private var polling: Task<Void, Never>?
    private var channelOf: [Inquiry.ID: ChannelKind] = [:]

    var current: Inquiry? { inquiries.first { $0.id == selected } }
    func channelUsed(_ q: Inquiry) -> ChannelKind { channelOf[q.id] ?? channelKind }

    private func makeChannel() -> Channel {
        let key = [channelKind.rawValue, smsNumber, server, String(partsPerText)].joined(separator: "|")
        if let channel, key == channelKey { return channel }
        let url = URL(string: server) ?? URL(string: "http://127.0.0.1:8765")!
        let c: Channel
        switch channelKind {
        case .sms: c = SMSChannel(number: smsNumber, partsPerText: partsPerText, server: url)
        case .simulated: c = SimulatedChannel(server: url)
        }
        channel = c; channelKey = key
        return c
    }

    /// The MuZip number: the one in Settings, or else SMS_FROM from the repo's .env (sim/server.py /api/phone/config).
    func loadNumber() async {
        guard smsNumber.isEmpty, let url = URL(string: server)?.appendingPathComponent("api/phone/config"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let n = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["sms_number"] as? String, !n.isEmpty else { return }
        smsNumber = n
    }

    func ask(photo: Photo, question: String) {
        if channelKind == .sms && smsNumber.isEmpty {
            Task {
                await loadNumber()
                if smsNumber.isEmpty { error = "Set the MuZip number in Settings, or SMS_FROM in .env with the simulator running." }
                else { ask(photo: photo, question: question) }
            }
            return
        }
        let q = Inquiry(photo: photo, question: question.isEmpty ? "What is this?" : question)
        inquiries.insert(q, at: 0)
        selected = q.id
        channelOf[q.id] = channelKind
        let c = makeChannel()
        (c as? SMSChannel)?.pic = q.pic
        let message = q.start()
        send(message, for: q, on: c, what: "Sending the sketch")
        startPolling()
    }

    /// `MuZip --ask <photo> "<question>" [--channel sms|simulated]`: asks at launch, in the window as usual, and prints
    /// every step on stdout (open -a MuZip --stdout <file> --args ...): how the whole loop is checked from the app itself.
    func autoAsk(_ args: [String]) {
        guard let i = args.firstIndex(of: "--ask"), args.count > i + 2 else { return }
        if let c = args.firstIndex(of: "--channel"), args.count > c + 1, let k = ChannelKind(rawValue: args[c + 1].uppercased() == "SMS" ? "SMS" : "Simulated") {
            channelKind = k
        }
        guard let photo = Photo(url: URL(fileURLWithPath: args[i + 1])) else { return say("can't read the photo") }
        say("asking by \(channelKind.rawValue): \(args[i + 2])")
        ask(photo: photo, question: args[i + 2])
    }

    private var printed: [UUID: Int] = [:]

    private func say(_ s: String) {
        FileHandle.standardOutput.write((ISO8601DateFormatter().string(from: Date()).suffix(9) + " " + s + "\n").data(using: .utf8)!)
    }

    /// Prints the events of `q` not printed yet.
    private func report(_ q: Inquiry) {
        for e in q.events.dropFirst(printed[q.id] ?? 0) {
            switch e {
            case .asked(let t, let n, let b): say("sent    sketch \(b) B, \(n) texts: \(t)")
            case .muse(let w): say("muse    \(w.replacingOccurrences(of: "\n", with: " "))")
            case .closeUps(let cs, let n): say("sent    \(cs.count) close-up(s) \(cs.map { "\($0.size.0)x\($0.size.1)\($0.colour ? " C" : "")\($0.high ? " H" : "") \($0.data.count) B" }.joined(separator: ", ")), \(n) texts")
            case .answer(let a): say("answer  \(a.replacingOccurrences(of: "\n", with: " ")) [\(q.textsSent) texts, \(q.bytesSent) B in all]")
            case .note(let n): say("note    \(n)")
            }
        }
        printed[q.id] = q.events.count
    }

    private func send(_ message: String, for q: Inquiry, on c: Channel, what: String) {
        report(q)
        busy = true
        status = "\(what): \(Codes.smsParts(message)) texts by \(c.label)…"
        error = nil
        objectWillChange.send()
        Task {
            do {
                try await c.send(message)
                status = "Waiting for Muse…"
            } catch {
                say("error   \(error.localizedDescription)")
                self.error = error.localizedDescription
                status = "Not sent"
                busy = false
            }
        }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let q = inquiries.first(where: { !$0.done }) else {
            busy = false
            return
        }
        let c = makeChannel()
        do {
            for text in try await c.poll() {
                if let back = q.receive(text) {
                    send(back, for: q, on: c, what: "Sending \(q.closeUps.isEmpty ? "parts again" : "close-ups")")
                } else if q.done {
                    report(q)
                    status = "Answered: \(q.textsSent) texts, \(q.bytesSent.formatted()) bytes sent"
                    busy = false
                }
                objectWillChange.send()
            }
        } catch {
            if self.error != error.localizedDescription { say("error   \(error.localizedDescription)") }
            self.error = error.localizedDescription
        }
    }
}
