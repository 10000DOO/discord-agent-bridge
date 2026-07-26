import Foundation

// MARK: - W11-b2: `/agent start` + `/mode backend` reconfigure select wizard
//
// Pure state machine — no Discord types. Steps:
//   start:       folder → [preset if any] → backend → model → [effort if any] → perm → done | cancelled
//   reconfigure: model → [effort if any] → perm → done | cancelled
//                (folder/preset/backend skipped; opened when /mode backend targets a different backend)
//
// Folder: dir:into / dir:up navigate immediately; dir:here commits cwd → preset (if guild has
// saved presets) or backend (R6: no presets → straight to backend).
// Preset: pick seeds selection + starts immediately; direct → backend; delete toggles remove mode.
// dir:create / dir:manual / dir:panel are handled outside the SM (modals / native panel
// in DabMain) via browserGoTo / browserCreate; they do not advance the wizard step.
// Choice steps: select onChange writes PENDING only; Next/Start commits and advances
// (Discord does not re-fire a select for the already-selected option).
// Option lists are injected at open from live `providerCatalog(for:)` — never hardcoded
// model/effort/perm vocabularies (Backend.allCases is the only fixed list).
//
// A4D session-channel create is wired in DabMain done path via `resolveSessionChannelId`
// + `createSessionChannel` (not inside this pure SM).
// dir:resume → separate ResumeWizard (W11-b2 residual, wired).

// MARK: Types

public enum WizardStep: String, Sendable, Equatable {
    case folder
    case preset
    case backend
    case model
    case effort
    case perm
    case done
    case cancelled
}

public struct WizardInput: Sendable, Equatable {
    public var id: String
    public var value: String?
    public init(id: String, value: String? = nil) {
        self.id = id
        self.value = value
    }
}

public struct WizardDefaults: Sendable, Equatable {
    public var backend: Backend
    public var model: String
    public var effort: String
    public var permMode: String
    public init(backend: Backend, model: String, effort: String, permMode: String) {
        self.backend = backend
        self.model = model
        self.effort = effort
        self.permMode = permMode
    }
}

/// Snapshot of per-backend option lists taken when the wizard opens.
public struct WizardOptionSource: Sendable, Equatable {
    public var backends: [Backend]
    public var modelsFor: [Backend: [ModelChoice]]
    public var permsFor: [Backend: [ModelChoice]]
    /// effortsFor[backend][modelValue] — empty array → skip effort step for that model.
    public var effortsFor: [Backend: [String: [ModelChoice]]]
    public var defaultEffortFor: [Backend: String]
    public var defaults: WizardDefaults

    public init(
        backends: [Backend] = Backend.allCases,
        modelsFor: [Backend: [ModelChoice]],
        permsFor: [Backend: [ModelChoice]],
        effortsFor: [Backend: [String: [ModelChoice]]],
        defaultEffortFor: [Backend: String],
        defaults: WizardDefaults
    ) {
        self.backends = backends
        self.modelsFor = modelsFor
        self.permsFor = permsFor
        self.effortsFor = effortsFor
        self.defaultEffortFor = defaultEffortFor
        self.defaults = defaults
    }

    public func models(for backend: Backend) -> [ModelChoice] {
        modelsFor[backend] ?? []
    }

    public func perms(for backend: Backend) -> [ModelChoice] {
        permsFor[backend] ?? []
    }

    public func efforts(for backend: Backend, model: String) -> [ModelChoice] {
        if let e = effortsFor[backend]?[model] { return e }
        return effortsFor[backend]?[""] ?? []
    }

    public func defaultEffort(for backend: Backend) -> String {
        defaultEffortFor[backend] ?? ""
    }
}

/// Params collected by the wizard for registry bind + store upsert.
public struct WizardStartParams: Sendable, Equatable {
    public var guildId: String
    public var channelId: String
    public var backend: Backend
    public var cwd: String
    public var ownerId: String
    public var model: String
    public var effort: String
    public var permMode: String

