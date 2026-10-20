import SwiftUI
import UniformTypeIdentifiers

/// Prepares a sample for cloning: silence trimmed from both ends, cut to at most 15 seconds at a quiet moment,
/// and evened out in loudness. Short, clean samples clone better and faster than long ones.
nonisolated enum Sample {
    static let maximum: Double = 15

    static func prepare(_ samples: [Float], sampleRate: Int) -> [Float] {
        let threshold: Float = 0.02
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold })
        else { return samples }
        let pad = sampleRate / 10
        var trimmed = Array(samples[max(0, first - pad)...min(samples.count - 1, last + pad)])
        let limit = Int(maximum * Double(sampleRate))
        if trimmed.count > limit {
            trimmed = Array(trimmed[..<quietestPoint(in: trimmed, from: limit * 4 / 5, to: limit, sampleRate: sampleRate)])
        }
        let peak = trimmed.map(abs).max() ?? 1
        guard peak > 0 else { return trimmed }
        let gain = 0.9 / peak
        return trimmed.map { $0 * gain }
    }

    /// Where a cut is least likely to land mid-word: the quietest 50 ms between `start` and `end`.
    private static func quietestPoint(in samples: [Float], from start: Int, to end: Int, sampleRate: Int) -> Int {
        let window = sampleRate / 20
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= end {
            var energy: Float = 0
            for i in index..<(index + window) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = index + window / 2
            }
            index += window / 2
        }
        return best
    }
}

