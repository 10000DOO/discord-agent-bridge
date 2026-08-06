import Foundation

// MARK: - WO-10 (design_orchestration_module_agents.md): one-shot start spec card
//
// Single-screen card — no step state machine (D15): 4 dropdowns (orchestrator model/effort,
// module model/effort) + Start/Cancel on one row. Every non-terminal interaction re-renders the
// same card; Start populates `confirmed` (DabMain does everything else — provisioning, install,
// index, mode enable, binding patch); Cancel just clears the card. Mirrors `ResumeWizard.swift`
// (get/put/remove/enqueue registry shape, `WizardView` render type) — 4장 참조 패턴.

public struct OrchestrationSpec: Sendable, Equatable {
    public var orchestratorModel: String
    public var orchestratorEffort: String
    public var moduleModel: String
    public var moduleEffort: String

    public init(
        orchestratorModel: String,
        orchestratorEffort: String,
        moduleModel: String,
        moduleEffort: String
    ) {
        self.orchestratorModel = orchestratorModel
        self.orchestratorEffort = orchestratorEffort
        self.moduleModel = moduleModel
        self.moduleEffort = moduleEffort
    }
}

/// D16: the card only ever offers Claude models — never opens for a non-Claude-bound lead channel
/// (2-2 scope: Claude backend only; this guard didn't exist before WO-10).
public func orchestrationCardAllowed(backend: Backend) -> Bool {
    backend == .claude
}

/// One-shot card — drop down 4 + [시작]/[취소]. Internal `Phase` is a 3-state completion flag,
/// not a `WizardStep` state machine (D15) — it only decides what the next `render()` shows.
public final class OrchestrationWizard: @unchecked Sendable {
    private enum Phase {
        case open
        case confirmed
        case cancelled
    }

    private let options: WizardOptionSource
    private var spec: OrchestrationSpec
    private var phase: Phase = .open

    /// Filled only by `orch:start`; stays nil while the card is open or once cancelled.
    public private(set) var confirmed: OrchestrationSpec?

    public init(options: WizardOptionSource, initial: OrchestrationSpec) {
        self.options = options
        self.spec = initial
    }

    /// Advance by one select/button. Unknown ids and input after a terminal phase are ignored.
    public func handle(customId: String, values: [String]) async {
        guard phase == .open else { return }
        switch customId {
        case "orch:omodel":
            if let v = values.first { spec.orchestratorModel = v }
        case "orch:oeffort":
            if let v = values.first { spec.orchestratorEffort = v }
        case "orch:mmodel":
            if let v = values.first { spec.moduleModel = v }
        case "orch:meffort":
            if let v = values.first { spec.moduleEffort = v }
        case "orch:start":
            confirmed = spec
            phase = .confirmed
        case "orch:cancel":
            phase = .cancelled
        default:
            break
        }
    }

