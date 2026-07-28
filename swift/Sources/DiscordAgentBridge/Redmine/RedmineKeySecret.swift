import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum RedmineKeySecretError: Error, Equatable, Sendable {
    case writeFailed(String)
}

/// Ensures `DAB_REDMINE_KEY_SECRET` is available for `RedmineApiKeyCipher`.
/// Order: process env → `~/.dab/env` → generate cryptographically secure random, append, setenv.
/// Never overwrites an existing secret in env or file.
public enum RedmineKeySecret {
    public static let envKey = "DAB_REDMINE_KEY_SECRET"

    public struct EnsureResult: Equatable, Sendable {
        public let secret: String
        /// `true` only when this call generated and persisted a new secret.
        public let generated: Bool
    }

    public static func defaultEnvFileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".dab/env")
    }

    /// Ensure secret is available in process env; create+persist if needed.
    /// - Parameters:
    ///   - environment: Snapshot used for the process-env check (injectable for tests).
    ///   - envFileURL: Env file path (default `~/.dab/env`; inject temp path in tests).
    ///   - setEnv: Writes into the live process environment (default `setenv(..., 1)`).
    @discardableResult
    public static func ensure(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        envFileURL: URL = defaultEnvFileURL(),
        setEnv: (String, String) -> Void = { name, value in
            _ = setenv(name, value, 1)
        }
    ) throws -> EnsureResult {
        if let existing = environment[envKey], !existing.isEmpty {
            return EnsureResult(secret: existing, generated: false)
        }
        if let fromFile = readSecretFromEnvFile(envFileURL), !fromFile.isEmpty {
            setEnv(envKey, fromFile)
            return EnsureResult(secret: fromFile, generated: false)
        }
        let secret = generateSecret()
        try appendSecret(secret, to: envFileURL)
        setEnv(envKey, secret)
        return EnsureResult(secret: secret, generated: true)
    }

    // MARK: - Internals

    /// 32 CSPRNG bytes → 64-char lowercase hex. Not time/version based.
    static func generateSecret() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func readSecretFromEnvFile(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard key == envKey else { continue }
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func appendSecret(_ secret: String, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let lineData = Data("\(envKey)=\(secret)\n".utf8)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(
                    atPath: url.path,
                    contents: lineData,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw RedmineKeySecretError.writeFailed("createFile failed: \(url.path)")
                }
            } else {
                // Preserve existing keys; only append. Ensure trailing newline before our line.
                if let existing = try? Data(contentsOf: url), !existing.isEmpty,
                   existing.last != UInt8(ascii: "\n") {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("\n".utf8))
                    try handle.write(contentsOf: lineData)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: lineData)
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as RedmineKeySecretError {
            throw error
        } catch {
            throw RedmineKeySecretError.writeFailed(String(describing: error))
        }
    }
}
