import SwiftUI

/// Text to speech: write, pick a voice, generate.
struct SpeechView: View {
    @Environment(Studio.self) private var studio
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var models
    @Environment(Player.self) private var player
    @Environment(\.textSize) private var textSize
    /// The editor's own copy of the draft. It's kept rather than rebuilt from the draft each time, which would
    /// put the cursor back at the end with every keystroke; playback only changes its highlight.
    @State private var text = AttributedString()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: textSize))
                    .lineSpacing(textSize * 0.3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                if studio.draft.isEmpty {
                    Text(placeholder)
                        .font(.system(size: textSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 29)
                        .padding(.top, 20)
                        .allowsHitTesting(false)
                }
            }
            GenerationStatus()
            Divider()
            SpeechControls(showsDirection: true)
        }
        .navigationTitle("Speech")
        .navigationSubtitle(studio.voice?.name ?? "")
        .onChange(of: text) {
            let typed = String(text.characters)
            if typed != studio.draft { studio.draft = typed }
        }
        .onChange(of: studio.draft, initial: true) {
            if String(text.characters) != studio.draft { text = AttributedString(studio.draft) }
        }
        .onChange(of: spokenWord) { highlight(spokenWord) }
    }

    /// Where the word being said is in the draft, in characters, while the speech made from it plays.
    private var spokenWord: Range<Int>? {
        let isPlaying = player.isPlaying(Player.live) || generator.lastClip.map { player.isPlaying($0.id.uuidString) } == true
        guard isPlaying, generator.spokenText == studio.draft else { return nil }
        let time = player.position
        guard let word = generator.timeline.lazy.flatMap(\.words).last(where: { $0.start <= time && $0.characters != nil }),
              time < word.end
        else { return nil }
        return word.characters
    }

    private func highlight(_ word: Range<Int>?) {
        text.foregroundColor = nil
        text.backgroundColor = nil
        guard let word, word.upperBound <= text.characters.count else { return }
        let start = text.characters.index(text.startIndex, offsetBy: word.lowerBound)
        let end = text.characters.index(start, offsetBy: word.count)
        text[start..<end].foregroundColor = .accentColor
        text[start..<end].backgroundColor = Color.accentColor.opacity(0.15)
    }

    private var placeholder: String {
        studio.voice.map { voice in
            let engine = SpeechRequest.make("", voice: voice, engine: studio.engine).engine
            return engine == .chatterbox
                ? "Type something to say. Add [laugh], [sigh] or [whispering] where you want them."
                : "Type something to say, as long as you like."
        } ?? "Pick a voice below, then type something to say."
    }
}

/// The bar under the editor in Speech and Script: voice, engine, direction, Generate.
struct SpeechControls: View {
    @Environment(Studio.self) private var studio
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var models
    var showsDirection = false

    var body: some View {
        @Bindable var studio = studio
        let voice = studio.voice
        let engine = voice.map { SpeechRequest.make("", voice: $0, engine: studio.engine).engine }
        HStack(spacing: 12) {
            if let voice { VoiceAvatar(voice: voice, size: 22) }
            VoicePicker(selection: $studio.voiceID)
                .labelsHidden()
                .fixedSize()
            if let voice, !voice.isPreset {
                Picker("Engine", selection: $studio.engine) {
                    ForEach(voice.engines) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("The model that speaks in this voice")
            }
            if showsDirection, engine?.takesDirection == true {
                TextField("Direction, like \u{201C}excited\u{201D} or \u{201C}whispering\u{201D}", text: $studio.direction)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            Spacer()
            if let engine, !models.isInstalled(engine), !generator.isGenerating {
                Text("Downloads \(engine.downloadSize.bytes) first")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if generator.isGenerating {
                Button("Stop", systemImage: "stop.fill") { generator.cancel() }
            } else {
                Button("Generate", systemImage: "waveform") { studio.generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(voice == nil || (studio.section == .speech ? studio.draft : studio.script).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Generate (⌘↩)")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Progress while speech generates, then the clip it made.
struct GenerationStatus: View {
    @Environment(Generator.self) private var generator
    @Environment(Player.self) private var player

    var body: some View {
        if generator.isGenerating || generator.lastClip != nil || generator.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let error = generator.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if generator.isGenerating {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(generator.status).foregroundStyle(.secondary)
                        Spacer()
                        if generator.progress > 0 {
                            Text(generator.progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if !generator.peaks.isEmpty {
                        Waveform(peaks: generator.peaks)
                            .frame(height: 36)
                    }
                } else if let clip = generator.lastClip {
                    ClipRow(clip: clip)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .animation(.default, value: generator.isGenerating)
        }
    }
}

/// A finished clip: play, its length, and what made it.
struct ClipRow: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    let clip: Clip

    var body: some View {
        VStack(spacing: 10) {
            row
            if isPlaying, player.duration > 0 {
                ProgressView(value: min(player.position / clip.duration, 1))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        .draggable(library.url(of: clip))
    }

    private var row: some View {
        HStack(spacing: 12) {
            Button {
                player.toggle(clip)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(clip.voiceName) · \(isPlaying ? "\(player.position.clock) / " : "")\(clip.duration.clock)")
                    .monospacedDigit()
                if let time = clip.generationTime, clip.duration > 0 {
                    Text("Made in \(time.formatted(.number.precision(.fractionLength(1)))) s, \((clip.duration / time).formatted(.number.precision(.fractionLength(1))))× real time\(clip.engine.map { " with \($0.name)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ShareLink(item: library.url(of: clip)) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .help("Share")
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.url(of: clip)])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private var isPlaying: Bool { player.isPlaying(clip.id.uuidString) }
}
