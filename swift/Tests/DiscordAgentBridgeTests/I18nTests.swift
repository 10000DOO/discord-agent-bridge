import Testing
@testable import DiscordAgentBridge

@Suite("I18n", .serialized)
struct I18nTests {
    /// Pin the locale to the calling test's task only. This used to swap the process-wide
    /// locale via `I18n.setLocale` and restore it afterwards, but the suites of this package
    /// run in parallel, so every other suite saw English for the duration and Korean-asserting
    /// tests failed intermittently (C30). Do not switch this back to `I18n.setLocale`.
    private func withLocale(_ locale: AppLocale, _ body: () -> Void) async {
        await I18n.withLocale(locale) { body() }
    }

    @Test func defaultsToKorean() {
        I18n.setLocale(.ko)
        #expect(I18n.getLocale() == .ko)
        #expect(I18n.t("stream.responding") == "응답 중…")
        #expect(I18n.t("stream.thinking") == "생각 중…")
        #expect(I18n.t("auth.denied", ["reason": "DM"]) == "권한이 없습니다: DM")
    }

    @Test func englishOverridesMajorKeys() async {
        await withLocale(.en) {
            #expect(I18n.t("stream.responding") == "Responding…")
            #expect(I18n.t("stream.thinking") == "Thinking…")
            #expect(I18n.t("stream.responded") == "Response complete")
            #expect(I18n.t("auth.denied", ["reason": "DM"]) == "Permission denied: DM")
            #expect(I18n.t("cmd.stop.done") == "Stopped the session.")
            #expect(I18n.t("cmd.clear.done").contains("Cleared"))
            #expect(I18n.t("cmd.close.done").contains("Closed"))
            #expect(I18n.t("watchdog.idle").contains("3 minutes"))
            #expect(I18n.t("perm.button.allow") == "Allow")
            #expect(I18n.t("perm.button.deny") == "Deny")
            #expect(I18n.t("status.title") == "Session status")
            #expect(I18n.t("stats.active", ["n": "2"]) == "Active sessions (2)")
            #expect(I18n.t("cmd.setup.unavailable").contains("Manage Channels"))
            #expect(I18n.t("doc.shared", ["path": "a.md"]).contains("a.md"))
            #expect(I18n.t("update.denied").contains("Administrator"))
            #expect(I18n.t("usage.title") == "Claude usage")
        }
    }

    @Test func fallsBackToKeyForMissing() async {
        await withLocale(.ko) {
            #expect(I18n.t("this.key.does.not.exist") == "this.key.does.not.exist")
        }
    }

