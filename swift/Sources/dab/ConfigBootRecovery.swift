import DiscordAgentBridge
import Foundation

// Boot must never die on config.json (docs/all-members-admin.md R10).
//
// It used to: a present-but-unreadable config.json aborted boot with exit(1), and under a
// keep-alive service supervisor that becomes a die/restart loop. The realistic trigger is not even
// corruption — writing a config.json that carries only an `auth` block (no `discord` section) was
// enough, because validation treated the absent section as an invalid value. The token normally
// lives in ~/.dab/env, so that file was never required to carry one.
//
// Now: an unreadable config.json is IGNORED (the process boots on defaults, exactly as it does
// when no config.json exists at all) and the reason is reported — logged, and posted to every
// guild's control channel once the gateway is up, so it is not silently swallowed. Updates keep
// working, which is the point: a bad config must never be able to strand a machine on an old
// build with no way in.
//
// The only remaining hard stop is having no token anywhere, which the caller already handles by
// running the setup wizard or printing usage.

struct ConfigBootOutcome: Equatable {
    /// nil → run on defaults (no file, or a file we could not read).
    var config: AppConfig?
    /// Human-facing reason, already localized. nil → nothing to report.
    var warning: String?
}

/// Decide what boot does with config.json. Pure apart from the injected loader, so the
/// never-exit contract is testable without launching a bot.
func resolveBootConfig(
    exists: Bool,
    path: String,
    load: @Sendable () async throws -> AppConfig
) async -> ConfigBootOutcome {
    guard exists else { return ConfigBootOutcome(config: nil, warning: nil) }
    do {
        return ConfigBootOutcome(config: try await load(), warning: nil)
    } catch {
        return ConfigBootOutcome(
            config: nil,
            warning: I18n.t("config.load.failed", ["error": "\(error)", "path": path])
        )
    }
}

/// Holds the boot-time config warning until the gateway is up and control channels are known.
/// Read once by `onReady`; a second read returns nil so a reconnect does not re-announce.
actor BootWarningRegistry {
    static let shared = BootWarningRegistry()

    private var warning: String?

    func set(_ text: String?) {
        warning = text
    }

    func take() -> String? {
        defer { warning = nil }
        return warning
    }
}
