import SwiftUI
import UniformTypeIdentifiers

/// Several voices in one recording: a podcast, a dialogue, an audiobook chapter with characters,
/// with pauses and sound effects between the lines.
struct ScriptView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(\.textSize) private var textSize
    @State private var showsPanel = true
    @State private var editor = ScriptEditorProxy()
    /// Bumped when sounds are added or removed, which the file system doesn't announce.
    @State private var soundsVersion = 0

    var body: some View {
        @Bindable var studio = studio
        let script = Script(studio.script, library: library, fallback: studio.voice)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScriptEditor(text: $studio.script, proxy: editor, fontSize: textSize - 2,
                             signature: "\(library.voices.map(\.name))|\(soundsVersion)")
                    .frame(minWidth: 0, maxWidth: .infinity)
                if showsPanel {
                    Divider()
                    ScriptPanel(script: script, editor: editor, soundsVersion: $soundsVersion)
                        .frame(width: 260)
                }
            }
            GenerationStatus()
            Divider()
            SpeechControls()
        }
        .toolbar {
            Menu("Insert", systemImage: "plus") {
                InsertMenu(editor: editor)
            }
            .help("Insert a pause or a sound")
            Toggle("Speakers", systemImage: "sidebar.trailing", isOn: $showsPanel)
                .help("Show or hide the speakers and sounds")
        }
        .navigationTitle("Script")
        .navigationSubtitle(subtitle(script))
    }

    private func subtitle(_ script: Script) -> String {
        let speakers = script.speakers
        let lines = speakers.reduce(0) { $0 + $1.lines }
        var parts = ["\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")", "\(lines) line\(lines == 1 ? "" : "s")"]
        let sounds = script.cues.filter { if case .sound = $0 { true } else { false } }.count
        if sounds > 0 { parts.append("\(sounds) sound\(sounds == 1 ? "" : "s")") }
        if script.duration > 0 { parts.append("\(script.duration.formatted(.number.precision(.fractionLength(0...1)))) s of pauses") }
        return parts.joined(separator: " · ")
    }
}

private struct InsertMenu: View {
    let editor: ScriptEditorProxy

    var body: some View {
        SwiftUI.Section("Pause") {
            ForEach(["0.5s", "1s", "2s", "5s"], id: \.self) { length in
                Button("Pause \(length)") { editor.insert("[pause \(length)]") }
            }
        }
        SwiftUI.Section("Sound") {
            ForEach(Sounds.all) { sound in
                Button(sound.name) { editor.insert("[sound \(sound.name)]") }
            }
        }
    }
}

private struct ScriptPanel: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let script: Script
    let editor: ScriptEditorProxy
    @Binding var soundsVersion: Int

    var body: some View {
        let _ = soundsVersion
        List {
            SwiftUI.Section {
                ForEach(script.speakers) { speaker in
                    SpeakerRow(speaker: speaker, editor: editor)
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Type @ at the start of a line to pick a speaker; lines without one continue with the last. Click a name in the script to change its voice.")
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                HStack(spacing: 6) {
                    ForEach(["0.5s", "1s", "2s"], id: \.self) { length in
                        Button(length) { editor.insert("[pause \(length)]") }
                            .controlSize(.small)
                    }
                    Spacer()
                }
            } header: {
                Text("Pauses")
            }

            SwiftUI.Section {
                ForEach(Sounds.all) { sound in
                    SoundRow(sound: sound, editor: editor) {
                        Sounds.delete(sound)
                        soundsVersion += 1
                    }
                }
                Button("Add Sounds…", systemImage: "plus") { addSounds() }
                    .buttonStyle(.borderless)
            } header: {
                Text("Sounds")
            } footer: {
                Text("Click a sound to put it at the cursor, or type [sound and pick one. Drop audio files here to add your own.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true }
            guard !audio.isEmpty else { return false }
            Sounds.add(audio)
            soundsVersion += 1
            return true
        }
    }

    private func addSounds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Sounds.add(panel.urls)
        soundsVersion += 1
    }
}

private struct SpeakerRow: View {
    let speaker: Script.Speaker
    let editor: ScriptEditorProxy

    var body: some View {
        HStack(spacing: 10) {
            if let voice = speaker.voice {
                VoiceAvatar(voice: voice, size: 26)
            } else {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(speaker.name.isEmpty ? "Narrator" : speaker.name)
                    .foregroundStyle(speaker.voice.map { Color(nsColor: ScriptTextView.color(for: $0.name)) } ?? .orange)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                VoiceChoices(current: speaker.voice) { editor.recast(speaker.name, to: $0) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(speaker.voice == nil ? "Choose a voice for \(speaker.name)" : "Change \(speaker.name)'s voice everywhere")
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let lines = "\(speaker.lines) line\(speaker.lines == 1 ? "" : "s")"
        guard let voice = speaker.voice else { return "No voice by this name — skipped" }
        return voice.isPreset ? "\(voice.engine.name) · \(lines)" : "\(voice.subtitle) · \(lines)"
    }
}

/// Every voice as menu buttons: yours, then each engine's built-in ones in a submenu.
struct VoiceChoices: View {
    @Environment(Library.self) private var library
    let current: Voice?
    let choose: (Voice) -> Void

    var body: some View {
        if !library.voices.isEmpty {
            SwiftUI.Section("My Voices") {
                ForEach(library.voices) { button($0) }
            }
        }
        ForEach(Engine.allCases.filter { !$0.presets.isEmpty }) { engine in
            Menu(engine.name) {
                ForEach(engine.presets, id: \.self) { preset in
                    button(.preset(preset, of: engine), title: "\(preset.name) — \(preset.language)")
                }
            }
        }
    }

    private func button(_ voice: Voice, title: String? = nil) -> some View {
        Toggle(title ?? voice.name, isOn: Binding(get: { current?.id == voice.id }, set: { _ in choose(voice) }))
    }
}

private struct SoundRow: View {
    @Environment(Player.self) private var player
    let sound: Sound
    let editor: ScriptEditorProxy
    let delete: () -> Void

    var body: some View {
        let id = "sound:\(sound.url.path)"
        HStack(spacing: 8) {
            Button {
                player.isPlaying(id) ? player.stop() : player.play(sound.url, id: id)
            } label: {
                Image(systemName: player.isPlaying(id) ? "stop.circle.fill" : "play.circle")
                    .foregroundStyle(.teal)
            }
            .buttonStyle(.borderless)
            .help("Hear it")
            Button {
                editor.insert("[sound \(sound.name)]")
            } label: {
                Text(sound.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Insert [sound \(sound.name)] at the cursor")
        }
        .contextMenu {
            Button("Insert") { editor.insert("[sound \(sound.name)]") }
            if !sound.isBuiltIn {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sound.url]) }
                Divider()
                Button("Delete", role: .destructive, action: delete)
            }
        }
    }
}
