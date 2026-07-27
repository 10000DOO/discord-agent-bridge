import Foundation

// MARK: - W11-b2 residual: pure "Resume Session" wizard (TS resumeWizard.ts parity)
//
// Two-step SM started from the folder step's `dir:resume` button:
//   backend → pick backend (select + 다음)
//   pick    → pick a resumable session (select RESUMES immediately)
// Terminal: done | cancelled | empty
//
// No Discord types. listResumableFor + resume are injected (DabMain wires Claude
// sidecar sessions.list; Codex/Grok best-effort store or empty).

// MARK: Types

public enum ResumeStep: String, Sendable, Equatable {
    case backend
    case pick
    case done
    case cancelled
    case empty
}

public struct ResumeParams: Sendable, Equatable {
    public var guildId: String
    public var channelId: String
    public var ownerId: String
    public var backend: Backend
    public var cwd: String
    public var sessionId: String

    public init(
        guildId: String,
        channelId: String,
        ownerId: String,
        backend: Backend,
        cwd: String,
        sessionId: String
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.backend = backend
        self.cwd = cwd
        self.sessionId = sessionId
    }
}

public struct ResumeResult: Sendable, Equatable {
    /// Channel the resumed session is bound to (current channel until A4D create lands).
    public var channelId: String
    public init(channelId: String) { self.channelId = channelId }
}

public typealias ResumeListFn = @Sendable (Backend, String) async -> [ResumableSession]
public typealias ResumeFn = @Sendable (ResumeParams) async throws -> ResumeResult

public struct ResumeWizardOptions: Sendable {
    public var guildId: String
    public var channelId: String
    public var ownerId: String
    /// Folder in view on the folder step; listResumable is scoped to it.
    public var cwd: String
    public var backends: [Backend]
    public var defaultBackend: Backend
    public var listResumableFor: ResumeListFn
    public var resume: ResumeFn
    /// Render relative time for option description (injectable for tests).
    public var relativeTime: @Sendable (String?) -> String

    public init(
        guildId: String,
        channelId: String,
        ownerId: String,
        cwd: String,
        backends: [Backend] = Backend.allCases,
        defaultBackend: Backend = .claude,
        listResumableFor: @escaping ResumeListFn,
        resume: @escaping ResumeFn,
        relativeTime: @escaping @Sendable (String?) -> String = { resumeRelativeTime($0) }
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.cwd = cwd
        self.backends = backends
        self.defaultBackend = defaultBackend
        self.listResumableFor = listResumableFor
        self.resume = resume
        self.relativeTime = relativeTime
    }
}

// MARK: State machine

public final class ResumeWizard: @unchecked Sendable {
    private let opts: ResumeWizardOptions
    private var step: ResumeStep = .backend
    private var selectedBackend: Backend
    private var pendingBackend: Backend?
    private var sessions: [ResumableSession] = []
    private var resumedChannelId: String?
    /// Set when `opts.resume` throws; surfaced in the next `.pick` render (H9).
    private var lastResumeError: String?

    public let ownerId: String

    public init(options: ResumeWizardOptions) {
        self.opts = options
        self.ownerId = options.ownerId
        self.selectedBackend = options.defaultBackend
    }

    public func currentStep() -> ResumeStep { step }

    /// Channel bound on successful resume, else nil.
    public func sessionChannelId() -> String? { resumedChannelId }

    /// Advance by one select/button. Unknown ids for the current step are ignored.
    ///   resume.backend        select → pending + re-render
    ///   resume.backend.next   button → commit, list, → pick | empty
    ///   resume.pick           select → RESUME chosen session → done
    ///   cancel                button → cancelled
    @discardableResult
    public func handle(_ input: WizardInput) async -> ResumeStep {
        if input.id == "cancel" {
            step = .cancelled
            return step
        }
        switch step {
        case .backend:
            if input.id == "resume.backend", let raw = input.value, let b = Backend(rawValue: raw) {
                pendingBackend = b
            } else if input.id == "resume.backend.next" {
                selectedBackend = pendingBackend ?? selectedBackend
                pendingBackend = nil
                sessions = await opts.listResumableFor(selectedBackend, opts.cwd)
                step = sessions.isEmpty ? .empty : .pick
            }
        case .pick:
            if input.id == "resume.pick", let sid = input.value {
                await resumeSession(sid)
            }
        case .done, .cancelled, .empty:
            break
        }
        return step
    }

    private func resumeSession(_ sessionId: String) async {
        guard sessions.contains(where: { $0.sessionId == sessionId }) else { return }
        lastResumeError = nil
        do {
            let result = try await opts.resume(ResumeParams(
                guildId: opts.guildId,
                channelId: opts.channelId,
                ownerId: opts.ownerId,
                backend: selectedBackend,
                cwd: opts.cwd,
                sessionId: sessionId
            ))
            resumedChannelId = result.channelId
            step = .done
        } catch {
            // Stay on pick so the user can try another session; surface the failure
            // on the next render (TS resumeWizard.ts:115-128 relies on guarded() for
            // this — Swift's handle() doesn't throw, so the wizard shows it itself).
            lastResumeError = I18n.t("cmd.error", ["error": error.localizedDescription])
        }
    }