    public init(
        guildId: String,
        channelId: String,
        backend: Backend,
        cwd: String,
        ownerId: String,
        model: String,
        effort: String,
        permMode: String
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.backend = backend
        self.cwd = cwd
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
    }
}

// MARK: Render specs (Discord-agnostic; dab maps to DiscordBM)

public struct WizardSelectOption: Sendable, Equatable {
    public var label: String
    public var value: String
    public var isDefault: Bool
    /// Discord select option description (≤100 chars). Used by preset summaries.
    public var description: String?
    public init(label: String, value: String, isDefault: Bool = false, description: String? = nil) {
        self.label = label
        self.value = value
        self.isDefault = isDefault
        self.description = description
    }
}

public enum WizardButtonStyle: String, Sendable, Equatable {
    case primary
    case secondary
    case success
    case danger
}

public enum WizardComponent: Sendable, Equatable {
    case select(customId: String, placeholder: String, options: [WizardSelectOption])
    case button(customId: String, label: String, style: WizardButtonStyle, disabled: Bool)
}

public struct WizardRow: Sendable, Equatable {
    public var components: [WizardComponent]
    public init(components: [WizardComponent]) { self.components = components }
}

public struct WizardView: Sendable, Equatable {
    public var title: String
    public var description: String
    public var rows: [WizardRow]
    public init(title: String, description: String, rows: [WizardRow]) {
        self.title = title
        self.description = description
        self.rows = rows
    }
}

// MARK: Component id recognition (for DabMain routing)

/// Custom ids owned by the agent-start wizard (folder + select steps). Distinct from `perm:<req>:<action>`.
/// Includes resume-flow ids so DabMain can dispatch before generic handlers.
public func isWizardCustomId(_ customId: String) -> Bool {
    if isDirectoryBrowserCustomId(customId) { return true }
    if isResumeWizardCustomId(customId) { return true }
    switch customId {
    case "backend", "backend.next",
         "model", "model.next",
         "effort", "effort.next",
         "perm.mode", "perm.start",
         "preset.pick", "preset.direct", "preset.delete",
         "wizard.back", "cancel":
        return true
    default:
        return false
    }
}

/// Discord option description clamp (select description max 100).
public func summarizePreset(_ p: Preset) -> String {
    let raw = "\(p.backend) · \(p.model ?? "-") · \(p.effort ?? "-") · \(p.profile ?? p.permMode ?? "-")"
    if raw.count <= 100 { return raw }
    return String(raw.prefix(99)) + "…"
}

// MARK: Load options from live catalogs

/// Probe every backend's live catalog once (wizard open). Backends = `Backend.allCases` only fixed.
public func loadWizardOptionSource(
    catalogFor: (Backend) -> any ProviderCatalog = { providerCatalog(for: $0) }
) async -> WizardOptionSource {
    var modelsFor: [Backend: [ModelChoice]] = [:]
    var permsFor: [Backend: [ModelChoice]] = [:]
    var effortsFor: [Backend: [String: [ModelChoice]]] = [:]
    var defaultEffortFor: [Backend: String] = [:]

    for backend in Backend.allCases {
        let cat = catalogFor(backend)
        // Warm async catalog (Claude caches the snapshot for subsequent effortChoices).
        let models = await cat.models(configured: nil)
        modelsFor[backend] = models
        permsFor[backend] = await cat.permissionChoices()
        let defE = await cat.defaultEffort() ?? ""
        defaultEffortFor[backend] = defE

        var byModel: [String: [ModelChoice]] = [:]
        byModel[""] = cat.effortChoices(modelLevels: nil)
        for m in models {
            byModel[m.value] = cat.effortChoices(modelLevels: m.supportedEffortLevels)
        }
        effortsFor[backend] = byModel
    }

    let defaultBackend = Backend.claude
    let models = modelsFor[defaultBackend] ?? []
    let perms = permsFor[defaultBackend] ?? []
    let defaults = WizardDefaults(
        backend: defaultBackend,
        model: models.first?.value ?? "",
        effort: defaultEffortFor[defaultBackend] ?? "",
        permMode: perms.first?.value ?? "default"
    )
    return WizardOptionSource(
        backends: Backend.allCases,
        modelsFor: modelsFor,
        permsFor: permsFor,
        effortsFor: effortsFor,
        defaultEffortFor: defaultEffortFor,
        defaults: defaults
    )
}

