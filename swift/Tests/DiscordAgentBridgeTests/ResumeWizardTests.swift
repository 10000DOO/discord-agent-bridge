import Testing
import Foundation
@testable import DiscordAgentBridge

// Pure ResumeWizard SM tests — no Discord, no sidecar.

@Suite("ResumeWizard")
struct ResumeWizardTests {

    private func makeFlow(
        backends: [Backend] = [.claude, .codex, .grok],
        defaultBackend: Backend = .claude,
        sessions: [Backend: [ResumableSession]] = [:],
        resumeChannel: String = "c1",
        resumeThrows: Bool = false
    ) -> ResumeWizard {
        let listed = LockedBox(sessions)
        return ResumeWizard(options: ResumeWizardOptions(
            guildId: "g1",
            channelId: "c1",
            ownerId: "u1",
            cwd: "/proj",
            backends: backends,
            defaultBackend: defaultBackend,
            listResumableFor: { backend, _ in
                listed.withLock { $0[backend] ?? [] }
            },
            resume: { params in
                if resumeThrows { throw ResumeTestError.fail }
                return ResumeResult(channelId: resumeChannel.isEmpty ? params.channelId : resumeChannel)
            },
            relativeTime: { iso in
                iso == nil ? "" : "1분 전"
            }
        ))
    }

    @Test func startsOnBackendStep() {
        let w = makeFlow()
        #expect(w.currentStep() == .backend)
        #expect(w.sessionChannelId() == nil)
        let view = w.render()
        #expect(view.description.contains("백엔드"))
        let ids = view.rows.flatMap(\.components).compactMap { c -> String? in
            switch c {
            case .select(let id, _, _): return id
            case .button(let id, _, _, _): return id
            }
        }
        #expect(ids.contains("resume.backend"))
        #expect(ids.contains("resume.backend.next"))
        #expect(ids.contains("cancel"))
    }

    @Test func backendSelectPendingThenNextListsSessions() async {
        let sessions = [
            ResumableSession(sessionId: "cl-1", cwd: "/proj", label: "Claude work", updatedAt: "2026-07-01T00:00:00Z"),
        ]
        let w = makeFlow(sessions: [.claude: sessions])
        _ = await w.handle(WizardInput(id: "resume.backend", value: "claude"))
        #expect(w.currentStep() == .backend)
        let step = await w.handle(WizardInput(id: "resume.backend.next"))
        #expect(step == .pick)
        let view = w.render()
        let pick = view.rows.flatMap(\.components).compactMap { c -> [WizardSelectOption]? in
            if case .select(let id, _, let opts) = c, id == "resume.pick" { return opts }
            return nil
        }.first
        #expect(pick?.map(\.value) == ["cl-1"])
        #expect(pick?.first?.label.contains("Claude work") == true)
    }

    @Test func emptyListGoesToEmpty() async {
        let w = makeFlow(sessions: [.claude: []])
        let step = await w.handle(WizardInput(id: "resume.backend.next"))
        #expect(step == .empty)
        #expect(w.render().rows.isEmpty)
        #expect(w.render().description.contains("재개할 세션이 없습니다"))
    }

    @Test func pickResumesAndBindsChannel() async {
        let sessions = [ResumableSession(sessionId: "cl-42", cwd: "/proj", label: "Resume me")]
        let w = makeFlow(sessions: [.claude: sessions], resumeChannel: "c-new")
        _ = await w.handle(WizardInput(id: "resume.backend.next"))
        let step = await w.handle(WizardInput(id: "resume.pick", value: "cl-42"))
        #expect(step == .done)
        #expect(w.sessionChannelId() == "c-new")
    }

    @Test func stalePickIdIsIgnored() async {
        let sessions = [ResumableSession(sessionId: "cl-1", cwd: "/proj")]
        let w = makeFlow(sessions: [.claude: sessions])
        _ = await w.handle(WizardInput(id: "resume.backend.next"))
        let step = await w.handle(WizardInput(id: "resume.pick", value: "foreign-id"))
        #expect(step == .pick)
        #expect(w.sessionChannelId() == nil)
    }