    @Test func interpolatesPlaceholders() async {
        await withLocale(.ko) {
            #expect(
                I18n.t("cmd.mode.switched", ["backend": "claude"])
                    == "백엔드를 claude 로 바꿨어요."
            )
        }
        await withLocale(.en) {
            #expect(
                I18n.t("cmd.mode.switched", ["backend": "claude"])
                    == "Switched backend to claude."
            )
        }
    }

    @Test func leavesUnknownPlaceholderVisible() async {
        await withLocale(.ko) {
            #expect(I18n.t("stream.thought") == "{sec}초 동안 생각함")
        }
    }

    @Test func perCallLocaleOverrideDoesNotChangeActive() {
        I18n.setLocale(.ko)
        #expect(I18n.t("perm.button.deny", locale: .en) == "Deny")
        #expect(I18n.getLocale() == .ko)
        #expect(I18n.t("perm.button.deny") == "거부")
    }

    @Test func requestLocaleDoesNotMutateGlobalFallback() async throws {
        I18n.setLocale(.ko)
        let translated = try await I18n.withLocale(.en) {
            I18n.t("perm.button.deny")
        }
        #expect(translated == "Deny")
        #expect(I18n.t("perm.button.deny") == "거부")
    }

    @Test func resolveLocaleDefaultsUnknownToKo() {
        #expect(I18n.resolveLocale(nil) == .ko)
        #expect(I18n.resolveLocale("") == .ko)
        #expect(I18n.resolveLocale("ja") == .ko)
        #expect(I18n.resolveLocale("en") == .en)
        #expect(I18n.resolveLocale("ko") == .ko)
    }

    @Test func missingGuildLocaleKeepsGlobalFallback() async {
        await withLocale(.en) {
            #expect(I18n.resolveServerLocale(nil) == .en)
            #expect(I18n.resolveServerLocale("") == .en)
            #expect(I18n.resolveServerLocale("ko") == .ko)
        }
    }

    /// The only test here that writes the process-wide locale, because landing in the
    /// process-wide locale IS the contract of `applyFromConfigLocale` — a task-local
    /// `I18n.withLocale` would shadow the very write under test, and asserting only
    /// values that resolve back to `ko` would still pass if `setLocale` broke for
    /// non-default locales.
    ///
    /// The two reads are CAPTURED here and asserted after the locale is back to `ko`, on
    /// purpose: `#expect` does non-trivial recording work, so evaluating it while the
    /// global still says `en` widens the window in which the suites running in parallel
    /// observe English and their Korean assertions fail (C30). Keep `#expect` out of the
    /// window — do not "tidy" these captures back into inline assertions.
    @Test func applyFromConfigLocale() {
        I18n.applyFromConfigLocale("en")
        let afterEn = I18n.getLocale()
        I18n.applyFromConfigLocale("ko")
        let afterKo = I18n.getLocale()
        #expect(afterEn == .en)
        #expect(afterKo == .ko)
    }

    @Test func modeUnavailableInterpolatesBackend() async {
        await withLocale(.ko) {
            #expect(
                I18n.t("cmd.mode.unavailable", ["backend": "grok"])
                    == "`grok` 백엔드는 사용할 수 없어요. 현재 세션은 그대로 유지했어요."
            )
        }
        await withLocale(.en) {
            #expect(
                I18n.t("cmd.mode.unavailable", ["backend": "grok"])
                    == "The `grok` backend is unavailable. Kept the current session unchanged."
            )
        }
    }

    @Test func directoryPanelPromptHasKoAndEnValues() {
        #expect(I18n.t("dir.panel.prompt", locale: .ko) == "Discord 세션 프로젝트 폴더 선택")
        #expect(I18n.t("dir.panel.prompt", locale: .en) == "Choose the project folder for the Discord session")
    }

    @Test func usageFiveHourLabelHasKoAndEnValues() {
        #expect(I18n.t("usage.fiveHour", locale: .ko) == "5시간")
        #expect(I18n.t("usage.fiveHour", locale: .en) == "5-hour")
    }

    @Test func configPanelTitleHasKoAndEnValues() {
        #expect(I18n.t("config.title", locale: .ko) == "역할·기본값 설정")
        #expect(I18n.t("config.title", locale: .en) == "Roles & defaults settings")
    }

    @Test func wizardStepFolderHasKoAndEnValues() {
        #expect(I18n.t("wizard.step.folder", locale: .ko) == "1/5단계 · 폴더")
        #expect(I18n.t("wizard.step.folder", locale: .en) == "Step 1/5 · Folder")
    }

    @Test func labelEnumsFollowActiveLocale() async {
        await withLocale(.en) {
            #expect(StreamEmbedLabels.thinking == "Thinking…")
            #expect(StreamEmbedLabels.responding == "Responding…")
            #expect(InterruptLabels.button == "⏹️ Stop")
            #expect(StatusEmbedLabels.title == "Session status")
            #expect(StatusEmbedLabels.resumeTitle == "Session resumed")
            #expect(idleWatchdogMessageKo.contains("3 minutes"))
            #expect(UpdateLabels.denied.contains("Administrator"))
            #expect(ToolThreadLabels.workThread == "Work log")
        }
        await withLocale(.ko) {
            #expect(StreamEmbedLabels.thinking == "생각 중…")
            #expect(formatStreamEmbed(phase: .thinking).title == "생각 중…")
            #expect(formatStreamEmbed().title == "응답 중…")
            #expect(buildStatusEmbed(SessionStatus(
                mode: "claude", cwd: "/w", permMode: "default", usagePanel: true
            )).title == "세션 상태")
        }
    }
}