/// Working directory for slice1: `DAB_CWD` if set/non-empty, else home.
public func wizardDefaultCwd(
    env: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory()
) -> String {
    if let v = env["DAB_CWD"], !v.isEmpty { return v }
    return home
}

// MARK: State machine

public struct WizardSelection: Sendable, Equatable {
    public var cwd: String
    public var backend: Backend
    public var model: String
    public var effort: String
    public var permMode: String
}

/// Seed for `/mode backend` reconfigure popup: skip folder/backend, open at model.
/// `model`/`effort` omitted → seeded from the NEW backend's catalog defaults.
public struct WizardEntry: Sendable, Equatable {
    public var backend: Backend
    public var cwd: String
    public var permMode: String
    public var model: String?
    public var effort: String?

    public init(
        backend: Backend,
        cwd: String,
        permMode: String,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.backend = backend
        self.cwd = cwd
        self.permMode = permMode
        self.model = model
        self.effort = effort
    }
}

public enum WizardKind: String, Sendable, Equatable {
    case start
    case reconfigure
}

/// Pure `/agent start` + reconfigure wizard (folder → [preset] → backend → model → effort → perm).
public final class ChannelWizard: @unchecked Sendable {
    public let guildId: String
    public let channelId: String
    public let ownerId: String
    private let options: WizardOptionSource
    private let browser: DirectoryBrowser
    private let kind: WizardKind
    private let firstStep: WizardStep
    private var step: WizardStep
    private var selection: WizardSelection
    private var pending: Pending = Pending()
    /// Snapshot of saved presets at open; shrinks on delete. Empty → no preset step (R6).
    private var presets: [Preset]
    /// Side-effect on delete (router persists to ConfigStore). Pure local filter always runs first.
    private let onDeletePreset: ((String) -> Void)?
    /// Optional formatter for select option descriptions. Nil → `summarizePreset`.
    private let summarizePresetFn: ((Preset) -> String)?
    /// Whether a preset's backend is still usable. Nil → no availability guard.
    private let backendAvailable: ((String) -> Bool)?
    /// Delete mode: a preset pick removes instead of launching. Toggled by 🗑.
    private var presetDeleteMode = false
    /// Set when the driver launched from a picked preset (skip "save as preset" on done).
    private var fromPreset = false
    /// Backend of a just-blocked unavailable preset pick (rendered as notice; cleared next action).
    private var presetUnavailable: String?
    /// Set when step becomes `.done` (perm.start or preset pick committed).
    public private(set) var startParams: WizardStartParams?

    private struct Pending {
        var backend: Backend?
        var model: String?
        var effort: String?
        var permMode: String?
    }

    public init(
        guildId: String,
        channelId: String,
        ownerId: String,
        browser: DirectoryBrowser,
        options: WizardOptionSource,
        entry: WizardEntry? = nil,
        presets: [Preset] = [],
        onDeletePreset: ((String) -> Void)? = nil,
        summarizePreset: ((Preset) -> String)? = nil,
        backendAvailable: ((String) -> Bool)? = nil
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.browser = browser
        self.options = options
        self.presets = presets
        self.onDeletePreset = onDeletePreset
        self.summarizePresetFn = summarizePreset
        self.backendAvailable = backendAvailable
        if let entry {
            // Reconfigure (backend switch): skip folder/preset/backend, start at model.
            // backend/cwd/permMode carry over; model/effort seed from caller or new-backend defaults.
            self.kind = .reconfigure
            self.firstStep = .model
            self.step = .model
            let models = options.models(for: entry.backend)
            self.selection = WizardSelection(
                cwd: entry.cwd,
                backend: entry.backend,
                model: entry.model ?? models.first?.value ?? options.defaults.model,
                effort: entry.effort ?? options.defaultEffort(for: entry.backend),
                permMode: entry.permMode
            )
        } else {
            self.kind = .start
            self.firstStep = .folder
            self.step = .folder
            let d = options.defaults
            self.selection = WizardSelection(
                cwd: browser.cwd(),
                backend: d.backend,
                model: d.model,
                effort: d.effort,
                permMode: d.permMode
            )
        }
    }

