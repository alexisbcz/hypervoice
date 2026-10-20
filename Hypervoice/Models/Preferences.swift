import Foundation

/// Every user preference, by its UserDefaults key, so views can share one `@AppStorage` spelling.
enum Pref {
    static let voice = "speak.voice"
    static let engine = "speak.engine"
    static let direction = "speak.direction"
    static let draft = "speak.draft"
    static let script = "script.text"
    static let serverEnabled = "server.enabled"
    static let serverPort = "server.port"
    static let transcriptionLanguage = "transcribe.language"
}

enum Prefs {
    /// The voice Speak opens with and the API falls back to.
    static var defaultVoice: String? { UserDefaults.standard.string(forKey: Pref.voice) }
}
