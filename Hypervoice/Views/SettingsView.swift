import SwiftUI

/// The Settings window (⌘,): native tabs and grouped forms, like System Settings.
struct SettingsView: View {
    /// Reopens on the tab you used last.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { AppearanceSettings() }
            Tab("API", systemImage: "network", value: "api") { APISettings() }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(Library.self) private var library
    @Environment(ModelStore.self) private var models
    @AppStorage(Pref.transcriptionLanguage) private var language = ""

    var body: some View {
        Form {
            Picker("Transcription language", selection: $language) {
                Text("Detect automatically").tag("")
                Divider()
                ForEach(Self.languages, id: \.self) { code in
                    Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                }
            }
            LabeledContent("Library") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(library.voices.count) voices, \(library.clips.count) clips").foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.open(Library.folder) }
                }
            }
            LabeledContent("Models") {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(models.totalSize > 0 ? models.totalSize.bytes : "None downloaded").foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(ModelStore.folder(of: .whisper).deletingLastPathComponent())
                    }
                }
            }
            HubTokenSection()
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    static let languages = ["en", "fr", "es", "de", "it", "pt", "nl", "ja", "zh", "ko", "ru", "ar", "hi", "pl", "tr", "sv", "uk"]
}

/// The Hugging Face token some models need before they'll download.
private struct HubTokenSection: View {
    @State private var token = HubToken.value ?? ""
    @State private var isSaved = HubToken.isSet

