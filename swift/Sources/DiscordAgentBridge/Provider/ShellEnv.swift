import Foundation

// Safe, regex-only scanner for shell dotfiles (TS `modes/custom/shellEnv.ts`).
// NEVER sources or executes the file; scans content for an allow-list of Anthropic/SDK
// env vars. Both `export KEY=...` and bare `KEY=...` forms are accepted, as are values
// inside an alias definition. Unknown keys ignored; values never logged.

/// Override home / inject file contents by basename for tests.
public struct ResolveCustomEnvOptions: Sendable, Equatable {
    public var homeDir: String?
    /// e.g. `{ ".zshrc": "export ANTHROPIC_MODEL=..." }`. Missing keys are read from disk.
    public var files: [String: String]?

    public init(homeDir: String? = nil, files: [String: String]? = nil) {
        self.homeDir = homeDir
        self.files = files
    }
}

public struct CustomEnvResult: Sendable, Equatable {
    public var env: [String: String]
    public var hasDangerousFlag: Bool
    public var source: String?

    public init(env: [String: String], hasDangerousFlag: Bool, source: String?) {
        self.env = env
        self.hasDangerousFlag = hasDangerousFlag
        self.source = source
    }
}

/// Dotfiles scanned. Later files override earlier; within a file, last occurrence wins.
private let defaultDotfiles = [
    ".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".bash_login", ".profile",
]

/// Allow-listed env vars only.
private let allowedKeys: Set<String> = [
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "API_TIMEOUT_MS",
]

private let dangerousFlag = "--dangerously-skip-permissions"

/// Extract allow-listed env vars from shell dotfiles under `homeDir` (or injected `files`).
public func resolveCustomEnv(_ opts: ResolveCustomEnvOptions = ResolveCustomEnvOptions()) -> CustomEnvResult {
    let homeDir = opts.homeDir ?? NSHomeDirectory()

    var env: [String: String] = [:]
    var source: String?
    var hasDangerousFlag = false

    for file in defaultDotfiles {
        let content: String?
        // Injected map wins (incl. empty string) so tests never touch real disk when key is set.
        if let files = opts.files, files.keys.contains(file) {
            content = files[file]
        } else {
            let path = (homeDir as NSString).appendingPathComponent(file)
            content = try? String(contentsOfFile: path, encoding: .utf8)
        }
        guard let content, !content.isEmpty else { continue }

        if content.contains(dangerousFlag) {
            hasDangerousFlag = true
        }

        let extracted = extractEnv(content)
        if !extracted.sourceKeys.isEmpty {
            for (k, v) in extracted.env { env[k] = v }
            source = file
        }
    }

    return CustomEnvResult(env: env, hasDangerousFlag: hasDangerousFlag, source: source)
}

/// Display label: `"Custom (model)"` when ANTHROPIC_MODEL is set, else `"Custom"`.
public func customBackendLabel(_ opts: ResolveCustomEnvOptions = ResolveCustomEnvOptions()) -> String {
    let env = resolveCustomEnv(opts).env
    if let model = env["ANTHROPIC_MODEL"], !model.isEmpty {
        // Operator-set env value: an SDK alias becomes its wire id, anything else prints as-is.
        return "Custom (\(modelDisplayText(model)))"
    }
    return "Custom"
}

// MARK: - private

private struct ExtractedEnv {
    var env: [String: String]
    var sourceKeys: [String]
}

/// Extract ALLOWED_KEYS assignments. Supports double/single/unquoted values and alias form.
/// Within one file, the last assignment for a key wins.
private func extractEnv(_ content: String) -> ExtractedEnv {
    var env: [String: String] = [:]
    var sourceKeys: [String] = []

    // TS: /(?:^|\s|;|')(?:export\s+)?\b(KEYS)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s;]*))/g
    let keysAlt = allowedKeys.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let pattern =
        "(?:^|\\s|;|')(?:export\\s+)?\\b(\(keysAlt))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s;]*))"
    guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
        return ExtractedEnv(env: [:], sourceKeys: [])
    }

    let ns = content as NSString
    let full = NSRange(location: 0, length: ns.length)
    re.enumerateMatches(in: content, options: [], range: full) { match, _, _ in
        guard let match, match.numberOfRanges >= 5 else { return }
        let key = ns.substring(with: match.range(at: 1))
        guard allowedKeys.contains(key) else { return }

        let rawValue: String
        if match.range(at: 2).location != NSNotFound {
            rawValue = ns.substring(with: match.range(at: 2))
        } else if match.range(at: 3).location != NSNotFound {
            rawValue = ns.substring(with: match.range(at: 3))
        } else if match.range(at: 4).location != NSNotFound {
            rawValue = ns.substring(with: match.range(at: 4))
        } else {
            rawValue = ""
        }

        env[key] = rawValue
        if !sourceKeys.contains(key) { sourceKeys.append(key) }
    }

    return ExtractedEnv(env: env, sourceKeys: sourceKeys)
}
