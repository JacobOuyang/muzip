import ImageIO
import MuZipCore
import PhotosUI
import SwiftUI

@main
struct MuZipPhoneApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            HomeView().environmentObject(model)
                .onOpenURL { model.handle(url: $0) }   // muzip://reply?text=... from the Shortcuts automation
        }
    }
}

// MARK: - Home: ask, and the questions so far

struct HomeView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var settings = false

    var body: some View {
        NavigationStack(path: $model.path) {
            List {
                Section { AskView() }
                if !model.inquiries.isEmpty {
                    Section("Questions") {
                        ForEach(model.inquiries) { q in
                            NavigationLink(value: q.id) {
                                HStack(spacing: 12) {
                                    Image(decorative: q.photo.image, scale: 1).resizable().scaledToFill().frame(width: 44, height: 44).clipped().cornerRadius(6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(q.question).lineLimit(2)
                                        Text("\(model.channelUsed(q).rawValue) · \(q.textsSent) texts\(q.done ? "" : " · asking")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) { Image("Logo").resizable().scaledToFit().frame(height: 30).accessibilityLabel("MuZip") }
                ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") } }
            }
            .navigationDestination(for: UUID.self) { id in
                if let q = model.inquiry(id) { InquiryView(q: q) }
            }
            .sheet(isPresented: $settings) { SettingsView() }
        }
    }
}

struct AskView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var photo: Photo?
    @State private var question = ""
    @State private var camera = false
    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            if let photo {
                Image(decorative: photo.image, scale: 1).resizable().scaledToFit().frame(maxHeight: 260).cornerRadius(10)
                Text("\(photo.width) × \(photo.height), \(ByteCountFormatter.string(fromByteCount: Int64(photo.fileBytes), countStyle: .file)). It stays on your iPhone: Muse gets a \(Photo.side) px grey sketch, then only the close-ups it asks for.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { camera = true } label: { Label(photo == nil ? "Take photo" : "Retake", systemImage: "camera").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!UIImagePickerController.hasCamera)
                PhotosPicker(selection: $picked, matching: .images) { Label("Library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            TextField("Is this a black widow?", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
            Picker("Send by", selection: $model.channel) { ForEach(PhoneChannel.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Button {
                guard let photo else { return }
                model.ask(photo: photo, question: question.trimmingCharacters(in: .whitespacesAndNewlines))
                self.photo = nil; question = ""
            } label: { Text("Ask Muse").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(photo == nil)
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 6)
        .fullScreenCover(isPresented: $camera) {
            CameraView { p in
                if let p { photo = p }
                camera = false
            }.ignoresSafeArea()
        }
        .onChange(of: picked) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self), let p = Photo(data: data) { photo = p }
            }
        }
    }
}

// MARK: - One question

struct InquiryView: View {
    @EnvironmentObject var model: PhoneModel
    let q: Inquiry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhotoWithBoxes(q: q)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What Muse saw").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Seen(data: q.sketch, label: "sketch")
                                ForEach(Array(q.closeUps.enumerated()), id: \.offset) { i, c in
                                    Seen(data: c.data, label: "\(i + 1)\(c.colour ? " C" : "")\(c.high ? " H" : "")")
                                }
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(q.textsSent) texts").font(.title3.weight(.medium))
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(q.bytesSent), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(q.photo.fileBytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(q.events.enumerated()), id: \.offset) { _, e in bubble(e) }
                if !q.done {
                    HStack(spacing: 6) { ProgressView(); Text(model.status).font(.caption).foregroundStyle(.secondary) }
                    if model.channelUsed(q) == .sms {
                        Button("Paste Muse's text") { model.pasteReply() }.font(.callout)
                    }
                }
                if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            .padding()
        }
        .navigationTitle(q.question).navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder func bubble(_ e: Inquiry.Event) -> some View {
        switch e {
        case .asked(let question, let texts, let bytes):
            Bubble(text: question, meta: "sketch, \(Photo.side) px grey · \(bytes) bytes · \(texts) texts", mine: true)
        case .muse(let words):
            Bubble(text: words, meta: "Muse")
        case .closeUps(let cs, let texts):
            Bubble(text: cs.count == 1 ? "Close-up sent automatically" : "\(cs.count) close-ups sent automatically",
                   meta: cs.map { "\($0.size.0)×\($0.size.1)\($0.colour ? " colour" : " grey")\($0.high ? ", high" : "")" }.joined(separator: " + ") + " · \(texts) texts", mine: true)
        case .answer(let a):
            Bubble(text: a, meta: "answer · \(q.textsSent) texts in all", answer: true)
        case .note(let n):
            Text(n).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PhotoWithBoxes: View {
    let q: Inquiry
    var body: some View {
        let aspect = CGFloat(q.photo.width) / CGFloat(q.photo.height)
        GeometryReader { geo in
            let s = geo.size.width / CGFloat(q.photo.width)
            ZStack(alignment: .topLeading) {
                Image(decorative: q.photo.image, scale: 1).resizable().frame(width: geo.size.width, height: geo.size.width / aspect)
                ForEach(Array(q.closeUps.enumerated()), id: \.offset) { i, c in
                    Rectangle().strokeBorder(c.colour ? Color.orange : Color.accentColor, lineWidth: 2)
                        .frame(width: c.crop.width * s, height: c.crop.height * s).offset(x: c.crop.minX * s, y: c.crop.minY * s)
                    Text("\(i + 1)").font(.caption2.bold()).padding(2).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: c.crop.minX * s + 2, y: c.crop.minY * s + 2)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .cornerRadius(10)
    }
}

struct Seen: View {
    let data: Data
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            if let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                Image(decorative: img, scale: 1).resizable().interpolation(.none).scaledToFit().frame(height: 56)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
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
            if mine { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                Text(text).textSelection(.enabled)
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(mine ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(answer ? Color.green.opacity(0.7) : .clear))
            if !mine { Spacer(minLength: 32) }
        }
    }
}

// MARK: - Settings and the one-time Shortcuts setup

struct SettingsView: View {
    @EnvironmentObject var model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Send by", selection: $model.channel) { ForEach(PhoneChannel.allCases) { Text($0.rawValue).tag($0) } }
                Section {
                    TextField("MuZip number", text: $model.smsNumber).keyboardType(.phonePad)
                    TextField("Shortcut name", text: $model.shortcutName)
                    Stepper("Code parts per text: \(model.partsPerText)", value: $model.partsPerText, in: 1...10)
                } header: { Text("SMS") } footer: {
                    Text("""
                    iOS lets no app send or read texts by itself, so MuZip uses two Shortcuts you set up once:

                    1. A shortcut named "\(model.shortcutName)": Split Text (Shortcut Input, by Custom: \(PhoneModel.separator)) → Repeat with Each → Send Message (Repeat Item, to the MuZip number), with "Show When Run" off.

                    2. An automation: Automation → Message → Sender is the MuZip number → Run Immediately. Actions: URL Encode (Shortcut Input → Content) → Text "muzip://reply?text=" followed by the URL Encoded Text → Open URLs.

                    If a reply doesn't come through, copy Muse's text and tap "Paste Muse's text" in the question.
                    """)
                }
                Section {
                    TextField("Muse number", text: $model.whatsappNumber).keyboardType(.phonePad)
                } header: { Text("WhatsApp") } footer: {
                    Text("WhatsApp opens with the message filled in; tap send. Replies are read from the bridge on your Mac (the address below).")
                }
                Section {
                    TextField("Mac address", text: $model.macServer).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Your Mac") } footer: {
                    Text("The MuZip simulator on your Mac, reachable on your Wi-Fi: start it with SIM_HOST=0.0.0.0 .venv/bin/python sim/server.py and use http://<your Mac's name>.local:8765. Simulated sends straight to it, with no texts.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
