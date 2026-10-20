import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("API", systemImage: "network") { APISettings() }
        }
        .frame(width: 520)
        .scenePadding()
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
        }
        .formStyle(.grouped)
    }

    static let languages = ["en", "fr", "es", "de", "it", "pt", "nl", "ja", "zh", "ko", "ru", "ar", "hi", "pl", "tr", "sv", "uk"]
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
                Text("GET /v1/voices lists every voice. Add \"model\" to pick an engine and \"instructions\" to direct a CustomVoice preset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { server.setEnabled(enabled, port: port) }
        .onSubmit { server.setEnabled(enabled, port: port) }
    }
}
