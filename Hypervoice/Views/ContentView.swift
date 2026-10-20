import SwiftUI

struct ContentView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var studio = studio
        NavigationSplitView {
            List(selection: $studio.section) {
                SwiftUI.Section("Create") {
                    ForEach([Pane.speech, .script, .transcribe]) { row($0) }
                }
                SwiftUI.Section("Library") {
                    ForEach([Pane.voices, .history]) { row($0) }
                }
                SwiftUI.Section("Setup") {
                    row(.models)
                }
            }
            .modifier(SidebarDarkening())
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch studio.section {
                case .speech: SpeechView()
                case .script: ScriptView()
                case .transcribe: TranscribeView()
                case .voices: VoicesView()
                case .history: HistoryView()
                case .models: ModelsView()
                }
            }
            .modifier(PageBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { NowPlayingBar() }
        }
        #if DEBUG
        // HYPERVOICE_OPEN_SETTINGS=1 opens Settings at launch, for checking it by eye.
        .task {
            if ProcessInfo.processInfo.environment["HYPERVOICE_OPEN_SETTINGS"] != nil { openSettings() }
        }
        #endif
        .sheet(item: $studio.sheet) { sheet in
            switch sheet {
            case .clone(let url): CloneSheet(source: url)
            case .design: DesignSheet()
            case .edit(let voice): EditVoiceSheet(voice: voice)
            }
        }
    }

    private func row(_ pane: Pane) -> some View {
        Label(pane.title, systemImage: pane.icon)
            .badge(pane == .voices ? library.voices.count : pane == .history ? library.clips.count : 0)
            .tag(pane)
    }
}

/// Playback of a saved clip, across the bottom of every pane.
struct NowPlayingBar: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    var body: some View {
        if let id = player.playing, id != Player.live, let clip = library.clips.first(where: { $0.id.uuidString == id }) {
            HStack(spacing: 12) {
                Button { player.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.text).lineLimit(1)
                    Text(clip.voiceName).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260, alignment: .leading)
                Text(player.position.clock).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(get: { player.duration > 0 ? player.position / player.duration : 0 },
                                      set: { player.seek(to: $0) }))
                    .controlSize(.small)
                Text(player.duration.clock).monospacedDigit().foregroundStyle(.secondary)
                RateMenu()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct RateMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        Picker("Speed", selection: $player.rate) {
            ForEach([0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { rate in
                Text(rate == 1 ? "1×" : "\(rate.formatted())×").tag(rate)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help("Playback speed")
    }
}

/// A round badge with the voice's initial, tinted by its name so each voice keeps its color.
struct VoiceAvatar: View {
    let voice: Voice
    var size: CGFloat = 32

    var body: some View {
        Circle()
            .fill(Self.color(for: voice.name).gradient)
            .overlay {
                if voice.isPreset {
                    Text(voice.name.prefix(1).uppercased())
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: voice.origin == .designed ? "sparkles" : voice.origin == .embedding ? "person.wave.2" : "waveform")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
    }

    static func color(for name: String) -> Color {
        Color(hue: hue(for: name), saturation: 0.5, brightness: 0.78)
    }

    /// Stable per name, so a voice keeps its color everywhere, the script editor included.
    static func hue(for name: String) -> Double {
        let hash = name.unicodeScalars.reduce(UInt32(5381)) { ($0 << 5) &+ $0 &+ $1.value }
        return Double(hash % 360) / 360
    }
}

/// Bars drawn from peaks, filled up to `progress`.
struct Waveform: View {
    let peaks: [Float]
    var progress: Double = 1
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let bar: CGFloat = 2
            let gap: CGFloat = 2
            let count = max(1, Int(size.width / (bar + gap)))
            let values = Self.resample(peaks, to: count)
            for (index, value) in values.enumerated() {
                let height = max(2, CGFloat(value) * size.height)
                let x = CGFloat(index) * (bar + gap)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                let played = Double(index) / Double(values.count) < progress
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? color : color.opacity(0.25)))
            }
        }
    }

    private static func resample(_ peaks: [Float], to count: Int) -> [Float] {
        guard peaks.count > count else { return peaks }
        let stride = Double(peaks.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * stride)
            let end = max(start + 1, Int(Double(index + 1) * stride))
            return peaks[start..<min(end, peaks.count)].max() ?? 0
        }
    }
}

/// Every voice in a menu: yours, then each engine's built-in ones.
struct VoicePicker: View {
    @Environment(Library.self) private var library
    @Binding var selection: String?

    var body: some View {
        Picker("Voice", selection: $selection) {
            if !library.voices.isEmpty {
                SwiftUI.Section("My Voices") {
                    ForEach(library.voices) { voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
            }
            ForEach(Self.groups, id: \.title) { group in
                SwiftUI.Section(group.title) {
                    ForEach(group.presets, id: \.self) { preset in
                        let voice = Voice.preset(preset, of: group.engine)
                        Text(group.byLanguage ? voice.name : "\(voice.name) — \(preset.language)").tag(Optional(voice.id))
                    }
                }
            }
        }
    }
}

extension VoicePicker {
    struct Group {
        var title: String
        var engine: Engine
        var presets: [Preset]
        var byLanguage: Bool
    }

    /// One section per engine; a long catalog gets one per language instead, so it can be scanned.
    static let groups: [Group] = Engine.allCases.flatMap { engine -> [Group] in
        let presets = engine.presets
        guard presets.count > 20 else { return presets.isEmpty ? [] : [Group(title: engine.name, engine: engine, presets: presets, byLanguage: false)] }
        let languages = Array(NSOrderedSet(array: presets.map(\.language))) as? [String] ?? []
        return languages.map { language in
            Group(title: "\(engine.name) · \(language)", engine: engine, presets: presets.filter { $0.language == language }, byLanguage: true)
        }
    }
}

/// What a pane shows before there's anything in it.
struct EmptyState<Actions: View>: View {
    let title: String
    let icon: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        } actions: {
            actions
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
