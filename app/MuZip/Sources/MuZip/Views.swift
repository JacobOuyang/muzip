import ImageIO
import MuZipCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MuZipApp: App {
    @StateObject private var model = AppModel()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("MuZip") {
            ContentView().environmentObject(model).frame(minWidth: 980, minHeight: 600)
        }
        Settings { SettingsView().environmentObject(model).frame(width: 460) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selected) {
                Logo(height: 34).padding(.vertical, 6)
                Section("Questions") {
                    ForEach(model.inquiries) { q in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.question).lineLimit(2)
                            Text("\(model.channelUsed(q).rawValue) · \(q.textsSent) texts\(q.done ? "" : " · asking")")
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(q.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                Button { model.selected = nil } label: { Label("New question", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(10)
            }
        } detail: {
            if let q = model.current {
                InquiryView(q: q)
            } else {
                NewQuestionView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.error ?? model.status).font(.callout).foregroundStyle(model.error == nil ? Color.secondary : Color.red).lineLimit(1)
            }
            ToolbarItem {
                Picker("Send by", selection: $model.channelKind) {
                    ForEach(ChannelKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260).help("How MuZip reaches Muse. Set the numbers in Settings (⌘,).")
            }
        }
    }
}

/// The MuZip logo (docs/logo-light.svg and logo-dark.svg, rendered into the app's Resources by make_app.sh).
struct Logo: View {
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let url = Bundle.main.url(forResource: scheme == .dark ? "logo-dark" : "logo-light", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit().frame(height: height).accessibilityLabel("MuZip")
        } else {
            Text("MuZip").font(.system(size: height * 0.5, weight: .semibold))
        }
    }
}

// MARK: - Asking

struct NewQuestionView: View {
    @EnvironmentObject var model: AppModel
    @State private var photo: Photo?
    @State private var url: URL?
    @State private var question = ""
    @State private var picking = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 16) {
            Logo(height: 56)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(targeted ? 0.18 : 0.08))
                if let photo {
                    Image(decorative: photo.image, scale: 1).resizable().scaledToFit().padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop a photo here, or choose one").foregroundStyle(.secondary)
                        Button("Choose photo…") { picking = true }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { items in
                _ = items.first?.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { load(u) } }
                }
                return true
            }
            if let photo {
                Text("\(photo.width) × \(photo.height), \(ByteCountFormatter.string(fromByteCount: Int64(photo.fileBytes), countStyle: .file)). It stays on this Mac; Muse gets a \(Photo.side) px grey sketch, then only the close-ups it asks for.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Is this a black widow?", text: $question).textFieldStyle(.roundedBorder).onSubmit(ask)
                Button("Photo…") { picking = true }
                Button("Ask", action: ask).keyboardShortcut(.defaultAction).disabled(photo == nil)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { r in if case .success(let u) = r { load(u) } }
    }

    private func load(_ u: URL) {
        let access = u.startAccessingSecurityScopedResource()
        defer { if access { u.stopAccessingSecurityScopedResource() } }
        if let p = Photo(url: u) { photo = p; url = u } else { model.error = "That file isn't a photo MuZip can read." }
    }

    private func ask() {
        guard let photo else { return }
        model.ask(photo: photo, question: question.trimmingCharacters(in: .whitespacesAndNewlines))
        self.photo = nil; question = ""
    }
}

// MARK: - One question

struct InquiryView: View {
    @EnvironmentObject var model: AppModel
    let q: Inquiry

    var body: some View {
        HSplitView {
            PhotoPane(q: q).frame(minWidth: 380)
            Thread(q: q).frame(minWidth: 320)
        }
    }
}

