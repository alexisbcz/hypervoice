import SwiftUI
import UniformTypeIdentifiers

/// Speech to text for any audio or video file, with timestamps, subtitles, and a shortcut to cloning the speaker.
struct TranscribeView: View {
    @Environment(Studio.self) private var studio
    @Environment(Player.self) private var player
    @Environment(ModelStore.self) private var models
    @State private var isTargeted = false

    var body: some View {
        Group {
            if studio.isTranscribing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(models.isInstalled(.whisper) ? "Transcribing…" : "Downloading \(Whisper.name) (\(Whisper.downloadSize.bytes))…")
                        .foregroundStyle(.secondary)
                    if let progress = models.progress(.whisper) {
                        ProgressView(value: progress).frame(width: 220)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let transcript = studio.transcript {
                TranscriptView(transcript: transcript)
            } else {
                EmptyState(title: "Transcribe", icon: "captions.bubble",
                           message: studio.transcriptionError ?? "Drop an audio or video file here to turn speech into text, on your Mac.") {
                    Button("Choose File…") { studio.openForTranscription() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            studio.transcribe(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle("Transcribe")
        .navigationSubtitle(studio.transcript?.source.lastPathComponent ?? "")
        .toolbar {
            if let transcript = studio.transcript {
                ToolbarItemGroup {
                    Button("Clone This Voice", systemImage: "person.badge.plus") { studio.sheet = .clone(transcript.source) }
                        .help("Make a voice from this recording")
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript.text, forType: .string)
                    }
                    Menu("Export", systemImage: "square.and.arrow.up") {
                        Button("Text…") { export(transcript.text, as: "txt", from: transcript) }
                        Button("Subtitles (SRT)…") { export(transcript.srt, as: "srt", from: transcript) }
                    }
                    Button("New", systemImage: "plus") { studio.openForTranscription() }
                }
            }
        }
    }

    private func export(_ text: String, as fileExtension: String, from transcript: Transcript) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = transcript.source.deletingPathExtension().lastPathComponent + "." + fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct TranscriptView: View {
    @Environment(Player.self) private var player
    @Environment(\.textSize) private var textSize
    let transcript: Transcript

    var body: some View {
        let id = "transcript:\(transcript.id)"
        List {
            if transcript.segments.isEmpty {
                Text(transcript.text).textSelection(.enabled)
            }
            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                let isCurrent = player.isPlaying(id) && player.position >= segment.start && player.position < segment.end
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Button(segment.start.clock) {
                        if !player.isPlaying(id) { player.play(transcript.source, id: id) }
                        player.seek(to: segment.start / max(player.duration, 1))
                    }
                    .buttonStyle(.link)
                    .monospacedDigit()
                    .help("Play from here")
                    Text(segment.text)
                        .font(.system(size: textSize - 2))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                }
                .padding(.vertical, 3)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(player.isPlaying(id) ? "Pause" : "Play", systemImage: player.isPlaying(id) ? "pause.fill" : "play.fill") {
                    player.isPlaying(id) ? player.stop() : player.play(transcript.source, id: id)
                }
                if player.isPlaying(id) {
                    Text("\(player.position.clock) / \(player.duration.clock)").monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(transcript.text.split(whereSeparator: \.isWhitespace).count) words\(transcript.language.map { " · \(Locale.current.localizedString(forLanguageCode: $0) ?? $0)" } ?? "")")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.bar)
        }
    }
}
