import Foundation

/// LFM3 Audio's voices: a female and a male one in each locale its model card lists. The model has no
/// other voices and can't clone or follow a description; its system prompt only takes a locale and a gender.
nonisolated enum LFM3Voices {
    /// Each locale's code, as the preset ids use it, and the English name the system prompt takes.
    static let locales: [(code: String, name: String)] = [
        ("en-US", "American English"), ("en-GB", "British English"), ("ar", "Arabic"), ("zh", "Chinese"),
        ("da", "Danish"), ("nl", "Dutch"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("he", "Hebrew"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"),
        ("pl", "Polish"), ("pt", "Portuguese"), ("es", "Spanish"), ("sv", "Swedish"), ("tr", "Turkish"),
    ]

    static let all: [Preset] = locales.flatMap { locale in
        ["female", "male"].map { Preset("\(locale.code)-\($0)", $0.capitalized, locale.name) }
    }

    /// The system prompt for a preset id like "fr-male", as the model card gives it.
    static func instructions(_ id: String?) -> String {
        let parts = (id ?? "").split(separator: "-")
        let gender = parts.last == "male" ? "male" : "female"
        let code = parts.dropLast().joined(separator: "-")
        let language = locales.first { $0.code == code }?.name ?? "American English"
        return "Perform TTS in \(language) using a \(gender) voice."
    }

    /// The system prompt for transcription: in a language it knows, from an ISO code like "fr", else whichever it hears.
    static func asrInstructions(_ language: String?) -> String {
        guard let code = language?.lowercased().split(separator: "-").first.map(String.init),
              locales.contains(where: { $0.code.split(separator: "-").first.map(String.init) == code }),
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code)
        else { return "Perform ASR." }
        return "Perform ASR in \(name)."
    }
}