    public func render() -> WizardView {
        let title = I18n.t("orchestration.wizard.title")
        switch phase {
        case .cancelled:
            return WizardView(title: title, description: I18n.t("orchestration.wizard.cancelled"), rows: [])
        case .confirmed:
            // The real summary (category/install/index/applied spec) is posted separately by
            // DabMain once the [시작] handler's provisioning finishes (mirrors ResumeWizard's
            // `.done` case — the router edits the message again after this render is shown).
            return WizardView(title: title, description: I18n.t("orchestration.wizard.confirmed"), rows: [])
        case .open:
            let leadTag = I18n.t("orchestration.wizard.tag.lead")
            let moduleTag = I18n.t("orchestration.wizard.tag.module")
            return WizardView(
                title: title,
                description: I18n.t("orchestration.wizard.description"),
                rows: [
                    WizardRow(components: [.select(
                        customId: "orch:omodel",
                        placeholder: I18n.t("orchestration.wizard.omodel"),
                        options: capSelectOptions(options.models(for: .claude).map {
                            WizardSelectOption(
                                label: taggedOptionLabel(modelOptionLabel($0), tag: leadTag),
                                value: $0.value,
                                isDefault: $0.value == spec.orchestratorModel,
                                description: modelOptionDescription($0)
                            )
                        })
                    )]),
                    WizardRow(components: [.select(
                        customId: "orch:oeffort",
                        placeholder: I18n.t("orchestration.wizard.oeffort"),
                        options: capSelectOptions(options.efforts(for: .claude, model: spec.orchestratorModel).map {
                            WizardSelectOption(
                                label: taggedOptionLabel($0.label, tag: leadTag),
                                value: $0.value,
                                isDefault: $0.value == spec.orchestratorEffort
                            )
                        })
                    )]),
                    WizardRow(components: [.select(
                        customId: "orch:mmodel",
                        placeholder: I18n.t("orchestration.wizard.mmodel"),
                        options: capSelectOptions(options.models(for: .claude).map {
                            WizardSelectOption(
                                label: taggedOptionLabel(modelOptionLabel($0), tag: moduleTag),
                                value: $0.value,
                                isDefault: $0.value == spec.moduleModel,
                                description: modelOptionDescription($0)
                            )
                        })
                    )]),
                    WizardRow(components: [.select(
                        customId: "orch:meffort",
                        placeholder: I18n.t("orchestration.wizard.meffort"),
                        options: capSelectOptions(options.efforts(for: .claude, model: spec.moduleModel).map {
                            WizardSelectOption(
                                label: taggedOptionLabel($0.label, tag: moduleTag),
                                value: $0.value,
                                isDefault: $0.value == spec.moduleEffort
                            )
                        })
                    )]),
                    WizardRow(components: [
                        .button(customId: "orch:start", label: I18n.t("wizard.start"), style: .success, disabled: false),
                        .button(customId: "orch:cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false),
                    ]),
                ]
            )
        }
    }
}

// MARK: Option label tagging (this card only)
//
// Discord's select component hides `placeholder` once an option is preselected (`isDefault`),
// which every option here always is — so without a per-option marker, the 총괄/모듈 distinction
// the placeholder used to carry disappears entirely from the rendered card. Prefixing the option
// label itself survives that (bug report: real Discord card showed 4 bare values with no way to
// tell which dropdown was which). Local to this file — `modelOptionLabel`/`modelOptionDescription`
// (`ProviderCatalog.swift`) stay untouched since `ChannelWizard`'s single-select-per-step model
// step shares them and never has this ambiguity.
private func taggedOptionLabel(_ label: String, tag: String) -> String {
    "\(tag) · \(label)"
}

// MARK: Component id recognition (DabMain routing)

/// Distinct `orch:` namespace so this card never collides with the `/agent start` wizard's
/// `WizardRegistry` dispatch on the same channel (8장 11번).
public func isOrchestrationWizardCustomId(_ customId: String) -> Bool {
    customId.hasPrefix("orch:")
}

// MARK: [시작] result line (DabMain's orch:start branch)

/// R10 step 5's summary line for the lead model/effort patch. Category/install/index have
/// already succeeded by the time this runs, so a patch failure only means "the model/effort
/// didn't take" — never the whole command — hence a dedicated failure line instead of silently
/// showing `appliedSpec` regardless of `BindingUpdateResult` (review fix, WO-10). Pure so
/// DabMain's message choice is unit-testable without a Discord harness.
public func orchestrationAppliedSpecLine(_ result: BindingUpdateResult, spec: OrchestrationSpec) -> String {
    switch result {
    case .ok:
        return I18n.t("orchestration.wizard.appliedSpec", [
            "model": modelDisplayText(spec.orchestratorModel),
            "effort": spec.orchestratorEffort,
            "moduleModel": modelDisplayText(spec.moduleModel),
            "moduleEffort": spec.moduleEffort,
        ])
    case .noBinding, .invalidEffort, .applyFailed, .persistFailed:
        return I18n.t("orchestration.wizard.appliedSpecFailed", [
            "model": modelDisplayText(spec.orchestratorModel),
            "effort": spec.orchestratorEffort,
        ])
    }
}

// MARK: In-memory registry (parallel to ResumeWizardRegistry / WizardRegistry)

/// channelId → active orchestration start card.
public actor OrchestrationWizardRegistry {
    public static let shared = OrchestrationWizardRegistry()
    private var cards: [String: OrchestrationWizard] = [:]

    public init() {}

    public func put(_ wizard: OrchestrationWizard, channelId: String) {
        cards[channelId] = wizard
    }

    public func get(channelId: String) -> OrchestrationWizard? {
        cards[channelId]
    }

    public func remove(channelId: String) {
        cards[channelId] = nil
    }

    private var queues: [String: Task<Void, Never>] = [:]

    /// Same shape as `ResumeWizardRegistry.enqueue` (`ResumeWizard.swift:339`) — serializes
    /// concurrent component clicks on the same channel so two clicks never interleave
    /// `OrchestrationWizard.handle`/`render`, and a fast double-click on `orch:start` can't fire
    /// the provisioning/install block twice.
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
