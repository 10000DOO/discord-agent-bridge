import Testing
@testable import DiscordAgentBridge

private let nonexistentHome = "/this-home-dir-does-not-exist-for-tests"

@Suite("resolveCustomEnv")
struct ResolveCustomEnvTests {
    @Test func extractsAllowedEnvVarsFromKimiAliasValue() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc":
                    "alias kimi='ANTHROPIC_BASE_URL=\"https://api.moonshot.ai/anthropic\" ANTHROPIC_AUTH_TOKEN=\"sk-secret\" ANTHROPIC_MODEL=\"kimi-k2.7-code\" API_TIMEOUT_MS=\"600000\" claude'",
            ]
        ))
        #expect(result.env == [
            "ANTHROPIC_BASE_URL": "https://api.moonshot.ai/anthropic",
            "ANTHROPIC_AUTH_TOKEN": "sk-secret",
            "ANTHROPIC_MODEL": "kimi-k2.7-code",
            "API_TIMEOUT_MS": "600000",
        ])
        #expect(result.source == ".zshrc")
        #expect(result.hasDangerousFlag == false)
    }

    @Test func extractsBareAndExportPrefixedAssignments() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc": """

                # some comment
                export ANTHROPIC_BASE_URL="https://api.example.com"
                ANTHROPIC_API_KEY='key-2'
                API_TIMEOUT_MS=600000
                """,
            ]
        ))
        #expect(result.env == [
            "ANTHROPIC_BASE_URL": "https://api.example.com",
            "ANTHROPIC_API_KEY": "key-2",
            "API_TIMEOUT_MS": "600000",
        ])
        #expect(result.source == ".zshrc")
    }

    @Test func alsoScansAliasClaude() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".bashrc":
                    "alias claude='ANTHROPIC_API_KEY=\"key-1\" ANTHROPIC_SMALL_FAST_MODEL=\"kimi-k2.7-code\" claude'",
            ]
        ))
        #expect(result.env == [
            "ANTHROPIC_API_KEY": "key-1",
            "ANTHROPIC_SMALL_FAST_MODEL": "kimi-k2.7-code",
        ])
        #expect(result.source == ".bashrc")
    }

    @Test func ignoresEnvKeysNotInAllowList() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc": """

                ANTHROPIC_MODEL="kimi"
                PATH="/evil"
                FOO="bar"
                """,
            ]
        ))
        #expect(result.env == ["ANTHROPIC_MODEL": "kimi"])
    }

    @Test func detectsDangerouslySkipPermissionsAnywhere() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc":
                    "# dangerous alias\nalias kimi='claude --dangerously-skip-permissions'\nANTHROPIC_MODEL=\"kimi\"",
            ]
        ))
        #expect(result.hasDangerousFlag == true)
        #expect(result.env["ANTHROPIC_MODEL"] == "kimi")
    }

    @Test func supportsSingleDoubleAndUnquotedValues() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc": """

                ANTHROPIC_MODEL='single'
                export ANTHROPIC_API_KEY="double"
                API_TIMEOUT_MS=600000
                """,
            ]
        ))
        #expect(result.env == [
            "ANTHROPIC_MODEL": "single",
            "ANTHROPIC_API_KEY": "double",
            "API_TIMEOUT_MS": "600000",
        ])
    }

    @Test func laterFilesOverrideEarlierFiles() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc": "ANTHROPIC_MODEL=\"old\"",
                ".zprofile": "ANTHROPIC_MODEL=\"new\"",
            ]
        ))
        #expect(result.env["ANTHROPIC_MODEL"] == "new")
        #expect(result.source == ".zprofile")
    }

    @Test func lastOccurrenceWithinSingleFileWins() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [
                ".zshrc": """

                ANTHROPIC_MODEL="first"
                ANTHROPIC_MODEL="second"
                ANTHROPIC_MODEL="third"
                """,
            ]
        ))
        #expect(result.env["ANTHROPIC_MODEL"] == "third")
    }

    @Test func emptyEnvWhenNoAllowedKeys() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [".zshrc": "# no relevant env\n"]
        ))
        #expect(result.env.isEmpty)
        #expect(result.source == nil)
        #expect(result.hasDangerousFlag == false)
    }

    @Test func doesNotSourceOrExecuteFile() {
        let result = resolveCustomEnv(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [".zshrc": "ANTHROPIC_MODEL=\"$(rm -rf /)\""]
        ))
        #expect(result.env["ANTHROPIC_MODEL"] == "$(rm -rf /)")
    }
}

@Suite("customBackendLabel")
struct CustomBackendLabelTests {
    @Test func namesResolvedAnthropicModel() {
        let label = customBackendLabel(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [".zshrc": "export ANTHROPIC_MODEL=\"kimi-k2.7-code\""]
        ))
        #expect(label == "Custom (kimi-k2.7-code)")
    }

    @Test func fallsBackToPlainCustom() {
        let label = customBackendLabel(ResolveCustomEnvOptions(
            homeDir: nonexistentHome,
            files: [:]
        ))
        #expect(label == "Custom")
    }
}