/// Clone a voice: record or import a sample, check the words in it, name it.
struct CloneSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(ModelStore.self) private var models
    @Environment(Studio.self) private var studio

    let source: URL?

    @State private var recorder = Recorder()
    @State private var name = ""
    @State private var engine: Engine = .qwen
    @State private var sample: URL?
    @State private var peaks: [Float] = []
    @State private var duration: Double = 0
    @State private var transcript = ""
    @State private var isTranscribing = false
    @State private var error: String?
    @State private var wasRecorded = false

    static let reading = "I keep a small notebook by the window, and every morning I write down one thing I noticed the day before. Some days it's the light on the rooftops; other days it's a song someone was humming on the train."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone a Voice").font(.title2.weight(.semibold))
                Text("Record or import 5 to 15 seconds of one person speaking clearly, with no music behind them.")
                    .foregroundStyle(.secondary)
            }

            if let sample {
                samplePreview(sample)
            } else if recorder.isRecording {
                recording
            } else {
                chooser
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Grandpa, Narrator, Me…"))
                Picker("Speaks with", selection: $engine) {
                    ForEach(Engine.cloning) { engine in
                        Text(engine.name).tag(engine)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Words in the sample")
                        Spacer()
                        if isTranscribing {
                            ProgressView().controlSize(.small)
                        } else if sample != nil {
                            Button(models.isInstalled(.whisper) ? "Transcribe" : "Transcribe (downloads \(Whisper.downloadSize.bytes))") { transcribe() }
                                .buttonStyle(.link)
                        }
                    }
                    TextEditor(text: $transcript)
                        .font(.body)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    Text(engine.needsTranscript ? "\(engine.name) clones best when these match the sample exactly." : "\(engine.name) doesn't need them, but other engines do.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sample == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || isTranscribing
                              || (engine.needsTranscript && transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            engine = studio.engine.clones ? studio.engine : .qwen
            if let source { await load(source, recorded: false) }
        }
        .onChange(of: recorder.recording) { _, url in
            if let url { Task { await load(url, recorded: true) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await load(url, recorded: false) }
            return true
        }
    }

    private var chooser: some View {
        HStack(spacing: 12) {
            Button {
                Task { _ = await recorder.start() }
            } label: {
                Label("Record", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            Button {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .movie]
                if panel.runModal() == .OK, let url = panel.url { Task { await load(url, recorded: false) } }
            } label: {
                Label("Choose File…", systemImage: "folder").frame(maxWidth: .infinity)
            }
        }
        .controlSize(.extraLarge)
        .overlay(alignment: .bottom) {
            if let error = recorder.error { Text(error).font(.caption).foregroundStyle(.red).offset(y: 20) }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read this aloud, at your normal pace:").font(.callout).foregroundStyle(.secondary)
            Text(Self.reading)
                .font(.system(size: 16))
                .lineSpacing(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            HStack(spacing: 12) {
                Button {
                    _ = recorder.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                Waveform(peaks: recorder.levels, color: .red).frame(height: 30)
                Text("\(recorder.elapsed.clock) / \(Recorder.maximum.clock)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func samplePreview(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Button {
                player.isPlaying("sample") ? player.stop() : player.play(url, id: "sample")
            } label: {
                Image(systemName: player.isPlaying("sample") ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
            }
            .buttonStyle(.borderless)
            Waveform(peaks: peaks, progress: player.isPlaying("sample") ? player.position / max(duration, 0.1) : 1)
                .frame(height: 36)
            Text(duration.clock).monospacedDigit().foregroundStyle(.secondary)
            Button("Replace", systemImage: "arrow.counterclockwise") {
                player.stop()
                sample = nil
                transcript = ""
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Use another sample")
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    private func load(_ url: URL, recorded: Bool) async {
        error = nil
        do {
            let rate = Generator.sampleRate
            let prepared = Sample.prepare(try await WAV.read(url, sampleRate: rate), sampleRate: rate)
            guard prepared.count > rate * 2 else {
                error = "That's under two seconds of speech. Try a longer sample."
                return
            }
            let file = FileManager.default.temporaryDirectory.appending(path: "Hypervoice sample \(UUID().uuidString).wav")
            try WAV.write(prepared, sampleRate: rate, to: file)
            sample = file
            peaks = WAV.peaks(prepared, count: 200)
            duration = Double(prepared.count) / Double(rate)
            wasRecorded = recorded
            if name.isEmpty, !recorded { name = url.deletingPathExtension().lastPathComponent }
            if recorded {
                transcript = Self.reading
            } else if models.isInstalled(.whisper) {
                transcribe()
            }
        } catch {
            self.error = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    private func transcribe() {
        guard let sample else { return }
        isTranscribing = true
        Task {
            do {
                let result = try await ModelStore.shared.track(.whisper) { try await Transcriber.shared.transcribe(sample) }
                transcript = result.text
            } catch {
                self.error = error.localizedDescription
            }
            isTranscribing = false
        }
    }

    private func save() {
        guard let sample else { return }
        do {
            let voice = try library.addVoice(name: name.trimmingCharacters(in: .whitespaces), origin: .cloned, sample: sample,
                                             transcript: transcript, engine: engine)
            studio.engine = engine
            studio.use(voice)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func close() {
        if recorder.isRecording { _ = recorder.stop() }
        player.stop()
        dismiss()
    }
}

/// Design a voice from a description, hear it, and keep the take you like as a sample,
/// so the voice sounds the same every time after.
struct DesignSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(ModelStore.self) private var models
    @Environment(Studio.self) private var studio

    @State private var name = ""
    @State private var prompt = ""
    @State private var engine: Engine = .qwenDesign
    @State private var line = "Every morning I write down one thing I noticed the day before. Today, it was the light on the rooftops."
    @State private var take: URL?
    @State private var peaks: [Float] = []
    @State private var isGenerating = false
    @State private var status = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    static let ideas = [
        "A warm, deep male narrator with a slight British accent, calm and unhurried.",
        "A bright young woman, upbeat and quick, like a morning radio host.",
        "An elderly storyteller with a gravelly, gentle voice, speaking slowly.",
        "A crisp, confident newsreader with a neutral American accent.",
        "A soft-spoken ASMR voice, close to the microphone, almost whispering.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Design a Voice").font(.title2.weight(.semibold))
                Text("Describe a voice that doesn't exist yet. Generate takes until one sounds right, then keep it.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Narrator"))
                Picker("Designed by", selection: $engine) {
                    ForEach(Engine.designing) { Text($0.name).tag($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(height: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: .rect(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.ideas, id: \.self) { idea in
                                Button(idea.components(separatedBy: ",").first ?? idea) { prompt = idea }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help(idea)
                            }
                        }
                    }
                }
                TextField("Says", text: $line, axis: .vertical)
                    .lineLimit(2...3)
            }
            .formStyle(.columns)

            HStack(spacing: 12) {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { task?.cancel() }
                } else if let take {
                    Button {
                        player.isPlaying("take") ? player.stop() : player.play(take, id: "take")
                    } label: {
                        Image(systemName: player.isPlaying("take") ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                    }
                    .buttonStyle(.borderless)
                    Waveform(peaks: peaks).frame(height: 36)
                    Button("Try Again", systemImage: "arrow.clockwise") { generate() }
                } else {
                    Button("Generate a Take", systemImage: "sparkles") { generate() }
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || line.isEmpty)
                    if !models.isInstalled(engine) {
                        Text("Downloads \(engine.downloadSize.bytes) first").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep This Voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(take == nil || isGenerating || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func generate() {
        error = nil
        isGenerating = true
        player.stop()
        let request = SpeechRequest(text: line, engine: engine, voice: prompt)
        let engine = engine
        task = Task {
            do {
                status = models.isInstalled(engine) ? "Loading \(engine.name)…" : "Downloading \(engine.name)…"
                let rate = try await ModelStore.shared.track(.engine(engine)) { try await Synth.shared.prepare(engine) }
                status = "Generating…"
                let samples = Sample.prepare(Generator.resample(try await Synth.shared.synthesize(request), from: rate, to: Generator.sampleRate),
                                             sampleRate: Generator.sampleRate)
                try Task.checkCancellation()
                let file = FileManager.default.temporaryDirectory.appending(path: "Hypervoice take \(UUID().uuidString).wav")
                try WAV.write(samples, sampleRate: Generator.sampleRate, to: file)
                take = file
                peaks = WAV.peaks(samples, count: 200)
                player.play(file, id: "take")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func save() {
        guard let take else { return }
        do {
            let voice = try library.addVoice(name: name.trimmingCharacters(in: .whitespaces), origin: .designed, sample: take,
                                             transcript: line, prompt: prompt, engine: .qwen)
            studio.engine = .qwen
            studio.use(voice)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func close() {
        task?.cancel()
        player.stop()
        dismiss()
    }
}

struct EditVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Library.self) private var library
    @State var voice: Voice

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                VoiceAvatar(voice: voice, size: 40)
                Text(voice.name.isEmpty ? "Voice" : voice.name).font(.title2.weight(.semibold))
            }
            Form {
                TextField("Name", text: $voice.name)
                Picker("Speaks with", selection: $voice.engine) {
                    ForEach(Engine.cloning) { Text($0.name).tag($0) }
                }
                TextField("Words in the sample", text: Binding(get: { voice.transcript ?? "" }, set: { voice.transcript = $0 }), axis: .vertical)
                    .lineLimit(3...6)
                if let prompt = voice.prompt {
                    LabeledContent("Designed from", value: prompt)
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    library.update(voice)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(voice.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
