import Foundation
import MuZipCore

// For checking MuZipCore against the Python phone (tests/test_swift_core.py):
//   muzip-cli sketch <photo> <pic id>                    -> the sketch's code parts, one per line
//   muzip-cli zoom <photo> <pic id> "<ZOOM line>"        -> the Z message, then "box x y w h" (sketch px)
//   muzip-cli ask <photo> "<question>" [server]           -> the whole loop against sim/server.py (Simulated), printed
let args = CommandLine.arguments
if args.count >= 4, args[1] == "ask", let photo = Photo(url: URL(fileURLWithPath: args[2])) {
    let server = URL(string: args.count > 4 ? args[4] : "http://127.0.0.1:8765")!.appendingPathComponent("api/phone/ask")
    let q = Inquiry(photo: photo, question: args[3])
    var message: String? = q.start()
    var shown = 0
    func show() {
        for e in q.events[shown...] {
            switch e {
            case .asked(let t, let n, let b): print("You    \(t)  [sketch \(b) B, \(n) texts]")
            case .muse(let w): print("Muse   \(w.replacingOccurrences(of: "\n", with: " "))")
            case .closeUps(let cs, let n): print("You    \(cs.count) close-up(s) \(cs.map { "\($0.size.0)x\($0.size.1)\($0.colour ? " C" : "")\($0.high ? " H" : "") \($0.data.count) B" }.joined(separator: ", ")) [\(n) texts]")
            case .answer(let a): print("Muse   \(a.replacingOccurrences(of: "\n", with: " "))")
            case .note(let n): print("       \(n)")
            }
        }
        shown = q.events.count
    }
    show()
    while let m = message {
        var r = URLRequest(url: server)
        r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try! JSONSerialization.data(withJSONObject: ["who": "cli:\(q.pic)", "text": m])
        let sem = DispatchSemaphore(value: 0)
        var reply = ""
        URLSession.shared.dataTask(with: r) { d, _, e in
            if let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { reply = j["text"] as? String ?? "" }
            else { reply = "error: \(e?.localizedDescription ?? "no reply")" }
            sem.signal()
        }.resume()
        sem.wait()
        message = q.receive(reply)
        show()
    }
    print("\(q.textsSent) texts, \(q.bytesSent) bytes sent, photo \(photo.fileBytes) bytes")
    exit(0)
}
guard args.count >= 4, let photo = Photo(url: URL(fileURLWithPath: args[2])) else {
    FileHandle.standardError.write("usage: muzip-cli sketch|zoom <photo> <pic id> [ZOOM line]\n".data(using: .utf8)!)
    exit(2)
}
let pic = args[3]
switch args[1] {
case "sketch":
    print(Codes.parts(kind: "P", data: photo.sketch(), id: pic).joined(separator: "\n"))
    print("size \(photo.sketchSize.0) \(photo.sketchSize.1)")
case "zoom":
    guard args.count >= 5, let z = Codes.zooms(args[4], pic: pic).first else { exit(2) }
    let c = photo.closeUp(z)
    print(Codes.parts(kind: "Z", data: Codes.zoomHead(parent: pic, box: c.box) + c.data, id: String(pic.first!) + "z").joined(separator: "\n"))
    print("box " + c.box.map { String(format: "%.4f", $0) }.joined(separator: " "))
    print("size \(c.size.0) \(c.size.1)")
default:
    exit(2)
}
