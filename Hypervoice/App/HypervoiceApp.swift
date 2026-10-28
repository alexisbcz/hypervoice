import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct HypervoiceApp: App {
    @State private var studio = Studio()

    init() {
        HubToken.apply()
        // LFM3 Audio's llama.cpp server is a separate process, which would otherwise keep running.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            LFM3.terminate()
        }
    }

    var body: some Scene {
        Window("Hypervoice", id: "main") {
            ContentView()
                .environment(studio)
                .environment(Library.shared)
                .environment(Generator.shared)
                .environment(Player.shared)
                .environment(ModelStore.shared)
                .modifier(AppAppearance())
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    Server.shared.setEnabled(UserDefaults.standard.bool(forKey: Pref.serverEnabled), port: Self.port)
                    #if DEBUG
                    Snapshot.runIfRequested(studio)
                    #endif
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Clone a Voice…") { studio.sheet = .clone(nil) }
                    .keyboardShortcut("n")
                Button("Design a Voice…") { studio.sheet = .design }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Phonon Voices…") { studio.importPhononVoices() }
                Divider()
                Button("Transcribe a File…") {
                    studio.section = .transcribe
                    studio.openForTranscription()
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Speech") {
                Button("Generate") { studio.generate() }
                    .keyboardShortcut(.return)
                    .disabled(studio.section != .speech && studio.section != .script)
                Button("Stop") {
                    Generator.shared.cancel()
                    Player.shared.stop()
                }
                .keyboardShortcut(".")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Pane.allCases) { section in
                    Button(section.title) { studio.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(section.index + 1)")))
                }
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(Library.shared)
                .environment(ModelStore.shared)
                .modifier(AppAppearance())
        }
    }

    static var port: Int {
        let saved = UserDefaults.standard.integer(forKey: Pref.serverPort)
        return saved > 0 ? saved : Server.defaultPort
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case speech, script, transcribe, voices, history, models

    var id: String { rawValue }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .speech: "Speech"
        case .script: "Script"
        case .transcribe: "Transcribe"
        case .voices: "Voices"
        case .history: "History"
        case .models: "Models"
        }
    }

    var icon: String {
        switch self {
        case .speech: "waveform"
        case .script: "text.bubble"
        case .transcribe: "captions.bubble"
        case .voices: "person.wave.2"
        case .history: "clock"
        case .models: "shippingbox"
        }
    }
}

/// The window's shared state: where you are, what you're writing, and which sheet is open.
@Observable
final class Studio {
    enum Sheet: Identifiable {
        /// Optionally starting from an audio file.
        case clone(URL?)
        case design
        case edit(Voice)

        var id: String {
            switch self {
            case .clone(let url): "clone\(url?.path ?? "")"
            case .design: "design"
            case .edit(let voice): "edit\(voice.id)"
            }
        }
    }

    var section: Pane = .speech
    var sheet: Sheet?
    var transcript: Transcript?
    var isTranscribing = false
    var transcriptionError: String?

    var draft = UserDefaults.standard.string(forKey: Pref.draft) ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: Pref.draft) }
    }
    var script = UserDefaults.standard.string(forKey: Pref.script) ?? Studio.sampleScript {
        didSet { UserDefaults.standard.set(script, forKey: Pref.script) }
    }
    var voiceID = UserDefaults.standard.string(forKey: Pref.voice) ?? Voice.presets.first { $0.preset == "af_heart" }?.id {
        didSet {
            UserDefaults.standard.set(voiceID, forKey: Pref.voice)
            // Each of your voices remembers the engine it sounds best with.
            if let voice, !voice.isPreset { engine = voice.engine }
        }
    }
    /// The engine for a cloned or designed voice, which several can speak.
    var engine = Engine(rawValue: UserDefaults.standard.string(forKey: Pref.engine) ?? "") ?? .qwen {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Pref.engine) }
    }
    var direction = UserDefaults.standard.string(forKey: Pref.direction) ?? "" {
        didSet { UserDefaults.standard.set(direction, forKey: Pref.direction) }
    }

    var voice: Voice? { Library.shared.voice(id: voiceID) }

    func generate() {
        switch section {
        case .speech:
            guard let voice, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Generator.shared.speak(draft, voice: voice, engine: engine, direction: direction)
        case .script:
            // Speakers with no voice by that name, and sounds that aren't in the list, are left out.
            let cues = Script(script, library: Library.shared, fallback: voice).cues.compactMap { cue -> Generator.Cue? in
                switch cue {
                case .speech(_, let voice, let text):
                    guard let voice else { return nil }
                    return .speech(.init(text: text, request: .make(text, voice: voice, engine: engine), voiceName: voice.name))
                case .pause(let seconds):
                    return .silence(seconds)
                case .sound(_, let sound):
                    return sound.map { .sound($0.url) }
                }
            }
            Generator.shared.run(cues, title: script)
        default:
            break
        }
    }

    /// Opens Speech with a voice selected.
    func use(_ voice: Voice) {
        voiceID = voice.id
        section = .speech
    }

    var importError: String?

    /// Adds voice files made in Gradium Studio, which Phonon reads directly.
    func importPhononVoices() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Phonon voice files (.safetensors) downloaded from Gradium Studio."
        guard panel.runModal() == .OK else { return }
        var rejected: [String] = []
        var last: Voice?
        for url in panel.urls {
            guard Self.isPhononVoice(url) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            last = try? Library.shared.addVoice(name: name, origin: .embedding, sample: url, transcript: nil, engine: .phonon)
        }
        importError = rejected.isEmpty ? nil : "Not Phonon voice files: \(rejected.joined(separator: ", "))"
        if let last { engine = .phonon; voiceID = last.id }
        section = .voices
    }

    /// A safetensors file holding one of the tensors Phonon takes as a voice.
    nonisolated static func isPhononVoice(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let size = try? handle.read(upToCount: 8), size.count == 8 else { return false }
        defer { try? handle.close() }
        let length = size.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        guard length < 1 << 20, let header = try? handle.read(upToCount: Int(length)),
              let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any]
        else { return false }
        return ["speaker_wavs", "emb", "audio_prompt"].contains { json[$0] != nil }
    }

    func openForTranscription() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribe(url)
    }

    func transcribe(_ url: URL) {
        section = .transcribe
        isTranscribing = true
        transcriptionError = nil
        transcript = nil
        let language = UserDefaults.standard.string(forKey: Pref.transcriptionLanguage).flatMap { $0.isEmpty ? nil : $0 }
        Task {
            do {
                transcript = try await ModelStore.shared.track(.whisper) {
                    try await Transcriber.shared.transcribe(url, language: language)
                }
            } catch {
                transcriptionError = error.localizedDescription
            }
            isTranscribing = false
        }
    }

    static let sampleScript = """
    [sound Hero]
    @Heart Welcome back to the show. Today we're talking about voices that never leave your Mac.
    @George Which, honestly, is the only way I'd want it.
    [pause 1s]
    @Heart Every word you hear was generated on-device, sentence by sentence.
    @George No cloud, no account, no meter running. Let's get into it.
    """
}
