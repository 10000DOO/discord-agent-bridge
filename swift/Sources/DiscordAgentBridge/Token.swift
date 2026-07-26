import Foundation

/// Resolves a Discord bot token from environment or CLI arguments.
public enum DiscordToken {
    /// Order: `DISCORD_BOT_TOKEN` → `DISCORD_TOKEN` → first CLI arg after argv[0] →
    /// `config.json` `discord.token` (C12: lowest-priority fallback so the field stops
    /// being dead, without disturbing the env/argv-first deployment story launchd/systemd
    /// setups already rely on).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        configToken: String? = nil
    ) -> String? {
        if let token = environment["DISCORD_BOT_TOKEN"], !token.isEmpty {
            return token
        }
        if let token = environment["DISCORD_TOKEN"], !token.isEmpty {
            return token
        }
        if arguments.count > 1 {
            let token = arguments[1]
            if !token.isEmpty { return token }
        }
        if let token = configToken, !token.isEmpty {
            return token
        }
        return nil
    }

    public static let usage = """
    Usage: dab [TOKEN]
      Set DISCORD_BOT_TOKEN or DISCORD_TOKEN, pass the bot token as the first argument,
      or set discord.token in config.json. Run `dab --setup` for details.

    Example:
      export DISCORD_BOT_TOKEN=your_bot_token
      swift run dab
    """
}
