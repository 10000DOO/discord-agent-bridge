import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("RedmineApiKeyCipher")
struct RedmineApiKeyCipherTests {
    private let env = ["DAB_REDMINE_KEY_SECRET": "test-secret"]

    @Test func roundTripsPlaintext() throws {
        let plain = "my-redmine-api-key"
        let encrypted = try RedmineApiKeyCipher.encrypt(plain, environment: env)
        let decrypted = try RedmineApiKeyCipher.decrypt(encrypted, environment: env)
        #expect(decrypted == plain)
    }

    @Test func encryptThrowsWhenSecretMissing() {
        #expect(throws: RedmineApiKeyCipherError.self) {
            try RedmineApiKeyCipher.encrypt("plain", environment: [:])
        }
    }

    @Test func decryptThrowsWhenSecretMissing() throws {
        let encrypted = try RedmineApiKeyCipher.encrypt("plain", environment: env)
        #expect(throws: RedmineApiKeyCipherError.self) {
            try RedmineApiKeyCipher.decrypt(encrypted, environment: [:])
        }
    }

    @Test func encryptProducesRandomNonceEachCall() throws {
        let plain = "same-plaintext"
        let first = try RedmineApiKeyCipher.encrypt(plain, environment: env)
        let second = try RedmineApiKeyCipher.encrypt(plain, environment: env)
        #expect(first != second)
    }
}
