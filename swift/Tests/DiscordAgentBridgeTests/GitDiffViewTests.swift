import Testing
import Foundation
@testable import DiscordAgentBridge

// docs/task-panel-and-diff-view.md WO-6 (R6-1, R7, R8).

@Suite struct GitStatusParseTests {
    @Test func parsesModifiedAddedDeletedUntracked() {
        let output = """
         M swift/Sources/a.swift
        A  swift/Sources/b.swift
         D swift/Sources/c.swift
        ?? docs/new.md
        """
        let files = parseGitStatusPorcelain(output)
        #expect(files.map(\.path) == [
            "swift/Sources/a.swift", "swift/Sources/b.swift", "swift/Sources/c.swift", "docs/new.md",
        ])
        #expect(files.map(\.kind) == [.modified, .added, .deleted, .untracked])
        #expect(files[3].kind.isUntracked)
    }

    @Test func renameKeepsTheNewPath() {
        let files = parseGitStatusPorcelain("R  old/name.swift -> new/name.swift")
        #expect(files.count == 1)
        #expect(files[0].path == "new/name.swift")
        #expect(files[0].kind == .renamed)
    }

    @Test func stagedThenEditedPrefersTheWorktreeColumn() {
        // "AM" — added to the index, then modified again in the work tree.
        let files = parseGitStatusPorcelain("AM swift/Sources/a.swift")
        #expect(files[0].kind == .modified)
    }

    @Test func quotedPathsAreUnquoted() {
        let files = parseGitStatusPorcelain("?? \"docs/with space.md\"")
        #expect(files[0].path == "docs/with space.md")
    }

    @Test func emptyOutputYieldsNoFiles() {
        #expect(parseGitStatusPorcelain("").isEmpty)
        #expect(parseGitStatusPorcelain("\n\n").isEmpty)
    }
}

@Suite struct GitNumstatParseTests {
    @Test func parsesCountsPerPath() {
        let counts = parseGitNumstat("96\t0\tswift/Sources/a.swift\n11\t2\tswift/Sources/b.swift")
        #expect(counts["swift/Sources/a.swift"]?.added == 96)
        #expect(counts["swift/Sources/b.swift"]?.removed == 2)
    }

    @Test func binaryFilesCountAsZero() {
        let counts = parseGitNumstat("-\t-\tassets/logo.png")
        #expect(counts["assets/logo.png"]?.added == 0)
        #expect(counts["assets/logo.png"]?.removed == 0)
    }

    @Test func renamedPathsResolveToTheCurrentName() {
        // Both numstat rename spellings must land on the path that exists now, or a renamed file
        // would show +0 -0 (its counts would be filed under a path the status list never mentions).
        let plain = parseGitNumstat("3\t1\told/name.swift => new/name.swift")
        #expect(plain["new/name.swift"]?.added == 3)
        let braced = parseGitNumstat("3\t1\tsrc/{old => new}/file.swift")
        #expect(braced["src/new/file.swift"]?.added == 3)
        #expect(resolveNumstatRenamePath("plain/path.swift") == "plain/path.swift")
    }

    @Test func mergeEnrichesStatusWithoutInventingFiles() {
        let status = [
            GitChangedFile(path: "a.swift", kind: .modified),
            GitChangedFile(path: "b.md", kind: .untracked),
        ]
        let merged = mergeChangedFiles(status: status, numstat: [
            "a.swift": (added: 4, removed: 1),
            "ghost.swift": (added: 9, removed: 9),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].added == 4)
        #expect(merged[0].removed == 1)
        // No numstat entry → counts stay zero, and the file is still listed.
        #expect(merged[1].added == 0)
    }
}

@Suite struct DiffPresentationTests {
    private let files = [
        GitChangedFile(path: "Render/TaskPanelHost.swift", kind: .modified, added: 96, removed: 0),
        GitChangedFile(path: "Render/ToolActivityHost.swift", kind: .modified, added: 11, removed: 2),
        GitChangedFile(path: "Render/LegacyPlanLine.swift", kind: .deleted, added: 0, removed: 30),
    ]

    @Test func summaryTotalsEveryFile() {
        let spec = formatDiffSummary(files: files, repoName: "discord-agent-bridge", branch: "master")
        #expect(spec.title.contains("3"))
        #expect(spec.title.contains("107"))
        #expect(spec.title.contains("32"))
        #expect(spec.footer.contains("discord-agent-bridge"))
        #expect(spec.footer.contains("master"))
        #expect(spec.description.contains("Render/TaskPanelHost.swift"))
    }

    @Test func detachedHeadOmitsTheBranchSegment() {
        let spec = formatDiffSummary(files: files, repoName: "repo", branch: nil)
        #expect(!spec.footer.contains("··"))
        #expect(spec.footer.hasPrefix("repo · "))
    }

    @Test func summaryStaysWithinTheEmbedLimit() {
        let many = (0..<400).map {
            GitChangedFile(path: "some/deep/path/file\($0).swift", kind: .modified, added: 3, removed: 1)
        }
        let spec = formatDiffSummary(files: many, repoName: "repo", branch: "main")
        #expect(spec.description.count <= streamEmbedDescLimit)
    }

    @Test func selectPagesSplitAtTwentyFiveAndDropNothing() {
        let many = (0..<57).map { GitChangedFile(path: "f\($0)", kind: .modified) }
        let pages = diffFileSelectPages(files: many)
        #expect(pages.map(\.count) == [25, 25, 7])
        #expect(pages.flatMap { $0 }.count == many.count)
        #expect(diffFileSelectPages(files: []).isEmpty)
    }

    @Test func fileBodyIsFencedAsDiffAndNotTruncated() {
        let body = "@@ -1 +1 @@\n-old\n+new"
        let out = formatFileDiffBody(file: files[1], diff: body)
        #expect(out.hasPrefix("⎿ Render/ToolActivityHost.swift · +11 -2"))
        #expect(out.contains("```diff"))
        #expect(out.contains("+new"))
    }

    @Test func nestedFenceCannotCloseOurCodeBlock() {
        let out = formatFileDiffBody(file: files[0], diff: "+```swift\n+let a = 1\n+```")
        #expect(!out.replacingOccurrences(of: "```diff", with: "").contains("```swift"))
        #expect(out.contains("'''swift"))
    }

    @Test func emptyDiffReportsItInsteadOfAnEmptyBlock() {
        // R8: never post an empty code fence.
        let out = formatFileDiffBody(file: files[0], diff: "   \n ")
        #expect(!out.contains("```"))
    }

    @Test func threadNameFitsDiscordsLimit() {
        #expect(diffThreadName(fileCount: 4).count <= DiscordText.threadNameLimit)
    }
}
