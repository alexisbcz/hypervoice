import SwiftUI

/// Several voices in one recording: a podcast, a dialogue, an audiobook chapter with characters.
struct ScriptView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @State private var showsSpeakers = true
    @Environment(\.textSize) private var textSize

    var body: some View {
        @Bindable var studio = studio
        let script = Script(studio.script, library: library, fallback: studio.voice)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TextEditor(text: $studio.script)
                    .font(.system(size: textSize - 2))
                    .lineSpacing(textSize * 0.35)
                    .scrollContentBackground(.hidden)
                    .padding(20)
                    .frame(minWidth: 0, maxWidth: .infinity)
                if showsSpeakers {
                    Divider()
                    SpeakerList(script: script)
                        .frame(width: 250)
                }
            }
            GenerationStatus()
            Divider()
            SpeechControls()
        }
        .toolbar {
            Toggle("Speakers", systemImage: "sidebar.trailing", isOn: $showsSpeakers)
                .help("Show or hide the speakers")
        }
        .navigationTitle("Script")
        .navigationSubtitle("\(script.speakers.count) speakers · \(script.parts.count) lines")
    }
}

private struct SpeakerList: View {
    @Environment(Library.self) private var library
    let script: Script

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(script.speakers, id: \.name) { speaker in
                    HStack(spacing: 10) {
                        if let voice = speaker.voice {
                            VoiceAvatar(voice: voice, size: 24)
                        } else {
                            Image(systemName: "questionmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(speaker.name.isEmpty ? "Narrator" : speaker.name)
                            Text(speaker.voice?.subtitle ?? "No voice by this name — skipped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Start a line with a voice's name and a colon, like \u{201C}Heart: Hello!\u{201D} Lines without a name continue with the last speaker; the first ones use the voice picked below.")
                    .foregroundStyle(.secondary)
            }
            if !library.voices.isEmpty {
                SwiftUI.Section("My Voices") {
                    ForEach(library.voices) { voice in
                        Label { Text(voice.name) } icon: { VoiceAvatar(voice: voice, size: 18) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}