    @Test func codexBackendListsCodexOnly() async {
        let w = makeFlow(sessions: [
            .claude: [ResumableSession(sessionId: "cl-1", cwd: "/proj")],
            .codex: [ResumableSession(sessionId: "cx-7", cwd: "/proj", label: "Codex thread")],
        ])
        _ = await w.handle(WizardInput(id: "resume.backend", value: "codex"))
        _ = await w.handle(WizardInput(id: "resume.backend.next"))
        #expect(w.currentStep() == .pick)
        let pick = w.render().rows.flatMap(\.components).compactMap { c -> [WizardSelectOption]? in
            if case .select(let id, _, let opts) = c, id == "resume.pick" { return opts }
            return nil
        }.first
        #expect(pick?.map(\.value) == ["cx-7"])
    }

    @Test func cancelFromBackend() async {
        let w = makeFlow()
        let step = await w.handle(WizardInput(id: "cancel"))
        #expect(step == .cancelled)
        #expect(w.render().description.contains("취소"))
    }

    @Test func terminalStepsIgnoreFurtherInput() async {
        let w = makeFlow(sessions: [.claude: []])
        _ = await w.handle(WizardInput(id: "resume.backend.next"))
        #expect(w.currentStep() == .empty)
        let step = await w.handle(WizardInput(id: "resume.backend.next"))
        #expect(step == .empty)
    }

    @Test func renderFollowsActiveLocale() {
        let prevLocale = I18n.getLocale()
        defer { I18n.setLocale(prevLocale) }
        let w = makeFlow()

        I18n.setLocale(.ko)
        #expect(w.render().title == "세션 시작")
        #expect(w.render().description == "재개할 백엔드를 선택하고 \"다음\"을 누르세요.")

        I18n.setLocale(.en)
        #expect(w.render().title == "Start session")
        #expect(w.render().description == "Pick the backend to resume and press \"Next\".")
    }

    @Test func recognizesResumeCustomIds() {
        let resume = isResumeWizardCustomId("dir:resume")
        let backend = isResumeWizardCustomId("resume.backend")
        let next = isResumeWizardCustomId("resume.backend.next")
        let pick = isResumeWizardCustomId("resume.pick")
        let notHere = isResumeWizardCustomId("dir:here")
        let notCancel = isResumeWizardCustomId("cancel")
        #expect(resume)
        #expect(backend)
        #expect(next)
        #expect(pick)
        #expect(!notHere)
        #expect(!notCancel)
        #expect(isWizardCustomId("dir:resume"))
        #expect(isWizardCustomId("resume.pick"))
    }
}

@Suite("resumeRelativeTime + listResumableFromStore")
struct ResumeHelpersTests {

    @Test func relativeTimeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        #expect(resumeRelativeTime(nil, now: now) == "")
        #expect(resumeRelativeTime("not-a-date", now: now) == "")
        #expect(resumeRelativeTime(fmt.string(from: now.addingTimeInterval(-10)), now: now) == "방금")
        #expect(resumeRelativeTime(fmt.string(from: now.addingTimeInterval(-120)), now: now) == "2분 전")
        #expect(resumeRelativeTime(fmt.string(from: now.addingTimeInterval(-7200)), now: now) == "2시간 전")
        #expect(resumeRelativeTime(fmt.string(from: now.addingTimeInterval(-172_800)), now: now) == "2일 전")
    }

    @Test func storeListFiltersBackendCwdAndSessionId() {
        let sessions: [String: PersistedSession] = [
            "a": PersistedSession(
                backend: .codex, backendSessionId: "t1", cwd: "/proj", guildId: "g",
                updatedAt: "2026-07-02T00:00:00Z"
            ),
            "b": PersistedSession(
                backend: .codex, backendSessionId: "t2", cwd: "/other", guildId: "g",
                updatedAt: "2026-07-03T00:00:00Z"
            ),
            "c": PersistedSession(
                backend: .claude, backendSessionId: "c1", cwd: "/proj", guildId: "g",
                updatedAt: "2026-07-04T00:00:00Z"
            ),
            "d": PersistedSession(
                backend: .codex, backendSessionId: nil, cwd: "/proj", guildId: "g",
                updatedAt: "2026-07-05T00:00:00Z"
            ),
            "e": PersistedSession(
                backend: .codex, backendSessionId: "t0", cwd: "/proj", guildId: "g",
                updatedAt: "2026-07-01T00:00:00Z", archived: true
            ),
        ]
        let listed = listResumableFromStore(sessions: sessions, backend: .codex, cwd: "/proj")
        #expect(listed.map(\.sessionId) == ["t1"])
    }
}

private enum ResumeTestError: Error { case fail }
