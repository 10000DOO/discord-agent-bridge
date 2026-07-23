import Foundation

/// Resolves a Discord bot token from environment or CLI arguments.
public enum DiscordToken {
    /// Order: `DISCORD_BOT_TOKEN` → `DISCORD_TOKEN` → first CLI arg after argv[0].
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
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
        return nil
    }

    public static let usage = """
    Usage: dab [TOKEN]
      Set DISCORD_BOT_TOKEN or DISCORD_TOKEN, or pass the bot token as the first argument.

    Example:
      export DISCORD_BOT_TOKEN=your_bot_token
      swift run dab
    """
}
