import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("DirectoryBrowser (W11-b2 folder)")
struct DirectoryBrowserTests {
    private func makeTempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub").appendingPathComponent("nested"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("file.txt").path,
            contents: Data("x".utf8)
        )
        return root
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test func listsSubdirsExcludesFilesDotFoldersSortedLast() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aaa"), withIntermediateDirectories: true)
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(b.listChildren() == ["aaa", "sub", ".hidden"])
    }

    @Test func ordersNonDotBeforeDotAlphabeticalWithinGroups() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        for name in ["banana", ".zeta", "apple", ".alpha", "cherry"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        let list = b.listChildren()
        #expect(list == ["apple", "banana", "cherry", "sub", ".alpha", ".zeta"])
        let firstDot = list.firstIndex(where: { $0.hasPrefix(".") })!
        #expect(list[..<firstDot].allSatisfy { !$0.hasPrefix(".") })
        #expect(list[firstDot...].allSatisfy { $0.hasPrefix(".") })
    }

    @Test func capsAt25AndPrefersNonDotFolders() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        for i in 0..<30 {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".hidden\(i)"),
                withIntermediateDirectories: true
            )
        }
        for name in ["proj-a", "proj-b", "proj-c"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        let list = b.listChildren()
        #expect(list.count == 25)
        for name in ["proj-a", "proj-b", "proj-c", "sub"] {
            #expect(list.contains(name))
        }
    }

    @Test func intoAndUpNavigate() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(b.into("sub"))
        #expect(b.cwd() == root.appendingPathComponent("sub").path)
        #expect(b.into("nested"))
        #expect(b.cwd() == root.appendingPathComponent("sub").appendingPathComponent("nested").path)
        #expect(b.up())
        #expect(b.cwd() == root.appendingPathComponent("sub").path)
        #expect(b.select() == root.appendingPathComponent("sub").path)
    }

    @Test func intoHiddenFolderWorks() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(b.into(".hidden"))
        #expect(b.cwd() == root.appendingPathComponent(".hidden").path)
    }

    @Test func cannotAscendAboveAllowedRoot() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(!b.up())
        #expect(b.cwd() == root.path)
    }

    @Test func intoDotDotEscapesRejected() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let sub = root.appendingPathComponent("sub").path
        let b = DirectoryBrowser(allowedRoots: [sub], startPath: sub)
        #expect(!b.into(".."))
        #expect(b.cwd() == sub)
    }

    @Test func intoNonexistentOrFileIsNoop() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(!b.into("does-not-exist"))
        #expect(!b.into("file.txt"))
        #expect(b.cwd() == root.path)
    }

    @Test func clampsStartPathOutsideRoots() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let sub = root.appendingPathComponent("sub").path
        let b = DirectoryBrowser(allowedRoots: [sub], startPath: NSTemporaryDirectory())
        #expect(b.cwd() == sub)
    }

    @Test func goToJumpsAndRejectsInvalid() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let nested = root.appendingPathComponent("sub").appendingPathComponent("nested").path
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(b.goTo(nested))
        #expect(b.cwd() == nested)

        let sub = root.appendingPathComponent("sub").path
        let b2 = DirectoryBrowser(allowedRoots: [sub], startPath: sub)
        #expect(!b2.goTo(root.appendingPathComponent("sub").appendingPathComponent("nope").path))
        #expect(!b2.goTo(root.appendingPathComponent("file.txt").path))
        #expect(!b2.goTo(NSTemporaryDirectory()))
        #expect(b2.cwd() == sub)
    }

    @Test func unboundedCanReachFilesystemRoot() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(startPath: root.path)
        var guardCount = 0
        while b.up() && guardCount < 100 { guardCount += 1 }
        // On POSIX, root is "/".
        #expect(b.cwd() == "/")
        #expect(!b.up())
    }

    @Test func renderHasIntoUpHereCreateManualCancel() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        let view = b.render()
        #expect(view.description.contains(root.path))
        let ids = view.rows.flatMap { row in
            row.components.map { c -> String in
                switch c {
                case .select(let id, _, _): return id
                case .button(let id, _, _, _): return id
                }
            }
        }
        #expect(ids.contains("dir:into"))
        #expect(ids.contains("dir:up"))
        #expect(ids.contains("dir:here"))
        #expect(ids.contains("dir:create"))
        #expect(ids.contains("dir:manual"))
        #expect(ids.contains("cancel"))
        #expect(!ids.contains("dir:panel")) // nativePanel default off

        // up disabled at root boundary
        let upDisabled = view.rows.flatMap(\.components).contains { c in
            if case .button(let id, _, _, let disabled) = c { return id == "dir:up" && disabled }
            return false
        }
        #expect(upDisabled)

        #expect(b.into("sub"))
        let upEnabled = b.render().rows.flatMap(\.components).contains { c in
            if case .button(let id, _, _, let disabled) = c { return id == "dir:up" && !disabled }
            return false
        }
        #expect(upEnabled)
    }

    @Test func renderShowsPanelWhenNativePanelEnabled() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path, nativePanel: true)
        let ids = b.render().rows.flatMap { row in
            row.components.map { c -> String in
                switch c {
                case .select(let id, _, _): return id
                case .button(let id, _, _, _): return id
                }
            }
        }
        #expect(ids.contains("dir:panel"))
        #expect(ids.contains("dir:manual"))
    }

    @Test func createChildMkdirAndEnter() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        switch b.createChild("new-folder", enter: true) {
        case .ok(let path):
            #expect(path == root.appendingPathComponent("new-folder").path)
            #expect(b.cwd() == path)
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        default:
            Issue.record("expected ok")
        }
    }

    @Test func createChildWithoutEnterStaysAtParent() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        switch b.createChild("stays", enter: false) {
        case .ok(let path):
            #expect(path == root.appendingPathComponent("stays").path)
            #expect(b.cwd() == root.path)
            #expect(b.listChildren().contains("stays"))
        default:
            Issue.record("expected ok")
        }
    }

    @Test func createChildRejectsTraversalAndAbsolute() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        for bad in ["..", "a/b", "a\\b", "/etc", ".", ""] {
            #expect(b.createChild(bad) == .invalidName, "should reject \(bad)")
        }
        #expect(b.cwd() == root.path)
    }

    @Test func createChildConfinedUnderAllowedRoot() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let sub = root.appendingPathComponent("sub").path
        let b = DirectoryBrowser(allowedRoots: [sub], startPath: sub)
        // Safe name still lands under sub — confine ok.
        switch b.createChild("ok", enter: true) {
        case .ok(let path):
            #expect(path.hasPrefix(sub))
        default:
            Issue.record("expected ok under sub")
        }
    }

    @Test func isSafeFolderNameRules() {
        #expect(isSafeFolderName("my-project"))
        #expect(isSafeFolderName("a"))
        #expect(!isSafeFolderName(""))
        #expect(!isSafeFolderName("."))
        #expect(!isSafeFolderName(".."))
        #expect(!isSafeFolderName("a/b"))
        #expect(!isSafeFolderName("a\\b"))
        #expect(!isSafeFolderName("/abs"))
    }

    @Test func goToAbsoluteWithinRoots() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let nested = root.appendingPathComponent("sub").appendingPathComponent("nested").path
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        #expect(b.goTo(nested))
        #expect(b.cwd() == nested)
        #expect(!b.goTo("/no/such/path-\(UUID().uuidString)"))
        #expect(b.cwd() == nested)
    }

    @Test func emptyFolderSelectHasSentinel() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let empty = root.appendingPathComponent("sub").appendingPathComponent("nested").path
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: empty)
        let opts = b.render().rows.flatMap(\.components).compactMap { c -> [WizardSelectOption]? in
            if case .select(let id, _, let o) = c, id == "dir:into" { return o }
            return nil
        }.first
        #expect(opts?.count == 1)
        #expect(opts?.first?.value == "__none__")
    }

    @Test func recognizesDirCustomIds() {
        #expect(isDirectoryBrowserCustomId("dir:into"))
        #expect(isDirectoryBrowserCustomId("dir:up"))
        #expect(isDirectoryBrowserCustomId("dir:here"))
        #expect(isDirectoryBrowserCustomId("dir:create"))
        #expect(isDirectoryBrowserCustomId("dir:manual"))
        #expect(isDirectoryBrowserCustomId("dir:panel"))
        #expect(!isDirectoryBrowserCustomId("backend"))
        #expect(isDirectoryBrowserCustomId("dir:resume"))
    }

    @Test func renderIncludesResumeButton() throws {
        let root = try makeTempTree()
        defer { cleanup(root) }
        let b = DirectoryBrowser(allowedRoots: [root.path], startPath: root.path)
        let buttonIds = b.render().rows.flatMap(\.components).compactMap { c -> String? in
            if case .button(let id, _, _, _) = c { return id }
            return nil
        }
        #expect(buttonIds.contains("dir:resume"))
        #expect(buttonIds.contains("dir:here"))
        #expect(buttonIds.contains("dir:create"))
    }
}