    /// Convenience: start browser at `cwd` (unbounded unless roots provided).
    public convenience init(
        guildId: String,
        channelId: String,
        ownerId: String,
        cwd: String,
        options: WizardOptionSource,
        allowedRoots: [String] = [],
        entry: WizardEntry? = nil,
        presets: [Preset] = [],
        onDeletePreset: ((String) -> Void)? = nil,
        summarizePreset: ((Preset) -> String)? = nil,
        backendAvailable: ((String) -> Bool)? = nil
    ) {
        self.init(
            guildId: guildId,
            channelId: channelId,
            ownerId: ownerId,
            browser: DirectoryBrowser(allowedRoots: allowedRoots, startPath: cwd),
            options: options,
            entry: entry,
            presets: presets,
            onDeletePreset: onDeletePreset,
            summarizePreset: summarizePreset,
            backendAvailable: backendAvailable
        )
    }

    public func currentStep() -> WizardStep { step }

    public func current() -> WizardSelection { selection }

    /// True when opened as the `/mode backend` cross-backend popup (same-channel restart on done).
    public func isReconfigure() -> Bool { kind == .reconfigure }

    /// True when the confirmed session was launched from a picked preset (skip save-as-preset).
    public func launchedFromPreset() -> Bool { fromPreset }

    /// Folder currently in the browser (manual/create/panel/resume).
    public func browserCwd() -> String { browser.cwd() }

    /// Jump browser to absolute path (manual modal / native panel / tests).
    @discardableResult
    public func browserGoTo(_ absPath: String) -> Bool { browser.goTo(absPath) }

    /// Create a child folder under the browsed cwd (create modal). Optionally enter it.
    public func browserCreate(_ name: String, enter: Bool = true) -> DirCreateResult {
        browser.createChild(name, enter: enter)
    }

    /// Advance by one select/button input. Unknown ids for the current step are ignored.
    @discardableResult
    public func handle(_ input: WizardInput) -> WizardStep {
        if input.id == "cancel" {
            step = .cancelled
            return step
        }
        if input.id == "wizard.back" {
            stepBack()
            return step
        }
        switch step {
        case .folder: handleFolder(input)
        case .preset: handlePreset(input)
        case .backend: handleBackend(input)
        case .model: handleModel(input)
        case .effort: handleEffort(input)
        case .perm: handlePerm(input)
        case .done, .cancelled: break
        }
        return step
    }

    private func stepBack() {
        // First step: start is a no-op; reconfigure cancels the backend-switch popup.
        if step == firstStep {
            if kind == .reconfigure { step = .cancelled }
            return
        }
        pending = Pending()
        switch step {
        case .preset:
            step = .folder
        case .backend:
            // Back from backend → preset when the guild still has presets, else folder (R6).
            step = hasPresetStep() ? .preset : .folder
        case .model:
            step = .backend
        case .effort:
            step = .model
        case .perm:
            step = hasEffortStep() ? .effort : .model
        default:
            break
        }
    }

    private func hasPresetStep() -> Bool { !presets.isEmpty }

    /// Folder nav: into/up re-render only; dir:here commits cwd → preset or backend.
    private func handleFolder(_ input: WizardInput) {
        if input.id == "dir:into", let v = input.value, v != "__none__", !v.isEmpty {
            _ = browser.into(v)
        } else if input.id == "dir:up" {
            _ = browser.up()
        } else if input.id == "dir:here" {
            // Clear stale unavailable notice when re-entering preset via folder (TS parity).
            presetUnavailable = nil
            selection.cwd = browser.select()
            step = hasPresetStep() ? .preset : .backend
        }
    }

