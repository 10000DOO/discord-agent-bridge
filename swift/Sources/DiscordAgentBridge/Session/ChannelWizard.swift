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
    /// Named permission profile picked in the perm step's quick-select, or nil for raw mode (C3).
    public var profile: String?

    public init(
        guildId: String,
        channelId: String,
        backend: Backend,
        cwd: String,
        ownerId: String,
        model: String,
        effort: String,
        permMode: String,
        profile: String? = nil
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.backend = backend
        self.cwd = cwd
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.profile = profile
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
         "perm.mode", "perm.profile", "perm.start",
         "preset.pick", "preset.direct", "preset.delete",
         "wizard.back", "cancel":
        return true
    default:
        return false
    }
}

/// Discord option description clamp (select description max 100).
/// The stored model is an alias; show the concrete wire id it names right now.
public func summarizePreset(_ p: Preset) -> String {
    let model = p.model.map(modelDisplayText) ?? "-"
    let raw = "\(p.backend) · \(model) · \(p.effort ?? "-") · \(p.profile ?? p.permMode ?? "-")"
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
        let models = [ModelChoice(value: providerDefaultModelSelection, label: "provider default (latest)")]
            + (await cat.models(configured: nil))
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
    let perms = permsFor[defaultBackend] ?? []
    let defaults = WizardDefaults(
        backend: defaultBackend,
        model: providerDefaultModelSelection,
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
    /// Named permission profile picked via the perm step's quick-select, or nil for raw mode (C3).
    public var profile: String? = nil
}

/// Seed for `/mode backend` reconfigure popup: skip folder/backend, open at model.
/// `model`/`effort` omitted → seeded from the NEW backend's catalog defaults.
public struct WizardEntry: Sendable, Equatable {
    public var backend: Backend
    public var cwd: String
    public var permMode: String
    /// Existing binding's permission profile, carried over as-is (nil = raw mode) (C3).
    public var profile: String?
    public var model: String?
    public var effort: String?

    public init(
        backend: Backend,
        cwd: String,
        permMode: String,
        profile: String? = nil,
        model: String? = nil,
        effort: String? = nil
    ) {
        self.backend = backend
        self.cwd = cwd
        self.permMode = permMode
        self.profile = profile
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
    /// Named permission profiles offered as the perm step's quick-select (C3). Empty → raw-only,
    /// same as before this feature (WO-7 passes `Array(config.profiles.keys)`).
    private let profileNames: [String]
    /// Side-effect on delete (router persists to ConfigStore, returns disk-truth preset list).
    /// Nil (tests) → local filter fallback.
    private let onDeletePreset: ((String) async -> [Preset])?
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
        /// Pending profile pick (`perm.profile`); mutually exclusive with `permMode` — whichever
        /// select the driver touches last wins (mirrors TS's single `pending.perm` slot).
        var profile: String?
    }

    public init(
        guildId: String,
        channelId: String,
        ownerId: String,
        browser: DirectoryBrowser,
        options: WizardOptionSource,
        entry: WizardEntry? = nil,
        presets: [Preset] = [],
        profileNames: [String] = [],
        onDeletePreset: ((String) async -> [Preset])? = nil,
        summarizePreset: ((Preset) -> String)? = nil,
        backendAvailable: ((String) -> Bool)? = nil
    ) {
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.browser = browser
        self.options = options
        self.presets = presets
        self.profileNames = profileNames
        self.onDeletePreset = onDeletePreset
        self.summarizePresetFn = summarizePreset
        self.backendAvailable = backendAvailable
        if let entry {
            // Reconfigure (backend switch): skip folder/preset/backend, start at model.
            // backend/cwd/permMode/profile carry over; model/effort seed from caller or new-backend defaults.
            self.kind = .reconfigure
            self.firstStep = .model
            self.step = .model
            self.selection = WizardSelection(
                cwd: entry.cwd,
                backend: entry.backend,
                model: entry.model ?? providerDefaultModelSelection,
                effort: entry.effort ?? options.defaultEffort(for: entry.backend),
                permMode: entry.permMode,
                profile: entry.profile
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
                permMode: d.permMode,
                // No config-level default profile is surfaced to the wizard yet — raw until the
                // driver picks one (perm.profile) or a preset seeds it.
                profile: nil
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
        profileNames: [String] = [],
        onDeletePreset: ((String) async -> [Preset])? = nil,
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
            profileNames: profileNames,
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
    public func handle(_ input: WizardInput) async -> WizardStep {
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
        case .preset: await handlePreset(input)
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
    private func handlePreset(_ input: WizardInput) async {
        // Recompute unavailable notice per interaction (only re-set when a pick is blocked).
        presetUnavailable = nil
        if input.id == "preset.direct" {
            step = .backend
        } else if input.id == "preset.delete" {
            presetDeleteMode.toggle()
        } else if input.id == "preset.pick", let name = input.value, !name.isEmpty {
            if presetDeleteMode {
                if let onDeletePreset {
                    presets = await onDeletePreset(name)
                } else {
                    presets.removeAll { $0.name == name }
                }
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
            selection.model = picked.model ?? providerDefaultModelSelection
            selection.effort = picked.effort ?? options.defaultEffort(for: backend)
            selection.permMode = picked.permMode ?? options.defaults.permMode
            selection.profile = picked.profile
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
            permMode: selection.permMode,
            profile: selection.profile
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

    /// `perm.profile` (quick-select) and `perm.mode` (raw) are mutually exclusive — picking one
    /// clears any pending pick on the other, so whichever the driver touched last wins on commit
    /// (mirrors TS's single `pending.perm` slot with `profile:`/`mode:` prefixes).
    private func handlePerm(_ input: WizardInput) {
        if input.id == "perm.profile", let v = input.value {
            pending.profile = v
            pending.permMode = nil
        } else if input.id == "perm.mode", let v = input.value {
            pending.permMode = v
            pending.profile = nil
        } else if input.id == "perm.start" {
            if let p = pending.profile {
                // "__raw__" is the explicit advanced-option sentinel (TS parity) — an explicit
                // opt-out of the profile quick-select, not "no pick".
                selection.profile = p == "__raw__" ? nil : p
                pending.profile = nil
            } else if let m = pending.permMode {
                selection.permMode = m
                selection.profile = nil
                pending.permMode = nil
            }
            commitStart()
        }
    }

    private func applyBackend(_ backend: Backend) {
        selection.backend = backend
        selection.model = providerDefaultModelSelection
        selection.effort = options.defaultEffort(for: backend)
        let perms = options.perms(for: backend)
        selection.permMode = perms.first?.value ?? selection.permMode
        selection.profile = nil
        pending = Pending()
    }

    private func hasEffortStep() -> Bool {
        !options.efforts(for: selection.backend, model: selection.model).isEmpty
    }

    // MARK: Render

    private func titleText() -> String {
        kind == .reconfigure
            ? I18n.t("wizard.recfg.title", ["backend": selection.backend.rawValue])
            : I18n.t("wizard.title")
    }

    private func stepDescription(_ step: WizardStep) -> String {
        switch step {
        case .model:
            return I18n.t(kind == .reconfigure ? "wizard.recfg.step.model" : "wizard.step.model")
        case .effort:
            return I18n.t(kind == .reconfigure ? "wizard.recfg.step.effort" : "wizard.step.effort")
        case .perm:
            return I18n.t(kind == .reconfigure ? "wizard.recfg.step.perm" : "wizard.step.perm")
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
                description: I18n.t("wizard.step.backend"),
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
                confirmLabel: I18n.t("wizard.next"),
                showBack: showBackButton()
            )
        case .model:
            let selected = pending.model ?? selection.model
            return choiceStep(
                title: title,
                description: stepDescription(.model),
                selectId: "model",
                options: options.models(for: selection.backend).map { m in
                    // First line names the concrete wire id, second line the friendly name + blurb.
                    WizardSelectOption(
                        label: modelOptionLabel(m),
                        value: m.value,
                        isDefault: m.value == selected,
                        description: modelOptionDescription(m)
                    )
                },
                confirmId: "model.next",
                confirmLabel: I18n.t("wizard.next"),
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
                confirmLabel: I18n.t("wizard.next"),
                showBack: showBackButton()
            )
        case .perm:
            let selected = pending.permMode ?? selection.permMode
            var rows: [WizardRow] = []
            // Quick-select: config.profiles names + an explicit "advanced" opt-out (C3). Only
            // shown when the guild has ≥1 registered profile (WO-7 injects `profileNames`).
            if !profileNames.isEmpty {
                let selectedProfile = pending.profile ?? selection.profile
                let profileOpts = capSelectOptions(
                    profileNames.map { name in
                        WizardSelectOption(label: name, value: name, isDefault: name == selectedProfile)
                    } + [
                        WizardSelectOption(
                            label: I18n.t("wizard.profile.advanced"),
                            value: "__raw__",
                            isDefault: selectedProfile == nil
                        ),
                    ]
                )
                if !profileOpts.isEmpty {
                    rows.append(WizardRow(components: [
                        .select(customId: "perm.profile", placeholder: I18n.t("wizard.step.perm"), options: profileOpts),
                    ]))
                }
            }
            let modeOpts = capSelectOptions(
                options.perms(for: selection.backend).map { p in
                    WizardSelectOption(label: p.label, value: p.value, isDefault: p.value == selected)
                }
            )
            if !modeOpts.isEmpty {
                // Placeholder names it as the manual/advanced path once the quick-select exists (TS parity).
                rows.append(WizardRow(components: [
                    .select(customId: "perm.mode", placeholder: I18n.t("wizard.profile.advanced"), options: modeOpts),
                ]))
            }
            let startLabel = kind == .reconfigure ? I18n.t("wizard.recfg.start") : I18n.t("wizard.start")
            var buttons: [WizardComponent] = [
                .button(customId: "perm.start", label: startLabel, style: .success, disabled: false),
            ]
            if showBackButton() {
                buttons.append(.button(customId: "wizard.back", label: I18n.t("wizard.back"), style: .secondary, disabled: false))
            }
            buttons.append(.button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false))
            rows.append(WizardRow(components: buttons))
            return WizardView(title: title, description: stepDescription(.perm), rows: rows)
        case .done:
            return WizardView(
                title: title,
                description: I18n.t("wizard.started", ["backend": selection.backend.rawValue, "cwd": selection.cwd]),
                rows: []
            )
        case .cancelled:
            let cancelled = I18n.t(kind == .reconfigure ? "wizard.recfg.cancelled" : "wizard.cancelled")
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
            let placeholder = presetDeleteMode ? I18n.t("preset.delete.active") : I18n.t("preset.pick.placeholder")
            rows.append(WizardRow(components: [
                .select(customId: "preset.pick", placeholder: placeholder, options: Array(opts)),
            ]))
        }
        var buttons: [WizardComponent] = [
            .button(customId: "preset.direct", label: I18n.t("preset.direct"), style: .primary, disabled: false),
            .button(customId: "preset.delete", label: I18n.t("preset.delete.button"), style: .secondary, disabled: false),
        ]
        if showBackButton() {
            buttons.append(.button(customId: "wizard.back", label: I18n.t("wizard.back"), style: .secondary, disabled: false))
        }
        buttons.append(.button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false))
        rows.append(WizardRow(components: buttons))
        var base = presetDeleteMode ? I18n.t("preset.delete.active") : I18n.t("preset.step.pick")
        if let unavailable = presetUnavailable {
            base += "\n" + I18n.t("preset.backend.unavailable", ["backend": unavailable])
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
            buttons.append(.button(customId: "wizard.back", label: I18n.t("wizard.back"), style: .secondary, disabled: false))
        }
        buttons.append(.button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false))
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

    private var queues: [String: Task<Void, Never>] = [:]

    /// Chain a wizard-handling job onto the per-channel queue so concurrent component
    /// interactions on the same channel never interleave (TS `enqueueWizard`, `router.ts:378-390`).
    /// Mirrors the existing `eventChains`/`notifyChains` per-key Task-chaining pattern
    /// (`DabSessionBridge.swift`/`CodexSessionBridge.swift`) — no drained-entry cleanup, same as those.
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
