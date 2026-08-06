import DiscordAgentBridge
import DiscordBM
import Foundation

// `/diff` — uncommitted changes of the session folder, inside a thread (WO-7 · WO-8).
// Parsing and formatting live in the library (`Render/GitDiffView.swift`); this file runs git and
// talks to Discord.

private let diffLog = Logger(name: "diff")

// MARK: - git

struct GitCommandResult {
    var code: Int32
    var stdout: String
    var ok: Bool { code == 0 }
}

/// Run one git command in `cwd`. stderr is discarded: a failure is judged by the exit code, and
/// mixing stderr into stdout would corrupt a diff body. Blocking work is pushed off the cooperative
/// pool so a slow repo can't stall the gateway.
func runGit(_ args: [String], cwd: String, timeout: TimeInterval = 20) async -> GitCommandResult {
    await Task.detached(priority: .userInitiated) {
        runGitSync(args, cwd: cwd, timeout: timeout)
    }.value
}

private func runGitSync(_ args: [String], cwd: String, timeout: TimeInterval) -> GitCommandResult {
    let process = Process()
    // Same resolver the sidecar spawn uses: under launchd/systemd PATH is minimal and a bare "git"
    // would not be found.
    process.executableURL = URL(fileURLWithPath: ProcessSidecarTransport.resolveExecutable("git"))
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        diffLog.warn("diff: git spawn failed args=\(args.first ?? "?") error=\(error)")
        return GitCommandResult(code: -1, stdout: "")
    }
    let killer = DispatchWorkItem {
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    // Single reader + a discarded stderr means the child can never block on an undrained pipe.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    return GitCommandResult(code: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
}

/// Collect the folder's uncommitted changes. `nil` when the folder is not a git work tree.
func gitChangedFiles(cwd: String) async -> [GitChangedFile]? {
    let insideWorkTree = await runGit(["rev-parse", "--is-inside-work-tree"], cwd: cwd)
    guard insideWorkTree.ok, insideWorkTree.stdout.contains("true") else { return nil }

    let status = await runGit(["status", "--porcelain"], cwd: cwd)
    guard status.ok else { return nil }
    let files = parseGitStatusPorcelain(status.stdout)
    guard !files.isEmpty else { return [] }

    // `HEAD` covers staged + unstaged in one pass; a repo with no commits yet has no HEAD, so fall
    // back to the work-tree-only form there.
    var numstat = await runGit(["diff", "HEAD", "--numstat"], cwd: cwd)
    if !numstat.ok {
        numstat = await runGit(["diff", "--numstat"], cwd: cwd)
    }
    var counts = numstat.ok ? parseGitNumstat(numstat.stdout) : [:]
    // Untracked files appear in no diff, so their line count is read locally rather than spending a
    // `--no-index` process each.
    for file in files where file.isUntrackedNeedingCount(counts) {
        counts[file.path] = (added: countLines(cwd: cwd, path: file.path), removed: 0)
    }
    return mergeChangedFiles(status: files, numstat: counts)
}

/// One file's diff body. Untracked files have no index side, hence the `--no-index` form.
func gitFileDiff(cwd: String, file: GitChangedFile) async -> String {
    if file.kind.isUntracked {
        // Exit code 1 just means "differs", which is the normal case here.
        let result = await runGit(["diff", "--no-index", "--", "/dev/null", file.path], cwd: cwd)
        return result.stdout
    }
    let versusHead = await runGit(["diff", "HEAD", "--", file.path], cwd: cwd)
    if versusHead.ok || !versusHead.stdout.isEmpty { return versusHead.stdout }
    return await runGit(["diff", "--", file.path], cwd: cwd).stdout
}

/// Current branch name, or nil when detached / unavailable.
func gitBranchName(cwd: String) async -> String? {
    let result = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
    let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.ok, !name.isEmpty, name != "HEAD" else { return nil }
    return name
}

private let untrackedCountByteCap = 2 * 1024 * 1024

/// Line count of a file inside the session folder, capped so a huge blob can't be slurped whole.
private func countLines(cwd: String, path: String) -> Int {
    let full = (cwd as NSString).appendingPathComponent(path)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
          let size = attrs[.size] as? Int, size <= untrackedCountByteCap,
          let data = FileManager.default.contents(atPath: full)
    else { return 0 }
    guard !data.isEmpty else { return 0 }
    let newlines = data.reduce(into: 0) { count, byte in if byte == 0x0A { count += 1 } }
    // A trailing byte that is not a newline still ends a line.
    return data.last == 0x0A ? newlines : newlines + 1
}

private extension GitChangedFile {
    func isUntrackedNeedingCount(_ counts: [String: (added: Int, removed: Int)]) -> Bool {
        kind.isUntracked && counts[path] == nil
    }
}

// MARK: - Thread state

