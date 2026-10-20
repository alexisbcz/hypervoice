import Foundation
import Security

/// Your Hugging Face access token, for models you have to accept terms for first, like Phonon Multilingual.
/// It's kept in the Keychain and handed to MLX Audio through `HF_TOKEN`, which is where it looks.
nonisolated enum HubToken {
    private static let service = "dev.alexis.Hypervoice.huggingface"

    static var value: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var isSet: Bool { !(value ?? "").isEmpty }

    /// Saves, or with an empty token removes, then applies it to this run.
    static func save(_ token: String) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        if !token.isEmpty {
            var add = query
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
        apply()
    }

    /// Puts the saved token in this process's environment, or takes back one it put there before.
    static func apply() {
        if let saved = value, !saved.isEmpty {
            setenv("HF_TOKEN", saved, 1)
        } else if ownsEnvironment {
            unsetenv("HF_TOKEN")
        }
        ownsEnvironment = isSet
    }

    nonisolated(unsafe) private static var ownsEnvironment = false

    /// What to tell someone whose download Hugging Face refused.
    static func explain(_ error: Error, for engine: Engine) -> String {
        let message = error.localizedDescription
        guard engine.isGated else { return message }
        let refused = ["401", "403", "unauthorized", "forbidden", "gated", "access"].contains { message.lowercased().contains($0) }
        guard refused || !isSet else { return message }
        return isSet
            ? "Hugging Face refused the download. Accept \(engine.name)'s terms at \(engine.page.absoluteString) with the account your token belongs to."
            : "\(engine.name) needs a Hugging Face token. Accept its terms at \(engine.page.absoluteString), then add a token in Settings › General."
    }
}
