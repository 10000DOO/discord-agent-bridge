import Testing
@testable import DiscordAgentBridge

@Suite("I18n", .serialized)
struct I18nTests {
    /// Reset process locale after each test (shared mutable active locale).
    private func withLocale(_ locale: AppLocale, _ body: () -> Void) {
        let prev = I18n.getLocale()
        I18n.setLocale(locale)
        defer { I18n.setLocale(prev) }
        body()
    }

    @Test func defaultsToKorean() {
        I18n.setLocale(.ko)
        #expect(I18n.getLocale() == .ko)
        #expect(I18n.t("stream.responding") == "응답 중…")
        #expect(I18n.t("stream.thinking") == "생각 중…")
        #expect(I18n.t("auth.denied", ["reason": "DM"]) == "권한이 없습니다: DM")
    }

    @Test func englishOverridesMajorKeys() {
        withLocale(.en) {
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

    @Test func fallsBackToKeyForMissing() {
        withLocale(.ko) {
            #expect(I18n.t("this.key.does.not.exist") == "this.key.does.not.exist")
        }
    }

    @Test func interpolatesPlaceholders() {
        withLocale(.ko) {
            #expect(
                I18n.t("cmd.mode.switched", ["backend": "claude"])
                    == "백엔드를 claude 로 바꿨어요."
            )
        }
        withLocale(.en) {
            #expect(
                I18n.t("cmd.mode.switched", ["backend": "claude"])
                    == "Switched backend to claude."
            )
        }
    }

    @Test func leavesUnknownPlaceholderVisible() {
        withLocale(.ko) {
            #expect(I18n.t("stream.thought") == "{sec}초 동안 생각함")
        }
    }

    @Test func perCallLocaleOverrideDoesNotChangeActive() {
        I18n.setLocale(.ko)
        #expect(I18n.t("perm.button.deny", locale: .en) == "Deny")
        #expect(I18n.getLocale() == .ko)
        #expect(I18n.t("perm.button.deny") == "거부")
    }

    @Test func resolveLocaleDefaultsUnknownToKo() {
        #expect(I18n.resolveLocale(nil) == .ko)
        #expect(I18n.resolveLocale("") == .ko)
        #expect(I18n.resolveLocale("ja") == .ko)
        #expect(I18n.resolveLocale("en") == .en)
        #expect(I18n.resolveLocale("ko") == .ko)
    }

    @Test func applyFromConfigLocale() {
        I18n.applyFromConfigLocale("en")
        #expect(I18n.getLocale() == .en)
        I18n.applyFromConfigLocale("ko")
        #expect(I18n.getLocale() == .ko)
    }

    @Test func labelEnumsFollowActiveLocale() {
        withLocale(.en) {
            #expect(StreamEmbedLabels.thinking == "Thinking…")
            #expect(StreamEmbedLabels.responding == "Responding…")
            #expect(InterruptLabels.button == "⏹️ Stop")
            #expect(StatusEmbedLabels.title == "Session status")
            #expect(StatusEmbedLabels.resumeTitle == "Session resumed")
            #expect(idleWatchdogMessageKo.contains("3 minutes"))
            #expect(UpdateLabels.denied.contains("Administrator"))
            #expect(ToolThreadLabels.workThread == "Work log")
        }
        withLocale(.ko) {
            #expect(StreamEmbedLabels.thinking == "생각 중…")
            #expect(formatStreamEmbed(phase: .thinking).title == "생각 중…")
            #expect(formatStreamEmbed().title == "응답 중…")
            #expect(buildStatusEmbed(SessionStatus(
                mode: "claude", cwd: "/w", permMode: "default", usagePanel: true
            )).title == "세션 상태")
        }
    }
}
