import Foundation
import MuZipCore
import SwiftUI

/// The app's state: the questions asked, the channel, and the loop that passes texts between a channel and the open
/// question (automatic: every close-up Muse asks for is cropped and sent without asking).
@MainActor
final class AppModel: ObservableObject {
    @Published var inquiries: [Inquiry] = []
    @Published var selected: Inquiry.ID?
    @Published var status = "Ready"
    @Published var error: String?
    @Published var busy = false

    @AppStorage("channel") var channelKind: ChannelKind = .simulated
    @AppStorage("smsNumber") var smsNumber = "+1 737 258 3742"
    @AppStorage("whatsappNumber") var whatsappNumber = "+1 415 523 8886"
    @AppStorage("server") var server = "http://127.0.0.1:8765"
    @AppStorage("partsPerText") var partsPerText = 3

    private var channel: Channel?
    private var channelKey = ""
    private var polling: Task<Void, Never>?
    private var channelOf: [Inquiry.ID: ChannelKind] = [:]

    var current: Inquiry? { inquiries.first { $0.id == selected } }
    func channelUsed(_ q: Inquiry) -> ChannelKind { channelOf[q.id] ?? channelKind }

    private func makeChannel() -> Channel {
        let key = [channelKind.rawValue, smsNumber, whatsappNumber, server, String(partsPerText)].joined(separator: "|")
        if let channel, key == channelKey { return channel }
        let url = URL(string: server) ?? URL(string: "http://127.0.0.1:8765")!
        let c: Channel
        switch channelKind {
        case .sms: c = SMSChannel(number: smsNumber, partsPerText: partsPerText)
        case .whatsapp: c = WhatsAppChannel(number: whatsappNumber, server: url)
        case .simulated: c = SimulatedChannel(server: url)
        }
        channel = c; channelKey = key
        return c
    }

    func ask(photo: Photo, question: String) {
        let q = Inquiry(photo: photo, question: question.isEmpty ? "What is this?" : question)
        inquiries.insert(q, at: 0)
        selected = q.id
        channelOf[q.id] = channelKind
        let c = makeChannel()
        let message = q.start()
        send(message, for: q, on: c, what: "Sending the sketch")
        startPolling()
    }

    private func send(_ message: String, for q: Inquiry, on c: Channel, what: String) {
        busy = true
        status = "\(what): \(Codes.smsParts(message)) texts by \(c.label)…"
        error = nil
        objectWillChange.send()
        Task {
            do {
                try await c.send(message)
                status = "Waiting for Muse…"
            } catch {
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
                    status = "Answered: \(q.textsSent) texts, \(q.bytesSent.formatted()) bytes sent"
                    busy = false
                }
                objectWillChange.send()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
