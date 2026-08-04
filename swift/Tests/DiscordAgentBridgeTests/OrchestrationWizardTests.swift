import Testing
import Foundation
@testable import DiscordAgentBridge

// WO-10 (design_orchestration_module_agents.md): pure OrchestrationWizard SM tests — no Discord,
// no ConfigStore/GuildChannels/OrchestrationInstaller/SessionLifecycle. The class has zero
// side-effecting dependencies injected (unlike ResumeWizard's `resume`/`listResumableFor`
// closures) — it only stores an `OrchestrationSpec` and flips a private `Phase`. Every call in
// this file that isn't `orch:start` is therefore, by construction, incapable of reaching
// `OrchestrationInstaller.installProject` / `ensureOrchestrationCategory` /
// `SessionLifecycle.enableOrchestrationMode` — those only run from DabMain's `orch:start` branch,
// entirely outside this type. `nonStartInteractionsNeverConfirm` below is the practical half of
// that proof (confirmed stays nil the whole time); the other half is that this file never
// imports/references those three symbols at all.

private let CLAUDE_MODELS = [
    ModelChoice(value: "opus", label: "opus", supportedEffortLevels: ["low", "medium", "high"]),
    ModelChoice(value: "sonnet", label: "sonnet", supportedEffortLevels: ["low", "medium", "high"]),
]
private let CLAUDE_EFFORTS = choices(["low", "medium", "high"])

private func fakeOptions() -> WizardOptionSource {
    WizardOptionSource(
        backends: [.claude],
        modelsFor: [.claude: CLAUDE_MODELS],
        permsFor: [.claude: [ModelChoice(value: "default", label: "default")]],
        effortsFor: [.claude: ["": CLAUDE_EFFORTS, "opus": CLAUDE_EFFORTS, "sonnet": CLAUDE_EFFORTS]],
        defaultEffortFor: [.claude: "medium"],
        defaults: WizardDefaults(backend: .claude, model: "opus", effort: "medium", permMode: "default")
    )
}

private func selectOptions(_ rows: [WizardRow], customId: String) -> [WizardSelectOption]? {
    rows.flatMap(\.components).compactMap { c -> [WizardSelectOption]? in
        if case .select(let id, _, let opts) = c, id == customId { return opts }
        return nil
    }.first
}

@Suite("OrchestrationWizard")
struct OrchestrationWizardTests {
    private func makeWizard(
        orchestratorModel: String = "opus",
        orchestratorEffort: String = "high",
        moduleModel: String = "opus",
        moduleEffort: String = "high"
    ) -> OrchestrationWizard {
        OrchestrationWizard(
            options: fakeOptions(),
            initial: OrchestrationSpec(
                orchestratorModel: orchestratorModel,
                orchestratorEffort: orchestratorEffort,
                moduleModel: moduleModel,
                moduleEffort: moduleEffort
            )
        )
    }

    // ① card render = 4 dropdowns + 1 button row = action rows ≤ 5 (Discord's hard cap, D15).
    @Test func renderIsFourDropdownsPlusOneButtonRowWithinActionRowCap() {
        let w = makeWizard()
        let view = w.render()
        #expect(view.rows.count == 5)

        let selectIds = view.rows.flatMap(\.components).compactMap { c -> String? in
            if case .select(let id, _, _) = c { return id }
            return nil
        }
        #expect(selectIds == ["orch:omodel", "orch:oeffort", "orch:mmodel", "orch:meffort"])

        let buttonIds = view.rows.last?.components.compactMap { c -> String? in
            if case .button(let id, _, _, _) = c { return id }
            return nil
        }
        #expect(buttonIds == ["orch:start", "orch:cancel"])
    }

