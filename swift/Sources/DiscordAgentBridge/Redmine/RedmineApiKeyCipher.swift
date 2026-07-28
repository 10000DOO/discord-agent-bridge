import Crypto
import Foundation

public enum RedmineApiKeyCipherError: Error {
    case missingSecretEnv
}

/// Encrypts/decrypts Redmine API keys at rest (R11). Fail-secure: without
/// `DAB_REDMINE_KEY_SECRET` in the environment, both directions throw rather
/// than falling back to plaintext or a fixed key (mirrors `ConfigSchema.swift`'s
/// `missingSecrets` pattern).
public enum RedmineApiKeyCipher {
    private static let secretEnvKey = "DAB_REDMINE_KEY_SECRET"

    public static func encrypt(
        _ plain: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Data {
        let key = try symmetricKey(environment: environment)
        let sealed = try AES.GCM.seal(Data(plain.utf8), using: key)
        // `combined` is only nil for a non-default nonce length; we never pass one.
        return sealed.combined!
    }

    public static func decrypt(
        _ data: Data,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let key = try symmetricKey(environment: environment)
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let opened = try AES.GCM.open(sealedBox, using: key)
        return String(decoding: opened, as: UTF8.self)
    }

    private static func symmetricKey(environment: [String: String]) throws -> SymmetricKey {
        guard let secret = environment[secretEnvKey], !secret.isEmpty else {
            throw RedmineApiKeyCipherError.missingSecretEnv
        }
        return SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }
}
