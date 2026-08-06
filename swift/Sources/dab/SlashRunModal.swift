import DiscordAgentBridge
import Foundation

// MARK: - /command modal (WO-7, docs/cli-slash-command-parity.md §3-5-1 · C7 · C8 · C21)

/// Modal `custom_id` prefix — how the picked command rides from the picker to the submit handler.
/// No other modal in this app starts with it (`dir:*`, `preset.name`, `redmine:config`).
let slashRunModalPrefix = "run:"

/// Discord's hard limits for the surfaces this modal touches.
let discordCustomIdLimit = 100
let discordModalTitleLimit = 45

/// What `/command command:<value>` should do, decided from the submitted value ALONE.
///
/// C7: `showModal` has to be this interaction's first and only ack — a defer makes a modal
/// impossible, and >3s of work kills the interaction outright. So every case below is a string
/// test: no backend call, no store read, not even the autocomplete cache. The "is this command
/// still real" question (C8) is answered at submit time, where a defer is allowed.
enum SlashRunOpen: Equatable {
    /// Autocomplete's C1 stand-in came back (`dab:no-session`) — that is guidance text, not a
    /// command. Answer with the same guidance instead of opening a modal on nothing.
    case noSession
    /// `run:{command}` would blow the 100-char `custom_id` (C21). Truncating it would open a modal
    /// that silently submits a DIFFERENT command, so refuse and say so.
    case nameTooLong
    case openModal(customId: String, command: String)
}

func slashRunOpenDecision(commandValue: String) -> SlashRunOpen {
    let command = commandValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty, command != slashCatalogNoSessionValue else { return .noSession }
    let customId = slashRunModalPrefix + command
    guard customId.count <= discordCustomIdLimit else { return .nameTooLong }
    return .openModal(customId: customId, command: command)
}

/// The command carried by a modal `custom_id`, or nil when the modal is not ours.
func parseSlashRunModalCustomId(_ customId: String) -> String? {
    guard customId.hasPrefix(slashRunModalPrefix) else { return nil }
    let command = String(customId.dropFirst(slashRunModalPrefix.count))
    return command.isEmpty ? nil : command
}

/// Modal title: the command about to run, so the user can see WHAT they are typing a prompt for.
/// Discord caps a modal title at 45 characters and does not validate it client-side.
func slashRunModalTitle(command: String) -> String {
    let title = "/" + command
    guard title.count > discordModalTitleLimit else { return title }
    return String(title.prefix(discordModalTitleLimit - 1)) + "…"
}

/// The text handed to the backend: the command line, then the user's prompt verbatim below it.
///
/// That newline is the entire reason this input is a modal and not a slash option (§3-5-1) —
/// Discord's string options cannot carry one, and skills are routinely driven as `/name` plus
/// several lines of prompt. Only the outer whitespace is trimmed; every interior newline the user
/// typed is passed through untouched. An empty prompt sends the bare command, which is how
/// argument-less commands are meant to be run.
func slashRunPromptText(command: String, prompt: String) -> String {
    let body = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? "/\(command)" : "/\(command)\n\(body)"
}

/// C8: the command name travelled through the client inside `custom_id`, and `/mode backend …`
/// may have changed what this channel can run since the picker was drawn. Re-check against the
/// backend bound RIGHT NOW before anything is sent.
///
/// Reads the very cache autocomplete filled — a channel that switched backends has its entry
/// dropped outright (C26), so a switched channel can never answer "yes" out of the old list. Stays
/// synchronous for the same reason autocomplete is (C17): nothing here waits on a backend.
func slashRunCommandStillAvailable(channelId: String, backend: Backend, command: String) -> Bool {
    autocompleteSlashCommands(channelId: channelId, backend: backend).contains { $0.name == command }
}