    /// Preset step: pick (launch) / direct (manual backend) / delete-mode toggle.
    private func handlePreset(_ input: WizardInput) {
        // Recompute unavailable notice per interaction (only re-set when a pick is blocked).
        presetUnavailable = nil
        if input.id == "preset.direct" {
            step = .backend
        } else if input.id == "preset.delete" {
            presetDeleteMode.toggle()
        } else if input.id == "preset.pick", let name = input.value, !name.isEmpty {
            if presetDeleteMode {
                presets.removeAll { $0.name == name }
                onDeletePreset?(name)
                presetDeleteMode = false
                return
            }
            guard let picked = presets.first(where: { $0.name == name }) else { return }
            if let backendAvailable, !backendAvailable(picked.backend) {
                presetUnavailable = picked.backend
                return
            }
            guard let backend = Backend(rawValue: picked.backend) else {
                // Unparseable backend string — treat as unavailable without a callback.
                presetUnavailable = picked.backend
                return
            }
            selection.backend = backend
            selection.model = picked.model
                ?? options.models(for: backend).first?.value
                ?? selection.model
            selection.effort = picked.effort ?? options.defaultEffort(for: backend)
            selection.permMode = picked.permMode ?? options.defaults.permMode
            fromPreset = true
            commitStart()
        }
    }

    /// Commit selection into startParams and mark done (perm.start / preset pick).
    private func commitStart() {
        startParams = WizardStartParams(
            guildId: guildId,
            channelId: channelId,
            backend: selection.backend,
            cwd: selection.cwd,
            ownerId: ownerId,
            model: selection.model,
            effort: selection.effort,
            permMode: selection.permMode
        )
        step = .done
    }

    private func handleBackend(_ input: WizardInput) {
        if input.id == "backend", let raw = input.value, let b = Backend(rawValue: raw) {
            pending.backend = b
        } else if input.id == "backend.next" {
            let chosen = pending.backend ?? selection.backend
            if chosen != selection.backend { applyBackend(chosen) }
            pending.backend = nil
            step = .model
        }
    }

    private func handleModel(_ input: WizardInput) {
        if input.id == "model", let v = input.value {
            pending.model = v
        } else if input.id == "model.next" {
            selection.model = pending.model ?? selection.model
            pending.model = nil
            step = hasEffortStep() ? .effort : .perm
        }
    }

    private func handleEffort(_ input: WizardInput) {
        if input.id == "effort", let v = input.value {
            pending.effort = v
        } else if input.id == "effort.next" {
            selection.effort = pending.effort ?? selection.effort
            pending.effort = nil
            step = .perm
        }
    }

    private func handlePerm(_ input: WizardInput) {
        if input.id == "perm.mode", let v = input.value {
            pending.permMode = v
        } else if input.id == "perm.start" {
            if let p = pending.permMode {
                selection.permMode = p
                pending.permMode = nil
            }
            commitStart()
        }
    }

    private func applyBackend(_ backend: Backend) {
        selection.backend = backend
        let models = options.models(for: backend)
        selection.model = models.first?.value ?? selection.model
        selection.effort = options.defaultEffort(for: backend)
        let perms = options.perms(for: backend)
        selection.permMode = perms.first?.value ?? selection.permMode
        pending = Pending()
    }

    private func hasEffortStep() -> Bool {
        !options.efforts(for: selection.backend, model: selection.model).isEmpty
    }

    // MARK: Render

    private func titleText() -> String {
        kind == .reconfigure
            ? "에이전트 전환 — \(selection.backend.rawValue)"
            : "에이전트 세션 시작"
    }

    private func stepDescription(_ step: WizardStep) -> String {
        switch step {
        case .model:
            return kind == .reconfigure
                ? "1/3단계 · 모델을 선택하고 \"다음\"을 누르세요."
                : "모델을 선택하세요 (\(selection.backend.rawValue))"
        case .effort:
            return kind == .reconfigure
                ? "2/3단계 · 추론 수준을 선택하고 \"다음\"을 누르세요."
                : "추론 강도를 선택하세요"
        case .perm:
            return kind == .reconfigure
                ? "3/3단계 · 권한을 선택하고 \"✅ 전환\"을 누르세요."
                : "권한 모드를 선택하고 시작하세요"
        default:
            return ""
        }
    }

