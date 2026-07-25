import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("FolderPanel pure (W11-b2 slice3, no live GUI)")
struct FolderPanelTests {

    @Test func escapeAppleScriptEscapesBackslashAndQuotes() {
        #expect(escapeAppleScript(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(escapeAppleScript(#"/Users/me/My "Quoted" Dir"#).contains(#"\"Quoted\""#))
    }

    @Test func chooseFolderScriptContainsPromptAndStartDirEscaped() {
        let script = chooseFolderScript(startDir: #"/Users/me/My "Quoted" Dir"#, prompt: "Pick a folder")
        #expect(script.contains("choose folder"))
        #expect(script.contains("POSIX path"))
        #expect(script.contains(#"\"Quoted\""#))
        #expect(script.contains("Pick a folder"))
    }

    @Test func interpretPickedPathOnZeroExit() {
        let o = interpretFolderPanelResult(
            stdout: "/Users/me/project/\n",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
        #expect(o == .picked("/Users/me/project/"))
    }

    @Test func interpretCancelOnAppleScriptMinus128() {
        let o = interpretFolderPanelResult(
            stdout: "",
            stderr: "execution error: User canceled. (-128)\n",
            exitCode: 1,
            timedOut: false
        )
        #expect(o == .cancelled)
    }

    @Test func interpretTimeoutTakesPrecedence() {
        let o = interpretFolderPanelResult(
            stdout: "",
            stderr: "",
            exitCode: nil,
            timedOut: true
        )
        #expect(o == .timeout)
    }

    @Test func interpretFailedUsesStderr() {
        let o = interpretFolderPanelResult(
            stdout: "",
            stderr: "osascript: some real failure\n",
            exitCode: 2,
            timedOut: false
        )
        #expect(o == .failed("osascript: some real failure"))
    }

    @Test func openMacFolderPanelWithInjectedRunnerResolvesPath() async throws {
        let run: PanelRunner = { command, args, timeoutMs in
            #expect(command == "osascript")
            #expect(args.count == 2)
            #expect(args[0] == "-e")
            #expect(args[1].contains("choose folder"))
            #expect(args[1].contains(#"\"Quoted\""#))
            #expect(timeoutMs == 60_000)
            return ProcessCapture(stdout: "/Users/me/project/\n", stderr: "", exitCode: 0)
        }
        let path = try await openMacFolderPanel(
            startDir: #"/Users/me/My "Quoted" Dir"#,
            prompt: "Pick a folder",
            timeoutMs: 60_000,
            run: run
        )
        #expect(path == "/Users/me/project/")
    }

    @Test func openMacFolderPanelCancelReturnsNil() async throws {
        let run: PanelRunner = { _, _, _ in
            ProcessCapture(
                stdout: "",
                stderr: "execution error: User canceled. (-128)\n",
                exitCode: 1
            )
        }
        let path = try await openMacFolderPanel(startDir: "/tmp", prompt: "Pick", timeoutMs: 5_000, run: run)
        #expect(path == nil)
    }

    @Test func openMacFolderPanelTimeoutThrows() async {
        let run: PanelRunner = { _, _, _ in
            ProcessCapture(stdout: "", stderr: "", exitCode: nil, timedOut: true)
        }
        do {
            _ = try await openMacFolderPanel(startDir: "/tmp", prompt: "Pick", timeoutMs: 5_000, run: run)
            Issue.record("expected timeout throw")
        } catch let err as FolderPanelError {
            #expect(err == .timeout)
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func openMacFolderPanelFailedThrows() async {
        let run: PanelRunner = { _, _, _ in
            ProcessCapture(stdout: "", stderr: "osascript: boom\n", exitCode: 2)
        }
        do {
            _ = try await openMacFolderPanel(startDir: "/tmp", prompt: "Pick", timeoutMs: 5_000, run: run)
            Issue.record("expected failed throw")
        } catch let err as FolderPanelError {
            #expect(err == .failed("osascript: boom"))
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }

    @Test func folderPanelBusyIsOneAtATime() async {
        let busy = FolderPanelBusy()
        #expect(await busy.tryBegin("c1") == true)
        #expect(await busy.tryBegin("c1") == false)
        #expect(await busy.tryBegin("c2") == true)
        await busy.end("c1")
        #expect(await busy.tryBegin("c1") == true)
        await busy.end("c1")
        await busy.end("c2")
    }
}