    // ② pressing [시작] with no prior selection confirms the constructor's initial spec verbatim.
    @Test func startWithoutAnySelectionConfirmsInitialDefaults() async {
        let w = makeWizard(orchestratorModel: "sonnet", orchestratorEffort: "low", moduleModel: "opus", moduleEffort: "medium")
        await w.handle(customId: "orch:start", values: [])
        #expect(w.confirmed == OrchestrationSpec(
            orchestratorModel: "sonnet", orchestratorEffort: "low", moduleModel: "opus", moduleEffort: "medium"
        ))
    }

    // A select actually changes what [시작] confirms (otherwise ② would be vacuous).
    @Test func selectingThenStartingConfirmsTheNewValue() async {
        let w = makeWizard(orchestratorModel: "opus", orchestratorEffort: "high", moduleModel: "opus", moduleEffort: "high")
        await w.handle(customId: "orch:mmodel", values: ["sonnet"])
        await w.handle(customId: "orch:meffort", values: ["low"])
        await w.handle(customId: "orch:start", values: [])
        #expect(w.confirmed?.moduleModel == "sonnet")
        #expect(w.confirmed?.moduleEffort == "low")
        // Untouched fields keep their initial value.
        #expect(w.confirmed?.orchestratorModel == "opus")
    }

    // ③ [취소] ends the card with confirmed still nil, and further clicks are ignored.
    @Test func cancelLeavesConfirmedNilAndIgnoresFurtherInput() async {
        let w = makeWizard()
        await w.handle(customId: "orch:cancel", values: [])
        #expect(w.confirmed == nil)
        #expect(w.render().rows.isEmpty)
        #expect(w.render().description.contains("취소"))

        // Terminal — a stray late click (e.g. a second component event for the same interaction)
        // must not resurrect the card or populate confirmed.
        await w.handle(customId: "orch:start", values: [])
        #expect(w.confirmed == nil)
    }

    // ④ re-running `/dab-orchestration` seeds the module dropdowns from the previously saved set
    // (ServerConfig.orchestration[channel].moduleModel/moduleEffort), not from the lead's values —
    // DabMain builds `initial` that way; here we just confirm the wizard renders whatever it's given.
    @Test func rendersStoredModuleSpecAsInitialSelectionOnRerun() {
        let w = makeWizard(orchestratorModel: "opus", orchestratorEffort: "high", moduleModel: "sonnet", moduleEffort: "low")
        let view = w.render()

        let mmodel = selectOptions(view.rows, customId: "orch:mmodel")
        #expect(mmodel?.first(where: \.isDefault)?.value == "sonnet")
        let meffort = selectOptions(view.rows, customId: "orch:meffort")
        #expect(meffort?.first(where: \.isDefault)?.value == "low")

        // Lead dropdowns are unaffected — they default from the lead's own values.
        let omodel = selectOptions(view.rows, customId: "orch:omodel")
        #expect(omodel?.first(where: \.isDefault)?.value == "opus")
    }

    // UX fix: Discord hides a select's placeholder once an option is preselected (every option
    // here always has one via `isDefault`), so the 총괄/모듈 distinction the placeholder used to
    // carry was invisible on the real card — all 4 dropdowns showed bare values with no way to
    // tell which was which. The option label itself must now carry that distinction, even when
    // the lead and module side share the exact same underlying catalog (same `value`s, same
    // `label`s here — `CLAUDE_MODELS`/`CLAUDE_EFFORTS` above are reused for both).
    @Test func leadAndModuleOptionLabelsCarryDistinctTagsForTheSameValue() {
        let w = makeWizard()
        let view = w.render()

        let omodel = selectOptions(view.rows, customId: "orch:omodel")
        let mmodel = selectOptions(view.rows, customId: "orch:mmodel")
        let oLabel = omodel?.first(where: { $0.value == "opus" })?.label
        let mLabel = mmodel?.first(where: { $0.value == "opus" })?.label
        #expect(oLabel != nil && mLabel != nil)
        #expect(oLabel != mLabel)
        #expect(oLabel?.contains("총괄") == true)
        #expect(mLabel?.contains("모듈") == true)

        let oeffort = selectOptions(view.rows, customId: "orch:oeffort")
        let meffort = selectOptions(view.rows, customId: "orch:meffort")
        let oeLabel = oeffort?.first(where: { $0.value == "high" })?.label
        let meLabel = meffort?.first(where: { $0.value == "high" })?.label
        #expect(oeLabel != nil && meLabel != nil)
        #expect(oeLabel != meLabel)
        #expect(oeLabel?.contains("총괄") == true)
        #expect(meLabel?.contains("모듈") == true)
    }

    // ⑤ D16: the card only ever offers Claude models — never opens for a non-Claude-bound lead.
    @Test func cardAllowedOnlyForClaudeBackend() {
        #expect(orchestrationCardAllowed(backend: .claude))
        #expect(!orchestrationCardAllowed(backend: .codex))
        #expect(!orchestrationCardAllowed(backend: .grok))
    }

    // Side-effect-0 proof (R10): every interaction on an open card except `orch:start` leaves
    // `confirmed` nil — the one gate DabMain checks before running any provisioning/install/index/
    // enableOrchestrationMode. Combined with this file never referencing those three symbols (see
    // header comment), an open-but-not-started card cannot reach them.
    @Test func nonStartInteractionsNeverConfirm() async {
        let w = makeWizard()
        await w.handle(customId: "orch:omodel", values: ["sonnet"])
        await w.handle(customId: "orch:oeffort", values: ["low"])
        await w.handle(customId: "orch:mmodel", values: ["sonnet"])
        await w.handle(customId: "orch:meffort", values: ["low"])
        await w.handle(customId: "unknown:id", values: ["whatever"])
        #expect(w.confirmed == nil)
        _ = w.render()
        #expect(w.confirmed == nil)
    }

    // Review fix (WO-10): a failed lead model/effort patch must say so — not silently claim
    // success — while category/install/index (already done by this point) aren't implicated.
    @Test func appliedSpecLineReportsSuccessOnOk() {
        let spec = OrchestrationSpec(orchestratorModel: "opus", orchestratorEffort: "high", moduleModel: "sonnet", moduleEffort: "low")
        let line = orchestrationAppliedSpecLine(.ok, spec: spec)
        #expect(line.contains("적용했어요"))
        #expect(line.contains("high"))
        #expect(!line.contains("실패"))
    }

    @Test func appliedSpecLineReportsFailureOnEveryNonOkResult() {
        let spec = OrchestrationSpec(orchestratorModel: "opus", orchestratorEffort: "high", moduleModel: "sonnet", moduleEffort: "low")
        let failures: [BindingUpdateResult] = [.noBinding, .invalidEffort, .applyFailed, .persistFailed]
        for result in failures {
            let line = orchestrationAppliedSpecLine(result, spec: spec)
            #expect(line.contains("실패했어요"), "expected a failure message for \(result)")
            #expect(line.contains("high"))
            #expect(!line.contains("적용했어요"))
        }
    }

    @Test func isOrchestrationWizardCustomIdRecognizesOrchPrefixOnly() {
        #expect(isOrchestrationWizardCustomId("orch:omodel"))
        #expect(isOrchestrationWizardCustomId("orch:start"))
        #expect(!isOrchestrationWizardCustomId("resume.pick"))
        #expect(!isOrchestrationWizardCustomId("cancel"))
        #expect(!isOrchestrationWizardCustomId("model"))
    }
}

