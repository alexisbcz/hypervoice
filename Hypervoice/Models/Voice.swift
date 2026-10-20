import Foundation

/// A voice to speak with: one you cloned or designed, kept as a sample, or one an engine ships with.
nonisolated struct Voice: Codable, Identifiable, Hashable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// Recorded or imported audio of a real person.
        case cloned
        /// Invented from a description, then kept as a sample so it sounds the same every time.
        case designed
        /// Built into an engine.
        case preset
    }

    var id: String
    var name: String
    var origin: Origin
    /// The engine it speaks with by default.
    var engine: Engine
    /// The reference recording, by file name inside the library's Voices folder.
    var sample: String?
    /// The words spoken in the sample.
    var transcript: String?
    /// For designed voices, the description they came from.
    var prompt: String?
    /// For presets, the engine's own id for the voice.
    var preset: String?
    var language: String?
    var created: Date

    var isPreset: Bool { origin == .preset }

    /// Engines that can speak in this voice.
    var engines: [Engine] {
        isPreset ? [engine] : Engine.cloning
    }

    var subtitle: String {
        switch origin {
        case .cloned: "Cloned"
        case .designed: "Designed"
        case .preset: [engine.name, language].compactMap(\.self).joined(separator: " · ")
        }
    }

    static func preset(_ preset: Preset, of engine: Engine) -> Voice {
        Voice(id: "\(engine.rawValue):\(preset.id)", name: preset.name, origin: .preset, engine: engine,
              preset: preset.id, language: preset.language, created: .distantPast)
    }

    /// Every built-in voice, grouped by engine in catalog order.
    static let presets: [Voice] = Engine.allCases.flatMap { engine in engine.presets.map { preset($0, of: engine) } }
}

/// A finished piece of generated speech, saved to the library.
nonisolated struct Clip: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var voiceName: String
    var engine: Engine?
    /// File name inside the library's Clips folder.
    var file: String
    var duration: Double
    var created: Date
    /// Seconds spent generating, to compare engines.
    var generationTime: Double?
}

/// A transcription of an audio or video file.
nonisolated struct Transcript: Identifiable, Hashable, Sendable {
    struct Segment: Hashable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    let id = UUID()
    var source: URL
    var text: String
    var segments: [Segment]
    var language: String?

    /// SubRip subtitles, one cue per segment.
    var srt: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.timestamp(segment.start)) --> \(Self.timestamp(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

extension Double {
    /// "0:07", "1:42", "1:02:03".
    var clock: String {
        let total = Int(rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
