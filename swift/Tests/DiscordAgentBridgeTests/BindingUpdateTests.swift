import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("BindingUpdate pure helpers")
struct BindingUpdateTests {
    @Test func applyPatchToConfigSetsOnlyProvidedFields() {
        let base = SessionConfig(backend: .claude, model: "m1", effort: "low", permMode: "default")
        let onlyModel = applyPatch(to: base, BindingPatch(model: "m2"))
        #expect(onlyModel.model == "m2")
        #expect(onlyModel.effort == "low")
        #expect(onlyModel.permMode == "default")
        #expect(onlyModel.backend == .claude)

        let backend = applyPatch(to: base, BindingPatch(backend: .codex))
        #expect(backend.backend == .codex)
        #expect(backend.model == "m1")
    }

    @Test func applyPatchToSessionClearsBackendSessionIdWhenRequested() {
        let s = PersistedSession(
            backend: .claude, backendSessionId: "B-1", cwd: "/x", guildId: "g",
            model: "m1", effort: "high", permMode: "plan", updatedAt: "t0"
        )
        let cleared = applyPatch(to: s, BindingPatch(clearBackendSessionId: true), now: "t1")
        #expect(cleared.backendSessionId == nil)
        #expect(cleared.model == "m1")
        #expect(cleared.effort == "high")
        #expect(cleared.permMode == "plan")
        #expect(cleared.updatedAt == "t1")

        let modelOnly = applyPatch(to: s, BindingPatch(model: "m2"), now: "t2")
        #expect(modelOnly.backendSessionId == "B-1")
        #expect(modelOnly.model == "m2")
        #expect(modelOnly.updatedAt == "t2")
    }

    @Test func sessionConfigFromPersistedMapsFields() {
        let s = PersistedSession(
            backend: .grok, backendSessionId: "s", cwd: "/c", guildId: "g",
            model: "g1", effort: "high", permMode: "bypassPermissions", updatedAt: "t"
        )
        let c = sessionConfig(from: s)
        #expect(c == SessionConfig(backend: .grok, model: "g1", effort: "high", permMode: "bypassPermissions"))
    }

    @Test func formatStatsLinesEmptyAndFilled() {
        #expect(formatStatsLines(bindings: []) == ["(none)"])
        let lines = formatStatsLines(bindings: [
            (channelId: "c1", backend: .claude, model: "sonnet", effort: "high"),
            (channelId: "c2", backend: .codex, model: nil, effort: nil),
        ])
        #expect(lines.count == 2)
        #expect(lines[0].contains("c1"))
        #expect(lines[0].contains("claude"))
        #expect(lines[0].contains("sonnet"))
        #expect(lines[0].contains("effort=high"))
        #expect(lines[1].contains("c2"))
        #expect(lines[1].contains("codex"))
        #expect(!lines[1].contains("`"))
        #expect(!lines[1].contains("effort="))
    }

    // MARK: - G-P1-04 /mode perm profile resolution

    private var sampleProfiles: [String: Profile] {
        [
            "readonly": Profile(
                permissionMode: "plan",
                allowedTools: ["Read", "Glob", "Grep"],
                policyTier: "read-only"
            ),
            "edit": Profile(
                permissionMode: "acceptEdits",
                allowedTools: ["Read", "Edit", "Write", "Bash"],
                policyTier: "normal"
            ),
        ]
    }

    @Test func resolveModePermKnownProfileStoresNameAndBundledMode() {
        let r = resolveModePerm(value: "readonly", profiles: sampleProfiles)
        #expect(r.permMode == "plan")
        #expect(r.permissionProfile == "readonly")
        #expect(r.updatePermissionProfile == true)
        #expect(r.display == "readonly")
        let patch = r.bindingPatch
        #expect(patch.permMode == "plan")
        #expect(patch.permissionProfile == "readonly")
        #expect(patch.updatePermissionProfile == true)
    }

    @Test func resolveModePermUnknownValueIsRawPermMode() {
        let r = resolveModePerm(value: "bypassPermissions", profiles: sampleProfiles)
        #expect(r.permMode == "bypassPermissions")
        #expect(r.permissionProfile == nil)
        #expect(r.updatePermissionProfile == false)
        #expect(r.display == "bypassPermissions")
        let patch = r.bindingPatch
        #expect(patch.permMode == "bypassPermissions")
        #expect(patch.updatePermissionProfile == false)
    }

    @Test func resolveModePermProfileNameWinsOverSameNamedMode() {
        // A key present in profiles is always treated as a profile (TS hasOwnProperty).
        var profiles = sampleProfiles
        profiles["plan"] = Profile(
            permissionMode: "acceptEdits",
            allowedTools: ["Read"],
            policyTier: "normal"
        )
        let r = resolveModePerm(value: "plan", profiles: profiles)
        #expect(r.permissionProfile == "plan")
        #expect(r.permMode == "acceptEdits")
        #expect(r.updatePermissionProfile == true)
    }

    @Test func applyPatchSessionWritesPermissionProfileWhenFlagged() {
        let s = PersistedSession(
            backend: .claude, cwd: "/x", guildId: "g",
            permMode: "default", permissionProfile: nil, updatedAt: "t0"
        )
        let viaProfile = applyPatch(
            to: s,
            BindingPatch(
                permMode: "plan",
                permissionProfile: "readonly",
                updatePermissionProfile: true
            ),
            now: "t1"
        )
        #expect(viaProfile.permMode == "plan")
        #expect(viaProfile.permissionProfile == "readonly")
        #expect(viaProfile.updatedAt == "t1")

        // Raw permMode switch: do not touch existing profile.
        let withProfile = PersistedSession(
            backend: .claude, cwd: "/x", guildId: "g",
            permMode: "plan", permissionProfile: "readonly", updatedAt: "t0"
        )
        let raw = applyPatch(
            to: withProfile,
            BindingPatch(permMode: "acceptEdits"),
            now: "t2"
        )
        #expect(raw.permMode == "acceptEdits")
        #expect(raw.permissionProfile == "readonly")
    }
}
