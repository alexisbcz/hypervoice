import AppKit
import SwiftUI

@main
struct HypervoiceApp: App {
    @State private var studio = Studio()

    var body: some Scene {
        Window("Hypervoice", id: "main") {
            ContentView()
                .environment(studio)
                .environment(Library.shared)
                .environment(Generator.shared)
                .environment(Player.shared)
                .environment(ModelStore.shared)
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
            let parsed = Script(script, library: Library.shared, fallback: voice)
            let lines = parsed.parts.compactMap { part -> Generator.Line? in
                guard let voice = part.voice else { return nil }
                return Generator.Line(text: part.text, request: .make(part.text, voice: voice, engine: engine), voiceName: voice.name)
            }
            Generator.shared.run(lines, title: script)
        default:
            break
        }
    }

    /// Opens Speech with a voice selected.
    func use(_ voice: Voice) {
        voiceID = voice.id
        section = .speech
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
    Heart: Welcome back to the show. Today we're talking about voices that never leave your Mac.
    George: Which, honestly, is the only way I'd want it.
    Heart: Every word you hear was generated on-device, sentence by sentence.
    George: No cloud, no account, no meter running. Let's get into it.
    """
}
