import CoreGraphics
import Foundation

/// One question about one photo, as the phone sees it: send the sketch with the question, answer every ZOOM with
/// close-ups cropped from the original, until Muse answers. Channel-agnostic: it takes the texts Muse sends and
/// returns what to send back (the same logic as evac/whatsapp.look_closer and sim/wa_phone.py).
public final class Inquiry: Identifiable {
    public enum Event {
        case asked(question: String, texts: Int, bytes: Int)
        case muse(String)
        case closeUps([CloseUp], texts: Int)
        case answer(String)
        case note(String)
    }

    public struct CloseUp {
        public let crop: CGRect          // in the photo's pixels
        public let colour: Bool
        public let high: Bool
        public let data: Data            // the WebP sent
        public let size: (Int, Int)
    }

    public let id = UUID()
    public let photo: Photo
    public let question: String
    public let pic: String
    public private(set) var events: [Event] = []
    public private(set) var done = false
    public private(set) var textsSent = 0
    public private(set) var bytesSent = 0
    public let sketch: Data
    private var sent: [String: [String]] = [:]   // code id -> its parts, for RESEND

    public init(photo: Photo, question: String) {
        self.photo = photo
        self.question = question
        let a = Array("abcdefghjkmnpqrstuvwxyz"), b = Array("23456789abcdefghjkmnpqrstuvwxyz")
        pic = String([a.randomElement()!, b.randomElement()!])
        sketch = photo.sketch()
    }

    /// The first message: the question, then the sketch's code parts.
    public func start() -> String {
        let parts = Codes.parts(kind: "P", data: sketch, id: pic)
        sent[pic] = parts
        let message = question + "\n" + parts.joined(separator: "\n")
        let texts = Codes.smsParts(message)
        textsSent += texts; bytesSent += sketch.count
        events.append(.asked(question: question, texts: texts, bytes: sketch.count))
        return message
    }

    /// A text from the MuZip number. -> what to send back (close-ups, or parts asked for again), or nil.
    public func receive(_ raw: String) -> String? {
        guard !done else { return nil }
        let text = Inquiry.clean(raw)
        if let again = Codes.resend(text), let parts = sent[again.id] {
            let want = again.parts.filter { $0 >= 1 && $0 <= parts.count }.map { parts[$0 - 1] }
            events.append(.note("Muse missed \(want.count) part\(want.count == 1 ? "" : "s"); sent again."))
            textsSent += Codes.smsParts(want.joined(separator: "\n"))
            return want.joined(separator: "\n")
        }
        let zs = Codes.zooms(text, pic: pic)
        guard let first = zs.first else {
            done = true
            events.append(.answer(text))
            return nil
        }
        let words = String(text[..<first.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { events.append(.muse(words)) }
        var outs: [String] = [], ups: [CloseUp] = []
        for (i, z) in zs.prefix(5).enumerated() {
            let c = photo.closeUp(z)
            let id = String(pic.first!) + String(Array("zyxwv")[i])
            let parts = Codes.parts(kind: "Z", data: Codes.zoomHead(parent: pic, box: c.box) + c.data, id: id)
            sent[id] = parts
            outs.append(parts.joined(separator: "\n"))
            ups.append(CloseUp(crop: c.crop, colour: z.colour, high: z.high, data: c.data, size: c.size))
            bytesSent += c.data.count
        }
        let message = outs.joined(separator: "\n")
        let texts = Codes.smsParts(message)
        textsSent += texts
        events.append(.closeUps(ups, texts: texts))
        return message
    }

    /// Muse's words without what the channel adds: the brand, Twilio's trial line, the STOP line and the kit's note.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "Sent from your Twilio trial account - ", with: "")
        for junk in ["Reply STOP to opt out.", "Your kit crops it from your photo and sends it back.", "Your kit crops them from your photo and sends them back."] {
            t = t.replacingOccurrences(of: junk, with: "")
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("MuZip:") { t = String(t.dropFirst(6)) }
        return t.replacingOccurrences(of: " \n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every close-up sent so far.
    public var closeUps: [CloseUp] {
        events.flatMap { if case .closeUps(let c, _) = $0 { return c } else { return [] } }
    }
}