/// Per-thread `/diff` state so a later click can rebuild the same file list without re-running git.
/// The thread id doubles as the interaction's channel id, so no id has to be smuggled into a
/// custom_id. Bounded: a long-lived bot must not accumulate one entry per `/diff` forever.
actor DiffThreadRegistry {
    static let shared = DiffThreadRegistry()
    private static let capacity = 50

    private struct Entry {
        var cwd: String
        var files: [GitChangedFile]
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func put(threadId: String, cwd: String, files: [GitChangedFile]) {
        if entries[threadId] == nil { order.append(threadId) }
        entries[threadId] = Entry(cwd: cwd, files: files)
        while order.count > Self.capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func get(threadId: String) -> (cwd: String, files: [GitChangedFile])? {
        guard let entry = entries[threadId] else { return nil }
        return (entry.cwd, entry.files)
    }
}

// MARK: - Command

enum DiffCommandOutcome {
    case notARepo
    case noChanges
    case posted(fileCount: Int)
    case failed
}

/// Open a thread for this run and post the summary plus the pickers into it.
func postDiffThread(client: any DiscordClient, channelId: String, cwd: String) async -> DiffCommandOutcome {
    guard let files = await gitChangedFiles(cwd: cwd) else { return .notARepo }
    guard !files.isEmpty else { return .noChanges }

    let branch = await gitBranchName(cwd: cwd)
    let repoName = (cwd as NSString).lastPathComponent
    let summary = formatDiffSummary(files: files, repoName: repoName, branch: branch)

    guard let threadResponse = try? await client.createThread(
        channelId: ChannelSnowflake(channelId),
        payload: Payloads.CreateThreadWithoutMessage(name: diffThreadName(fileCount: files.count), type: .publicThread)
    ), let thread = try? threadResponse.decode() else {
        diffLog.warn("diff: thread create failed channel=\(channelId)")
        return .failed
    }
    let threadId = thread.id
    await DiffThreadRegistry.shared.put(threadId: threadId.rawValue, cwd: cwd, files: files)

    let embed = Embed(
        title: summary.title,
        description: summary.description,
        color: DiscordColor(value: DiscordColors.streaming),
        footer: Embed.Footer(text: summary.footer)
    )
    _ = await createMessageWithRetry(
        client: client,
        channelId: threadId,
        payload: .init(embeds: [embed], components: diffComponentRows(files: files))
    )
    return .posted(fileCount: files.count)
}

/// Select pages (25 per menu) plus the expand-all button. A single-file change needs no picker, but
/// it still needs the button — without it there would be no way to see that file's diff at all.
func diffComponentRows(files: [GitChangedFile]) -> [Interaction.ActionRow] {
    guard !files.isEmpty else { return [] }
    let pages = files.count > 1 ? diffFileSelectPages(files: files) : []
    var rows: [Interaction.ActionRow] = []
    var offset = 0
    for (pageIndex, page) in pages.enumerated() {
        let options = page.enumerated().map { indexInPage, file in
            Interaction.ActionRow.StringSelectMenu.Option(
                label: DiscordText.truncate(file.path, 100),
                value: "\(offset + indexInPage)",
                description: "+\(file.added) -\(file.removed)"
            )
        }
        rows.append([
            .stringSelect(Interaction.ActionRow.StringSelectMenu(
                custom_id: diffFileSelectCustomId,
                options: options,
                placeholder: pages.count > 1
                    ? I18n.t("diff.select.placeholderPaged", ["page": "\(pageIndex + 1)", "pages": "\(pages.count)"])
                    : I18n.t("diff.select.placeholder")
            ))
        ])
        offset += page.count
    }
    rows.append([
        .button(.init(style: .secondary, label: I18n.t("diff.button.expandAll"), custom_id: diffExpandAllCustomId))
    ])
    return rows
}

// MARK: - Components (WO-8)

let diffFileSelectCustomId = "diff:file"
let diffExpandAllCustomId = "diff:all"

enum DiffComponentAction {
    case file
    case expandAll
}

/// `diff:` namespace, kept separate from every other custom_id family.
func parseDiffComponentId(_ customId: String) -> DiffComponentAction? {
    switch customId {
    case diffFileSelectCustomId: return .file
    case diffExpandAllCustomId: return .expandAll
    default: return nil
    }
}

func handleDiffComponent(
    client: any DiscordClient,
    payload: Interaction,
    comp: Interaction.MessageComponent,
    action: DiffComponentAction
) async {
    // The click happens inside the thread, so its channel id IS the registry key.
    let threadId = payload.channel_id?.rawValue ?? ""
    _ = try? await client.createInteractionResponse(
        id: payload.id,
        token: payload.token,
        payload: .deferredUpdateMessage()
    )
    guard let state = await DiffThreadRegistry.shared.get(threadId: threadId) else {
        _ = await createMessageWithRetry(
            client: client,
            channelId: ChannelSnowflake(threadId),
            payload: .init(content: I18n.t("diff.expired"))
        )
        return
    }

    let selected: [GitChangedFile]
    switch action {
    case .expandAll:
        selected = state.files
    case .file:
        guard let raw = (comp.values ?? []).first,
              let index = Int(raw), state.files.indices.contains(index)
        else { return }
        selected = [state.files[index]]
    }

    for file in selected {
        let body = formatFileDiffBody(file: file, diff: await gitFileDiff(cwd: state.cwd, file: file))
        for chunk in DiscordText.chunkMessage(body) {
            _ = await createMessageWithRetry(
                client: client,
                channelId: ChannelSnowflake(threadId),
                payload: .init(content: chunk)
            )
        }
    }
}
