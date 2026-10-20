import Foundation

/// A speech model Hypervoice can run, all through MLX on Apple silicon.
/// Each downloads from Hugging Face the first time it's used.
nonisolated enum Engine: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwen, qwenDesign, qwenPresets, chatterbox, omnivoice, kokoro, pocket

    var id: String { rawValue }

    var name: String {
        switch self {
        case .qwen: "Qwen3-TTS"
        case .qwenDesign: "Qwen3-TTS VoiceDesign"
        case .qwenPresets: "Qwen3-TTS CustomVoice"
        case .chatterbox: "Chatterbox Turbo"
        case .omnivoice: "OmniVoice"
        case .kokoro: "Kokoro"
        case .pocket: "Pocket TTS"
        }
    }

    var summary: String {
        switch self {
        case .qwen: "Clones a voice from a few seconds of audio. 10 languages."
        case .qwenDesign: "Creates a voice from a written description. 10 languages."
        case .qwenPresets: "Nine studio voices that take direction, like \u{201C}whispering\u{201D}."
        case .chatterbox: "Fast English cloning. Understands [laugh], [sigh] and other tags."
        case .omnivoice: "Clones or designs voices in more than 600 languages."
        case .kokoro: "Tiny and fast, with dozens of built-in voices."
        case .pocket: "Kyutai's tiny model. Starts speaking almost instantly."
        }
    }

    var repository: String {
        switch self {
        case .qwen: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        case .qwenDesign: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
        case .qwenPresets: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
        case .chatterbox: "mlx-community/chatterbox-turbo-8bit"
        case .omnivoice: "mlx-community/OmniVoice"
        case .kokoro: "mlx-community/Kokoro-82M-bf16"
        case .pocket: "mlx-community/pocket-tts"
        }
    }

    /// What `TTS.loadModel` dispatches on, given up front so a cached model loads offline.
    var modelType: String {
        switch self {
        case .qwen, .qwenDesign, .qwenPresets: "qwen3_tts"
        case .chatterbox: "chatterbox_turbo"
        case .omnivoice: "omnivoice"
        case .kokoro: "kokoro"
        case .pocket: "pocket_tts"
        }
    }

    /// Roughly what the first use downloads, in bytes.
    var downloadSize: Int64 {
        switch self {
        case .qwen: 2_000_000_000
        case .qwenDesign: 3_100_000_000
        case .qwenPresets: 2_000_000_000
        case .chatterbox: 710_000_000
        case .omnivoice: 3_300_000_000
        case .kokoro: 390_000_000
        case .pocket: 240_000_000
        }
    }

    /// Speaks in a voice cloned from a sample.
    var clones: Bool { [.qwen, .chatterbox, .omnivoice].contains(self) }
    /// Invents a voice from a description.
    var designs: Bool { [.qwenDesign, .omnivoice].contains(self) }
    /// Needs the words spoken in the sample, not only the audio.
    var needsTranscript: Bool { [.qwen, .omnivoice].contains(self) }
    /// Takes a style instruction alongside a built-in voice.
    var takesDirection: Bool { self == .qwenPresets }

    /// Built-in voices, by the id the model knows them by.
    var presets: [Preset] {
        switch self {
        case .qwenPresets:
            [Preset("Ryan", "Ryan", "English"), Preset("Aiden", "Aiden", "English"),
             Preset("Vivian", "Vivian", "Chinese"), Preset("Serena", "Serena", "Chinese"),
             Preset("Uncle_Fu", "Uncle Fu", "Chinese"), Preset("Dylan", "Dylan", "Chinese"),
             Preset("Eric", "Eric", "Chinese"), Preset("Ono_Anna", "Ono Anna", "Japanese"),
             Preset("Sohee", "Sohee", "Korean")]
        case .kokoro:
            [Preset("af_heart", "Heart", "American English"), Preset("af_bella", "Bella", "American English"),
             Preset("af_nicole", "Nicole", "American English"), Preset("af_sarah", "Sarah", "American English"),
             Preset("af_sky", "Sky", "American English"), Preset("am_adam", "Adam", "American English"),
             Preset("am_michael", "Michael", "American English"), Preset("am_puck", "Puck", "American English"),
             Preset("bf_emma", "Emma", "British English"), Preset("bf_isabella", "Isabella", "British English"),
             Preset("bm_george", "George", "British English"), Preset("bm_lewis", "Lewis", "British English"),
             Preset("ff_siwis", "Siwis", "French"), Preset("ef_dora", "Dora", "Spanish"),
             Preset("if_sara", "Sara", "Italian"), Preset("pf_dora", "Dóra", "Portuguese"),
             Preset("jf_alpha", "Alpha", "Japanese"), Preset("zf_xiaoxiao", "Xiaoxiao", "Chinese"),
             Preset("hf_alpha", "Ananya", "Hindi")]
        case .pocket:
            ["alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma"]
                .map { Preset($0, $0.capitalized, "English") }
        case .chatterbox:
            [Preset("default", "Chatterbox", "English")]
        default:
            []
        }
    }

    static var cloning: [Engine] { allCases.filter(\.clones) }
    static var designing: [Engine] { allCases.filter(\.designs) }
}

nonisolated struct Preset: Hashable, Sendable {
    let id: String
    let name: String
    let language: String

    init(_ id: String, _ name: String, _ language: String) {
        self.id = id
        self.name = name
        self.language = language
    }
}

/// The speech-to-text model behind Transcribe and the transcripts of voice samples.
nonisolated enum Whisper {
    static let name = "Whisper Large v3 Turbo"
    static let summary = "Transcribes audio in 99 languages, with timestamps."
    static let repository = "mlx-community/whisper-large-v3-turbo"
    static let downloadSize: Int64 = 1_620_000_000
}
