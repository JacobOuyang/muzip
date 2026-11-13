import Foundation

/// The text codes a photo and its close-ups travel as (evac/codes.py, sim/kit.js): `#<type><id>.<i>/<n>:<base64>:<crc16>#`,
/// each part at most one SMS in the basic alphabet. Every phone parses the same ZOOM line; change it in all three together.
public enum Codes {
    public static let partChars = 153
    public static let high = 256           // a high-detail close-up's side (" H")
    public static let minCrop = 48.0       // the smallest crop, in the original's pixels

    public struct Code { public let kind: Character; public let id: String; public let data: Data }

    /// One "ZOOM <pic> x y w h[ C][ H]" line: a box in the sketch's pixels.
    public struct Zoom {
        public let pic: String
        public let box: [Int]
        public let colour: Bool
        public let high: Bool
        public let range: Range<String.Index>
    }

    public static func crc16(_ s: String) -> String {
        var c: UInt16 = 0xFFFF
        for b in s.utf8 {
            c ^= UInt16(b) << 8
            for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        }
        return String(format: "%04x", c)
    }

    /// The parts of one code (each fits one SMS).
    public static func parts(kind: Character, data: Data, id: String) -> [String] {
        let b64 = Array(data.base64EncodedString())
        let head = "#\(kind)\(id).9/9:".count + ":xxxx#".count
        let size = partChars - head - 2
        var chunks: [String] = []
        var i = 0
        while i < b64.count { chunks.append(String(b64[i..<min(i + size, b64.count)])); i += size }
        if chunks.isEmpty { chunks = [""] }
        return chunks.enumerated().map { "#\(kind)\(id).\($0.offset + 1)/\(chunks.count):\($0.element):\(crc16($0.element))#" }
    }

    private static let code = try! NSRegularExpression(pattern: "#([PZKMGTLSA])([0-9a-z]{2,4})\\.(\\d+)/(\\d+):([A-Za-z0-9+/=]*):([0-9a-f]{4})#")
    private static let zoom = try! NSRegularExpression(pattern: "\\bZOOM\\s+([0-9a-z]{2,4})((?:\\s+\\d+){1,4})((?:\\s+[CH]\\b)*)", options: .caseInsensitive)
    private static let resendRx = try! NSRegularExpression(pattern: "\\bRESEND\\s+([0-9a-z]{2,4})((?:\\s+\\d+)+)", options: .caseInsensitive)

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    /// Every code in a message: the complete ones, and the part numbers still missing per id.
    public static func decode(_ message: String) -> (complete: [Code], missing: [String: [Int]]) {
        var got: [String: (kind: Character, n: Int, parts: [Int: String])] = [:]
        var order: [String] = []
        for m in code.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            let g = groups(m, in: message)
            guard crc16(g[5]) == g[6], let i = Int(g[3]), let n = Int(g[4]) else { continue }
            if got[g[2]] == nil { got[g[2]] = (Character(g[1]), n, [:]); order.append(g[2]) }
            got[g[2]]!.parts[i] = g[5]
        }
        var complete: [Code] = [], missing: [String: [Int]] = [:]
        for id in order {
            let g = got[id]!
            let lost = (1...max(1, g.n)).filter { g.parts[$0] == nil }
            if !lost.isEmpty { missing[id] = lost; continue }
            if let d = Data(base64Encoded: (1...g.n).map { g.parts[$0]! }.joined()) { complete.append(Code(kind: g.kind, id: id, data: d)) }
        }
        return (complete, missing)
    }

    /// Every ZOOM for a box in a message, for picture `pic` if given, in the order asked.
    public static func zooms(_ message: String, pic: String? = nil) -> [Zoom] {
        zoom.matches(in: message, range: NSRange(message.startIndex..., in: message)).compactMap { m in
            let g = groups(m, in: message)
            let nums = g[2].split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
            let flags = g[3].uppercased().split(whereSeparator: { $0.isWhitespace })
            guard nums.count == 4, pic == nil || g[1].lowercased() == pic, let r = Range(m.range, in: message) else { return nil }
            return Zoom(pic: g[1].lowercased(), box: nums, colour: flags.contains("C"), high: flags.contains("H"), range: r)
        }
    }

    /// "RESEND <id> 2 5": the part numbers a server asks for again.
    public static func resend(_ message: String) -> (id: String, parts: [Int])? {
        guard let m = resendRx.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) else { return nil }
        let g = groups(m, in: message)
        return (g[1].lowercased(), g[2].split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) })
    }

    /// A Z code's header: the parent's id (length byte + id), then its box as 4 x uint16 in 1/64 px.
    public static func zoomHead(parent: String, box: [Double]) -> Data {
        var d = Data([UInt8(parent.utf8.count)]) + Data(parent.utf8)
        for v in box {
            let u = UInt16(max(0, min(65535, (v * 64).rounded(.toNearestOrEven))))
            d.append(UInt8(u >> 8)); d.append(UInt8(u & 0xFF))
        }
        return d
    }

    /// SMS a text takes: 160 alone / 153 a part in the basic alphabet, else 70 / 67.
    public static func smsParts(_ text: String) -> Int {
        if text.allSatisfy({ gsm7.contains($0) }) { return text.count <= 160 ? 1 : (text.count + 152) / 153 }
        let units = text.utf16.count
        return units <= 70 ? 1 : (units + 66) / 67
    }

    static let gsm7 = Set("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà")
}
