import Testing
import Foundation
@testable import DiscordAgentBridge
@testable import dab

// docs/task-panel-and-diff-view.md WO-7 · WO-8 (R6, R6-1).

@Suite("/diff wiring") struct DiffCommandWiringTests {
    private func files(_ count: Int) -> [GitChangedFile] {
        (0..<count).map { GitChangedFile(path: "src/file\($0).swift", kind: .modified, added: 2, removed: 1) }
    }

    @Test func diffIsRegisteredAsASlashCommand() {
        let specs = allSlashCommandSpecs()
        #expect(specs.contains { $0.name == "diff" })
        let spec = diffCommandSpec()
        // ko over 32 scalars silently drops the whole locale; en over 100 fails the bulk register.
        #expect(spec.description.ko.unicodeScalars.count <= 32)
        #expect(spec.description.en.count <= 100)
        #expect(spec.options.isEmpty)
    }

    @Test func singleFileStillGetsAWayToSeeItsDiff() {
        // Regression: with one changed file there is no picker, so dropping the button too left the
        // thread with a summary and no route to the diff at all.
        let rows = diffComponentRows(files: files(1))
        #expect(rows.count == 1)
        #expect(!rows.isEmpty)
    }

    @Test func multipleFilesGetOnePickerPlusTheButton() {
        let rows = diffComponentRows(files: files(3))
        #expect(rows.count == 2)
    }

    @Test func moreThanTwentyFiveFilesSplitIntoSeveralPickers() {
        // R6-1 / D4-2: the list is never truncated to fit one menu.
        let rows = diffComponentRows(files: files(60))
        #expect(rows.count == 4) // 3 select pages (25/25/10) + expand-all
    }

    @Test func noFilesMeansNoComponents() {
        #expect(diffComponentRows(files: []).isEmpty)
    }

    @Test func componentIdsAreRoutedAndDoNotCollide() {
        #expect(parseDiffComponentId(diffFileSelectCustomId) != nil)
        #expect(parseDiffComponentId(diffExpandAllCustomId) != nil)
        #expect(parseDiffComponentId("interrupt:1:2") == nil)
        #expect(parseDiffComponentId(taskPanelRecheckCustomId) == nil)
        #expect(parseDiffComponentId("diff") == nil)
    }

    @Test func threadRegistryKeepsTheNewestEntriesOnly() async {
        let registry = DiffThreadRegistry()
        for index in 0..<60 {
            await registry.put(threadId: "t\(index)", cwd: "/tmp", files: files(1))
        }
        // Bounded so a long-lived bot can't grow one entry per /diff forever.
        #expect(await registry.get(threadId: "t59") != nil)
        #expect(await registry.get(threadId: "t0") == nil)
    }

    @Test func registryRoundTripsCwdAndFiles() async {
        let registry = DiffThreadRegistry()
        await registry.put(threadId: "t1", cwd: "/work/repo", files: files(2))
        let state = await registry.get(threadId: "t1")
        #expect(state?.cwd == "/work/repo")
        #expect(state?.files.count == 2)
    }
}
