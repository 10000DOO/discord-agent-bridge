import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("DirectoryBrowser (W11-b2 slice2)")
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

    @Test func renderHasIntoUpHereCancel() throws {
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
        #expect(ids.contains("cancel"))
        #expect(!ids.contains("dir:panel"))
        #expect(!ids.contains("dir:manual"))

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
        let into = isDirectoryBrowserCustomId("dir:into")
        let up = isDirectoryBrowserCustomId("dir:up")
        let here = isDirectoryBrowserCustomId("dir:here")
        let manual = isDirectoryBrowserCustomId("dir:manual")
        let backend = isDirectoryBrowserCustomId("backend")
        #expect(into)
        #expect(up)
        #expect(here)
        #expect(!manual)
        #expect(!backend)
    }
}