    public func render() -> WizardView {
        // TS `resumeWizard.ts`: every non-done step shares the generic 'wizard.title'.
        let title = I18n.t("wizard.title")
        switch step {
        case .backend:
            let selected = pendingBackend ?? selectedBackend
            let options = opts.backends.map { b in
                WizardSelectOption(
                    label: b == .custom ? customBackendLabel() : b.rawValue,
                    value: b.rawValue,
                    isDefault: b == selected
                )
            }
            return WizardView(
                title: title,
                description: I18n.t("resume.step.backend"),
                rows: [
                    WizardRow(components: [
                        .select(
                            customId: "resume.backend",
                            placeholder: I18n.t("resume.step.backend"),
                            options: capSelectOptions(options)
                        ),
                    ]),
                    WizardRow(components: [
                        .button(customId: "resume.backend.next", label: I18n.t("wizard.next"), style: .primary, disabled: false),
                        .button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false),
                    ]),
                ]
            )
        case .pick:
            // WizardSelectOption has no description field — surface relative time in the label.
            let pickOptions = sessions.prefix(25).map { s -> WizardSelectOption in
                let time = opts.relativeTime(s.updatedAt)
                let base = clipResumeLabel(s.label ?? s.sessionId, 95)
                let label = time.isEmpty ? base : clipResumeLabel("\(base) · \(time)", 95)
                return WizardSelectOption(label: label, value: s.sessionId, isDefault: false)
            }
            var description = I18n.t("resume.step.pick")
            if let lastResumeError {
                description = "\(lastResumeError)\n\(description)"
            }
            return WizardView(
                title: title,
                description: description,
                rows: [
                    WizardRow(components: [
                        .select(
                            customId: "resume.pick",
                            placeholder: I18n.t("resume.select.placeholder"),
                            options: capSelectOptions(Array(pickOptions))
                        ),
                    ]),
                    WizardRow(components: [
                        .button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false),
                    ]),
                ]
            )
        case .empty:
            return WizardView(title: title, description: I18n.t("resume.none"), rows: [])
        case .done:
            // TS renders this with an always-blank {channel} (the real bound-channel
            // confirmation is posted separately by the router — DabMain.swift:1250).
            return WizardView(
                title: I18n.t("resume.status.title"),
                description: I18n.t("resume.done", ["channel": ""]),
                rows: []
            )
        case .cancelled:
            return WizardView(title: title, description: I18n.t("wizard.cancelled"), rows: [])
        }
    }
}

// MARK: Relative time (TS helpers.relativeTime)

/// Short relative time for resume picker option labels. Absent/unparseable → "".
public func resumeRelativeTime(
    _ updatedAt: String?,
    now: Date = Date()
) -> String {
    guard let updatedAt, !updatedAt.isEmpty else { return "" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var then = formatter.date(from: updatedAt)
    if then == nil {
        formatter.formatOptions = [.withInternetDateTime]
        then = formatter.date(from: updatedAt)
    }
    guard let then else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(then)))
    if seconds < 60 { return I18n.t("resume.time.now") }
    let minutes = seconds / 60
    if minutes < 60 { return I18n.t("resume.time.min", ["n": "\(minutes)"]) }
    let hours = minutes / 60
    if hours < 24 { return I18n.t("resume.time.hour", ["n": "\(hours)"]) }
    return I18n.t("resume.time.day", ["n": "\(hours / 24)"])
}

// MARK: Store-backed list (Codex/Grok best-effort)

/// Best-effort resumable list from persisted channel rows (same backend + cwd, has backendSessionId).
public func listResumableFromStore(
    sessions: [String: PersistedSession],
    backend: Backend,
    cwd: String
) -> [ResumableSession] {
    let want = standardizedPath(cwd)
    var out: [ResumableSession] = []
    for s in sessions.values {
        guard s.backend == backend, !s.archived, let sid = s.backendSessionId, !sid.isEmpty else { continue }
        guard standardizedPath(s.cwd) == want else { continue }
        out.append(ResumableSession(
            sessionId: sid,
            cwd: s.cwd,
            label: sid,
            updatedAt: s.updatedAt
        ))
    }
    // Newest first (updatedAt ISO sorts lexicographically for standard format).
    out.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    return out
}

private func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}

private func clipResumeLabel(_ s: String, _ max: Int) -> String {
    guard s.count > max else { return s }
    return String(s.prefix(max - 1)) + "…"
}

// MARK: Component id recognition

/// custom_ids owned by the resume flow (DabMain routing).
public func isResumeWizardCustomId(_ customId: String) -> Bool {
    if customId == "dir:resume" { return true }
    if customId.hasPrefix("resume.") { return true }
    return false
}

// MARK: In-memory resume flow store (DabMain)

/// channelId → active resume wizard (parallel to WizardRegistry).
public actor ResumeWizardRegistry {
    public static let shared = ResumeWizardRegistry()
    private var flows: [String: ResumeWizard] = [:]

    public init() {}

    public func put(_ flow: ResumeWizard, channelId: String) {
        flows[channelId] = flow
    }

    public func get(channelId: String) -> ResumeWizard? {
        flows[channelId]
    }

    public func remove(channelId: String) {
        flows[channelId] = nil
    }

    private var queues: [String: Task<Void, Never>] = [:]

    /// Chain a resume-wizard job onto the per-channel queue so concurrent component
    /// interactions on the same channel never interleave `ResumeWizard.handle`/`render`
    /// (same rationale/shape as `WizardRegistry.enqueue`, `ChannelWizard.swift:898`).
    public func enqueue(channelId: String, _ job: @escaping @Sendable () async -> Void) async {
        let prev = queues[channelId]
        let next = Task {
            _ = await prev?.value
            await job()
        }
        queues[channelId] = next
        await next.value
    }
}