struct PhotoPane: View {
    let q: Inquiry
    @State private var hover: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let s = min(geo.size.width / CGFloat(q.photo.width), geo.size.height / CGFloat(q.photo.height))
                let w = CGFloat(q.photo.width) * s, h = CGFloat(q.photo.height) * s
                ZStack(alignment: .topLeading) {
                    Image(decorative: q.photo.image, scale: 1).resizable().frame(width: w, height: h)
                    ForEach(Array(q.closeUps.enumerated()), id: \.offset) { i, c in
                        Rectangle().strokeBorder(c.colour ? Color.orange : Color.accentColor, lineWidth: hover == i ? 3 : 2)
                            .frame(width: c.crop.width * s, height: c.crop.height * s)
                            .offset(x: c.crop.minX * s, y: c.crop.minY * s)
                        Text("\(i + 1)").font(.caption.bold()).padding(3).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: c.crop.minX * s + 3, y: c.crop.minY * s + 3)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            Text("Your photo stays on this Mac. The boxes are the close-ups sent.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What Muse saw").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            Seen(data: q.sketch, label: "sketch")
                            ForEach(Array(q.closeUps.enumerated()), id: \.offset) { i, c in
                                Seen(data: c.data, label: "\(i + 1)\(c.colour ? " C" : "")\(c.high ? " H" : "")")
                                    .onHover { hover = $0 ? i : nil }
                            }
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Sent so far").font(.caption).foregroundStyle(.secondary)
                    Text("\(q.textsSent) texts").font(.title2.weight(.medium))
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(q.bytesSent), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(q.photo.fileBytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }
}

/// A picture as Muse got it (decoded from the WebP sent), shown enlarged without smoothing.
struct Seen: View {
    let data: Data
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            if let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                Image(decorative: img, scale: 1).resizable().interpolation(.none).scaledToFit().frame(height: 64)
                    .help("\(img.width)×\(img.height) px, \(data.count) bytes")
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct Thread: View {
    @EnvironmentObject var model: AppModel
    let q: Inquiry

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(q.events.enumerated()), id: \.offset) { i, e in
                        bubble(e).id(i)
                    }
                    if !q.done {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.status).font(.caption).foregroundStyle(.secondary) }
                            .padding(.top, 4).id(-1)
                    }
                }
                .padding(16)
            }
            .onChange(of: q.events.count) { _ in withAnimation { proxy.scrollTo(q.done ? q.events.count - 1 : -1) } }
        }
    }

    @ViewBuilder func bubble(_ e: Inquiry.Event) -> some View {
        switch e {
        case .asked(let question, let texts, let bytes):
            Bubble(text: question, meta: "sketch, \(Photo.side) px grey · \(bytes) bytes · \(texts) texts", mine: true)
        case .muse(let words):
            Bubble(text: words, meta: "Muse")
        case .closeUps(let cs, let texts):
            let what = cs.map { "\($0.size.0)×\($0.size.1)\($0.colour ? " colour" : " grey")\($0.high ? ", high detail" : "")" }.joined(separator: " + ")
            Bubble(text: cs.count == 1 ? "Close-up sent automatically" : "\(cs.count) close-ups sent automatically",
                   meta: "\(what) · \(cs.reduce(0) { $0 + $1.data.count }) bytes · \(texts) texts", mine: true)
        case .answer(let a):
            Bubble(text: a, meta: "answer · \(q.textsSent) texts in all", answer: true)
        case .note(let n):
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Bubble: View {
    let text: String
    let meta: String
    var mine = false
    var answer = false

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(text).textSelection(.enabled)
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(answer ? Color.green.opacity(0.7) : .clear))
            if !mine { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Send by", selection: $model.channelKind) { ForEach(ChannelKind.allCases) { Text($0.rawValue).tag($0) } }
            Section("SMS") {
                TextField("MuZip number", text: $model.smsNumber)
                Stepper("Code parts per text: \(model.partsPerText)", value: $model.partsPerText, in: 1...10)
                Text("Sent from your number through Messages (turn on Text Message Forwarding on your iPhone). Reading replies needs Full Disk Access for MuZip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("WhatsApp") {
                TextField("Muse number", text: $model.whatsappNumber)
                Text("Sent from WhatsApp Desktop (MuZip needs Accessibility to press Return). Replies are read from the bridge's log through the simulator server below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                TextField("Simulator server", text: $model.server)
                Text("sim/server.py: Simulated asks the router directly; WhatsApp reads replies here.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