    /// Start: hide back on first (folder) step. Reconfigure: always show (first-step back cancels).
    private func showBackButton() -> Bool {
        !(step == firstStep && kind == .start)
    }

    public func render() -> WizardView {
        let title = titleText()
        switch step {
        case .folder:
            return browser.render()
        case .preset:
            return renderPresetStep(title: title)
        case .backend:
            return choiceStep(
                title: title,
                description: "백엔드를 선택하세요",
                selectId: "backend",
                options: options.backends.map { b in
                    WizardSelectOption(
                        // custom label names the operator's ANTHROPIC_MODEL when set (TS customBackendLabel).
                        label: b == .custom ? customBackendLabel() : b.rawValue,
                        value: b.rawValue,
                        isDefault: b == (pending.backend ?? selection.backend)
                    )
                },
                confirmId: "backend.next",
                confirmLabel: "다음",
                showBack: showBackButton()
            )
        case .model:
            let selected = pending.model ?? selection.model
            return choiceStep(
                title: title,
                description: stepDescription(.model),
                selectId: "model",
                options: options.models(for: selection.backend).map { m in
                    WizardSelectOption(label: m.label, value: m.value, isDefault: m.value == selected)
                },
                confirmId: "model.next",
                confirmLabel: "다음",
                showBack: showBackButton()
            )
        case .effort:
            let selected = pending.effort ?? selection.effort
            return choiceStep(
                title: title,
                description: stepDescription(.effort),
                selectId: "effort",
                options: options.efforts(for: selection.backend, model: selection.model).map { e in
                    WizardSelectOption(label: e.label, value: e.value, isDefault: e.value == selected)
                },
                confirmId: "effort.next",
                confirmLabel: "다음",
                showBack: showBackButton()
            )
        case .perm:
            let selected = pending.permMode ?? selection.permMode
            let modeOpts = capSelectOptions(
                options.perms(for: selection.backend).map { p in
                    WizardSelectOption(label: p.label, value: p.value, isDefault: p.value == selected)
                }
            )
            var rows: [WizardRow] = []
            if !modeOpts.isEmpty {
                rows.append(WizardRow(components: [
                    .select(customId: "perm.mode", placeholder: "권한 모드", options: modeOpts),
                ]))
            }
            let startLabel = kind == .reconfigure ? "✅ 전환" : "시작"
            var buttons: [WizardComponent] = [
                .button(customId: "perm.start", label: startLabel, style: .success, disabled: false),
            ]
            if showBackButton() {
                buttons.append(.button(customId: "wizard.back", label: "이전", style: .secondary, disabled: false))
            }
            buttons.append(.button(customId: "cancel", label: "취소", style: .secondary, disabled: false))
            rows.append(WizardRow(components: buttons))
            return WizardView(title: title, description: stepDescription(.perm), rows: rows)
        case .done:
            return WizardView(
                title: title,
                description: "시작됨: \(selection.backend.rawValue) · \(selection.cwd)",
                rows: []
            )
        case .cancelled:
            let cancelled = kind == .reconfigure
                ? "에이전트 전환을 취소했어요."
                : "취소되었습니다."
            return WizardView(title: title, description: cancelled, rows: [])
        }
    }