    var body: some View {
        SwiftUI.Section {
            SecureField("Access token", text: $token, prompt: Text("hf_…"))
                .onSubmit(save)
            HStack {
                Link("Create a token", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                Spacer()
                if isSaved, token == HubToken.value {
                    Label("Saved in the Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(token.isEmpty && isSaved ? "Remove" : "Save", action: save)
                    .disabled(token == (HubToken.value ?? ""))
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Phonon Multilingual only downloads once you accept its terms on Hugging Face. A read-only token from that account is enough.")
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        HubToken.save(token)
        isSaved = HubToken.isSet
        ModelStore.shared.refresh()
    }
}

private struct APISettings: View {
    @AppStorage(Pref.serverEnabled) private var enabled = false
    @AppStorage(Pref.serverPort) private var port = Server.defaultPort
    @State private var server = Server.shared

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Local API", isOn: $enabled)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(!enabled)
                LabeledContent("Status") {
                    if let error = server.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Label(server.isRunning ? "Listening on 127.0.0.1:\(String(server.port))" : "Off",
                              systemImage: server.isRunning ? "circle.fill" : "circle")
                            .foregroundStyle(server.isRunning ? .green : .secondary)
                    }
                }
            } footer: {
                Text("Compatible with OpenAI's speech endpoint, so existing apps, scripts and agents can speak in your voices. Only this Mac can reach it.")
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section("Try it") {
                Text("""
                curl localhost:\(String(port))/v1/audio/speech \\
                  -d '{"input": "Hello from Hypervoice", "voice": "Heart"}' \\
                  -o hello.wav
                """)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                Text("GET /v1/voices lists every voice. Add \"model\" to pick an engine and \"instructions\" to direct a CustomVoice preset. POST /v1/audio/transcriptions with model=lfm3 transcribes with LFM3 Audio instead of Whisper.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: enabled) { server.setEnabled(enabled, port: port) }
        .onSubmit { server.setEnabled(enabled, port: port) }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Pref.theme) private var theme = Theme.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.system
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @AppStorage(Pref.darkSidebar) private var darkSidebar = false
    @AppStorage(Pref.textSize) private var textSize = Pref.defaultTextSize

    var body: some View {
        Form {
            SwiftUI.Section {
                SpeechPreview()
                    .listRowInsets(EdgeInsets())
            }

            SwiftUI.Section("Theme") {
                HStack(spacing: 0) {
                    ForEach(Theme.allCases) { option in
                        ThemeOption(theme: option, isSelected: theme == option) {
                            withAnimation(.snappy) { theme = option }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)

                LabeledContent("Dark mode darkness") {
                    HStack(spacing: 10) {
                        Text("Gray").foregroundStyle(.secondary)
                        Slider(value: $darkness, in: 0...1)
                            .frame(width: 180)
                        Text("Black").foregroundStyle(.secondary)
                    }
                }
                Toggle("Darken the sidebar too", isOn: $darkSidebar)

                LabeledContent("Accent color") {
                    HStack(spacing: 9) {
                        ForEach(AccentChoice.allCases) { option in
                            AccentSwatch(choice: option, isSelected: accent == option) {
                                withAnimation(.snappy) { accent = option }
                            }
                        }
                    }
                }
            }

            SwiftUI.Section("Text") {
                LabeledContent("Text size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $textSize, in: 13...24, step: 1)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                        Text("\(Int(textSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            SwiftUI.Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        withAnimation(.snappy) { Pref.resetAppearance() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
    }
}

/// A slice of the Speech pane, drawn with the real waveform, so every setting shows as it will look.
private struct SpeechPreview: View {
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @Environment(\.textSize) private var textSize

    private static let voice = Voice.presets.first { $0.preset == "af_heart" } ?? Voice.presets[0]
    private static let peaks: [Float] = (0..<160).map { index in
        let x = Double(index)
        return Float(0.18 + 0.5 * abs(sin(x * 0.21) * cos(x * 0.047)) + 0.25 * abs(sin(x * 0.9)) * 0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The light on the rooftops was the first thing I noticed this morning.")
                .font(.system(size: textSize))
                .lineSpacing(textSize * 0.3)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Self.voice.name) · 0:05").font(.callout)
                    Waveform(peaks: Self.peaks, progress: 0.4)
                        .frame(height: 22)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190, alignment: .topLeading)
        .background(Color.page(darkness: darkness))
        .allowsHitTesting(false)
        .accessibilityLabel("Preview")
    }
}

/// A miniature window in light, dark, or half of each, like System Settings' appearance picker.
private struct ThemeOption: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                thumbnail
                    .frame(width: 112, height: 72)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, lineWidth: 3)
                            .opacity(isSelected ? 1 : 0)
                    }
                Text(theme.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            MiniWindow(dark: false)
                .overlay(alignment: .trailing) {
                    MiniWindow(dark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: 56) }
                }
        }
    }
}

/// Sidebar, a few lines of text, a waveform and the Generate bar, in a few rounded strokes.
private struct MiniWindow: View {
    let dark: Bool
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @AppStorage(Pref.darkSidebar) private var darkSidebar = false

    var body: some View {
        let background = dark ? Color(white: Color.pageWhite(darkness: darkness)) : Color(white: 0.98)
        let sidebar = dark ? Color(white: darkSidebar ? Color.sidebarWhite(darkness: darkness) : 0.2) : Color(white: 0.9)
        let ink = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 4)
                Capsule().fill(.tint).frame(width: 22, height: 4)
                Capsule().fill(ink).frame(width: 18, height: 3)
                Capsule().fill(ink).frame(width: 20, height: 3)
                Spacer()
            }
            .padding(6)
            .frame(width: 34, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink).frame(width: 56, height: 3)
                Capsule().fill(ink).frame(width: 44, height: 3)
                HStack(spacing: 1.5) {
                    ForEach([3, 6, 9, 5, 8, 4, 7, 3], id: \.self) { height in
                        Capsule().fill(.tint.opacity(0.85)).frame(width: 2, height: CGFloat(height))
                    }
                }
                .frame(height: 10)
                Spacer()
                HStack {
                    Spacer()
                    Capsule().fill(.tint).frame(width: 18, height: 7)
                }
            }
            .padding(7)
        }
        .background(background)
    }
}

/// One accent color dot; "System" is the multicolor wheel macOS uses for "follow the system".
private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = choice.color {
                    Circle().fill(color.gradient)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
                }
                Circle().strokeBorder(.black.opacity(0.12))
                if isSelected {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