@Suite("OrchestrationWizardRegistry")
struct OrchestrationWizardRegistryTests {
    private func makeCard() -> OrchestrationWizard {
        OrchestrationWizard(
            options: fakeOptions(),
            initial: OrchestrationSpec(orchestratorModel: "opus", orchestratorEffort: "high", moduleModel: "opus", moduleEffort: "high")
        )
    }

    @Test func putGetRemove() async {
        let reg = OrchestrationWizardRegistry()
        let card = makeCard()
        await reg.put(card, channelId: "c1")
        #expect(await reg.get(channelId: "c1") != nil)
        await reg.remove(channelId: "c1")
        #expect(await reg.get(channelId: "c1") == nil)
    }

    // Mirrors ResumeWizardRegistryTests.enqueueSerializesJobsOnSameChannel (ResumeWizard.swift's
    // registry) — same queue mechanism, same guarantee needed here so a fast double-click on
    // `orch:start` can't run the provisioning block twice.
    @Test func enqueueSerializesJobsOnSameChannel() async throws {
        let reg = OrchestrationWizardRegistry()
        let recorder = OrchQueueOrderRecorder()
        let gate = OrchQueueGate()

        let firstJob = Task {
            await reg.enqueue(channelId: "c1") {
                await recorder.log("start:1")
                await gate.wait()
                await recorder.log("end:1")
            }
        }
        while await recorder.events.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let secondJob = Task {
            await reg.enqueue(channelId: "c1") {
                await recorder.log("start:2")
                await recorder.log("end:2")
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(await recorder.events == ["start:1"])

        await gate.open()
        _ = await (firstJob.value, secondJob.value)
        #expect(await recorder.events == ["start:1", "end:1", "start:2", "end:2"])
    }
}

private actor OrchQueueOrderRecorder {
    private(set) var events: [String] = []
    func log(_ event: String) { events.append(event) }
}

private actor OrchQueueGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