    /// Preset step: select of saved presets + 🆕 직접 설정 / 🗑 삭제 / back / cancel.
    private func renderPresetStep(title: String) -> WizardView {
        var rows: [WizardRow] = []
        if !presets.isEmpty {
            let summarize = summarizePresetFn ?? summarizePreset
            let opts = presets.prefix(25).map { p in
                WizardSelectOption(
                    label: p.name,
                    value: p.name,
                    isDefault: false,
                    description: summarize(p)
                )
            }
            let placeholder = presetDeleteMode ? "삭제할 프리셋을 선택하세요." : "프리셋 선택…"
            rows.append(WizardRow(components: [
                .select(customId: "preset.pick", placeholder: placeholder, options: Array(opts)),
            ]))
        }
        var buttons: [WizardComponent] = [
            .button(customId: "preset.direct", label: "🆕 직접 설정", style: .primary, disabled: false),
            .button(customId: "preset.delete", label: "🗑 삭제", style: .secondary, disabled: false),
        ]
        if showBackButton() {
            buttons.append(.button(customId: "wizard.back", label: "이전", style: .secondary, disabled: false))
        }
        buttons.append(.button(customId: "cancel", label: "취소", style: .secondary, disabled: false))
        rows.append(WizardRow(components: buttons))
        var base = presetDeleteMode ? "삭제할 프리셋을 선택하세요." : "프리셋을 선택하세요."
        if let unavailable = presetUnavailable {
            base += "\n이 프리셋의 백엔드(\(unavailable))를 지금은 쓸 수 없어요."
        }
        return WizardView(title: title, description: base, rows: rows)
    }

    private func choiceStep(
        title: String,
        description: String,
        selectId: String,
        options: [WizardSelectOption],
        confirmId: String,
        confirmLabel: String,
        showBack: Bool
    ) -> WizardView {
        let capped = capSelectOptions(options)
        var rows: [WizardRow] = []
        if !capped.isEmpty {
            rows.append(WizardRow(components: [
                .select(customId: selectId, placeholder: description, options: capped),
            ]))
        }
        var buttons: [WizardComponent] = [
            .button(customId: confirmId, label: confirmLabel, style: .primary, disabled: false),
        ]
        if showBack {
            buttons.append(.button(customId: "wizard.back", label: "이전", style: .secondary, disabled: false))
        }
        buttons.append(.button(customId: "cancel", label: "취소", style: .secondary, disabled: false))
        rows.append(WizardRow(components: buttons))
        return WizardView(title: title, description: description, rows: rows)
    }
}

// MARK: Select option cap (Discord ≤25)

func capSelectOptions(_ options: [WizardSelectOption]) -> [WizardSelectOption] {
    func clamp(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n))
    }
    let trimmed = options.map {
        let desc = $0.description.map { clamp($0, 100) }
        return WizardSelectOption(
            label: clamp($0.label, 100),
            value: clamp($0.value, 100),
            isDefault: $0.isDefault,
            description: desc
        )
    }
    if trimmed.count <= 25 { return trimmed }
    let selected = trimmed.first(where: \.isDefault)
    var capped = Array(trimmed.prefix(25))
    if let selected, !capped.contains(where: { $0.value == selected.value }) {
        capped = [selected] + Array(capped.prefix(24))
    }
    return capped
}

// MARK: In-memory wizard store (DabMain)

/// channelId → active agent-start wizard. One process-wide (EventHandler is recreated per event).
public actor WizardRegistry {
    public static let shared = WizardRegistry()
    private var wizards: [String: ChannelWizard] = [:]

    public init() {}

    public func put(_ wizard: ChannelWizard, channelId: String) {
        wizards[channelId] = wizard
    }

    public func get(channelId: String) -> ChannelWizard? {
        wizards[channelId]
    }

    public func remove(channelId: String) {
        wizards[channelId] = nil
    }
}

/// `"guildId:channelId"` → draft for "💾 프리셋으로 저장" after a normal (non-preset) start.
/// Persisted via `SessionStore` (`swift-state.json` `presetDrafts` field, C16) so a draft survives
/// a restart before the user taps "save as preset" — mirrors TS `state/store.ts` get/set/deletePresetDraft.
public actor PresetDraftRegistry {
    public static let shared = PresetDraftRegistry()

    public init() {}

    public static func key(guildId: String, channelId: String) -> String {
        "\(guildId):\(channelId)"
    }

    public func set(_ draft: PresetDraft, key: String) async {
        try? await SessionStore.shared.setPresetDraft(draft, key: key)
    }

    public func get(key: String) async -> PresetDraft? {
        await SessionStore.shared.presetDraft(key: key)
    }

    public func remove(key: String) async {
        try? await SessionStore.shared.removePresetDraft(key: key)
    }
}
