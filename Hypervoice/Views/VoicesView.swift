import SwiftUI

/// Your cloned and designed voices, and every engine's built-in ones.
struct VoicesView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(ModelStore.self) private var models
    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                group("My Voices", subtitle: "Cloned from a recording, designed from a description, or made in Gradium Studio.") {
                    if let error = studio.importError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filter(library.voices)) { VoiceCard(voice: $0) }
                        if search.isEmpty {
                            NewVoiceCard(title: "Clone a Voice", subtitle: "From a few seconds of audio", icon: "waveform.badge.plus") { studio.sheet = .clone(nil) }
                            NewVoiceCard(title: "Design a Voice", subtitle: "From a written description", icon: "sparkles") { studio.sheet = .design }
                            NewVoiceCard(title: "Import a Phonon Voice", subtitle: "A voice file from Gradium Studio", icon: "square.and.arrow.down") { studio.importPhononVoices() }
                        }
                    }
                }
                ForEach(Engine.allCases.filter { !$0.presets.isEmpty }) { engine in
                    let voices = filter(engine.presets.map { Voice.preset($0, of: engine) })
                    if !voices.isEmpty {
                        group(engine.name, subtitle: subtitle(engine)) {
                            PresetGrid(voices: voices, columns: columns)
                        }
                    }
                }
            }
            .padding(20)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search voices")
        .navigationTitle("Voices")
        .toolbar {
            Menu("New Voice", systemImage: "plus") {
                Button("Clone a Voice…", systemImage: "waveform.badge.plus") { studio.sheet = .clone(nil) }
                Button("Design a Voice…", systemImage: "sparkles") { studio.sheet = .design }
                Divider()
                Button("Import Phonon Voices…", systemImage: "square.and.arrow.down") { studio.importPhononVoices() }
                Link("Make One in Gradium Studio", destination: URL(string: "https://gradium.ai")!)
            }
        }
    }

    private func subtitle(_ engine: Engine) -> String {
        var parts = [engine.summary]
        if !models.isInstalled(engine) { parts.append("Downloads \(engine.downloadSize.bytes) on first use.") }
        if engine.isGated, !HubToken.isSet { parts.append("Needs a Hugging Face token in Settings.") }
        if let note = engine.licenseNote { parts.append(note) }
        return parts.joined(separator: " ")
    }

    private func filter(_ voices: [Voice]) -> [Voice] {
        guard !search.isEmpty else { return voices }
        return voices.filter { "\($0.name) \($0.subtitle) \($0.language ?? "") \($0.prompt ?? "")".localizedStandardContains(search) }
    }

    private func group(_ title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            content()
        }
    }
}

/// An engine's built-in voices; a long catalog reads better split by language.
private struct PresetGrid: View {
    let voices: [Voice]
    let columns: [GridItem]

    var body: some View {
        let languages = Array(NSOrderedSet(array: voices.compactMap(\.language))) as? [String] ?? []
        if voices.count > 20, languages.count > 1 {
            ForEach(languages, id: \.self) { language in
                Text(language)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                grid(voices.filter { $0.language == language })
            }
        } else {
            grid(voices)
        }
    }

    private func grid(_ voices: [Voice]) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(voices) { VoiceCard(voice: $0) }
        }
    }
}

private struct VoiceCard: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Generator.self) private var generator
    @State private var isHovering = false
    let voice: Voice

    var body: some View {
        HStack(spacing: 12) {
            VoiceAvatar(voice: voice, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name).font(.headline).lineLimit(1)
                Text(voice.isPreset ? [voice.language, voice.prompt].compactMap(\.self).joined(separator: " — ") : voice.prompt ?? voice.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                preview()
            } label: {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isHovering || isPreviewing ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(voice.isPreset ? "Hear this voice" : "Play the sample")
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(studio.voiceID == voice.id ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: studio.voiceID == voice.id ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: 12))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { studio.use(voice) }
        .onTapGesture { studio.voiceID = voice.id }
        .contextMenu {
            Button("Use in Speech") { studio.use(voice) }
            if !voice.isPreset {
                Button("Edit…") { studio.sheet = .edit(voice) }
                if let url = library.sampleURL(of: voice) {
                    Button(voice.origin == .embedding ? "Show Voice File in Finder" : "Show Sample in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
                Button("Delete", role: .destructive) { library.delete(voice) }
            }
        }
    }

    private var isPreviewing: Bool {
        player.isPlaying("voice:\(voice.id)") || (previewing && (generator.isGenerating || player.isPlaying(Player.live)))
    }

    @State private var previewing = false

    private func preview() {
        if isPreviewing {
            player.stop()
            generator.cancel()
            previewing = false
            return
        }
        if voice.hasSample, let url = library.sampleURL(of: voice) {
            player.play(url, id: "voice:\(voice.id)")
        } else {
            let text = Self.previewText(for: voice.language)
            previewing = true
            generator.run([.init(text: text, request: .make(text, voice: voice), voiceName: voice.name)], title: text, save: false)
        }
    }

    static func previewText(for language: String?) -> String {
        switch language {
        case "French": "Bonjour ! Voici à quoi ressemble ma voix."
        case "Spanish": "¡Hola! Así es como suena mi voz."
        case "Italian": "Ciao! Ecco come suona la mia voce."
        case "Portuguese": "Olá! É assim que a minha voz soa."
        case "Japanese": "こんにちは。これが私の声です。"
        case "Chinese": "你好！这就是我的声音。"
        case "Korean": "안녕하세요. 이것이 제 목소리예요."
        case "Hindi": "नमस्ते! मेरी आवाज़ ऐसी सुनाई देती है।"
        default: "Hi there! This is what my voice sounds like."
        }
    }
}

private struct NewVoiceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(.rect)
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
