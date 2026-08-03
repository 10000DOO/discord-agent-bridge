import Foundation
import Testing
@testable import DiscordAgentBridge

private struct StubError: Error, Sendable {}

/// Minimal `ProjectRagProfile` stub (WO-2 does not depend on the real WO-4~7 profiles).
private struct StubProfile: ProjectRagProfile {
    let id: String
    let version: Int
    let score: Int
    var discovery: ProfileDiscovery = ProfileDiscovery()
    var shouldThrow: Bool = false

    func matches(root: URL, files: [ProjectFileRecord]) -> Int { score }
    func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery {
        if shouldThrow { throw StubError() }
        return discovery
    }
}

private func tempProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-rag-builder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func readNdjson<T: Decodable>(_ type: T.Type, at url: URL) throws -> [T] {
    let content = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try content.split(separator: "\n").map { try decoder.decode(T.self, from: Data($0.utf8)) }
}

@Suite("ProjectRagBuilder.computeSnapshot")
struct ProjectRagBuilderSnapshotTests {
    @Test func unchangedMtimeReusesPreviousHashRealChangeTriggersRehash() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let filePath = root.appendingPathComponent("a.txt")
        try "hello".write(to: filePath, atomically: true, encoding: .utf8)

        let first = try computeSnapshot(root: root, previousFiles: nil)
        let record = try #require(first.files.first { $0.path == "a.txt" })

        // Same path + same mtimeNs (file untouched) but a deliberately wrong previous sha256 —
        // if the fast mtime prefilter engages, the stale digest gets reused verbatim.
        let stalePrevious = ProjectFileRecord(path: "a.txt", sha256: "deadbeef", size: record.size, mtimeNs: record.mtimeNs)
        let second = try computeSnapshot(root: root, previousFiles: [stalePrevious])
        let secondRecord = try #require(second.files.first { $0.path == "a.txt" })
        #expect(secondRecord.sha256 == "deadbeef", "unchanged mtime must skip rehashing and reuse the previous digest")

        // A previous record whose mtimeNs no longer matches must force a real rehash.
        let mismatchedPrevious = ProjectFileRecord(path: "a.txt", sha256: "deadbeef", size: record.size, mtimeNs: record.mtimeNs + 1)
        let third = try computeSnapshot(root: root, previousFiles: [mismatchedPrevious])
        let thirdRecord = try #require(third.files.first { $0.path == "a.txt" })
        #expect(thirdRecord.sha256 == record.sha256, "changed mtime must trigger a real rehash, not reuse the stale digest")
    }

    @Test func excludesDefaultDirectoriesAndOversizedFilesButKeepsProjectMetadata() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try "ignored".write(to: root.appendingPathComponent("node_modules/dep/index.js"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ignored".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

        try "kept".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let bigData = Data(repeating: 0x41, count: 6 * 1024 * 1024) // 6 MiB > 5 MiB limit
        try bigData.write(to: root.appendingPathComponent("huge.bin"))

        let snapshot = try computeSnapshot(root: root, previousFiles: nil)
        let paths = Set(snapshot.files.map(\.path))
        #expect(!paths.contains("node_modules/dep/index.js"), "excluded directory contents must not be indexed")
        #expect(!paths.contains(".git/HEAD"), "excluded directory contents must not be indexed")
        #expect(!paths.contains("huge.bin"), "files over the 5 MiB limit must be skipped")
        #expect(paths.contains("Package.swift"), "project metadata files must not be excluded")
    }
}

@Suite("ProjectRagBuilder.build")
struct ProjectRagBuilderBuildTests {
    @Test func primarySucceedsMergesGenericAndPrimaryWithFullCoverage() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try Data(repeating: 0x41, count: 6 * 1024 * 1024).write(to: root.appendingPathComponent("huge.bin"))

        let generic = StubProfile(
            id: "generic-file-graph", version: 1, score: 10,
            discovery: ProfileDiscovery(modules: [RagModule(id: "generic-mod", displayName: "generic", paths: ["a.swift"])])
        )
        let primary = StubProfile(
            id: "swift-spm-xcode", version: 1, score: 90,
            discovery: ProfileDiscovery(symbols: [RagSymbol(name: "Foo", kind: "class", path: "a.swift", line: 1)])
        )

        let result = try await build(root: root, previousManifest: nil, profiles: [generic, primary])
        defer { try? FileManager.default.removeItem(at: result.tmpVersionDir) }

        #expect(result.manifest.semanticCoverage == "full")
        #expect(result.manifest.profileId == "swift-spm-xcode")

        let modules = try readNdjson(RagModule.self, at: result.tmpVersionDir.appendingPathComponent("modules.ndjson"))
        let symbols = try readNdjson(RagSymbol.self, at: result.tmpVersionDir.appendingPathComponent("symbols.ndjson"))
        #expect(modules.map(\.id) == ["generic-mod"])
        #expect(symbols.map(\.name) == ["Foo"])

        let diagnostics = try readNdjson(RagDiagnostic.self, at: result.tmpVersionDir.appendingPathComponent("diagnostics.ndjson"))
        #expect(diagnostics.contains { $0.code == "excludedLargeFile" })
    }

    @Test func primaryFailsPublishesGenericOnlyWithGenericCoverage() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "content".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

        let generic = StubProfile(
            id: "generic-file-graph", version: 1, score: 10,
            discovery: ProfileDiscovery(modules: [RagModule(id: "generic-mod", displayName: "generic", paths: ["a.swift"])])
        )
        let primary = StubProfile(id: "swift-spm-xcode", version: 1, score: 90, shouldThrow: true)

        let result = try await build(root: root, previousManifest: nil, profiles: [generic, primary])
        defer { try? FileManager.default.removeItem(at: result.tmpVersionDir) }

        #expect(result.manifest.semanticCoverage == "generic")
        #expect(result.manifest.profileId == "generic-file-graph")

        let symbols = try readNdjson(RagSymbol.self, at: result.tmpVersionDir.appendingPathComponent("symbols.ndjson"))
        #expect(symbols.isEmpty, "the failed primary profile's symbols must not be published")

        let modules = try readNdjson(RagModule.self, at: result.tmpVersionDir.appendingPathComponent("modules.ndjson"))
        #expect(modules.map(\.id) == ["generic-mod"], "generic result is still published")

        let diagnostics = try readNdjson(RagDiagnostic.self, at: result.tmpVersionDir.appendingPathComponent("diagnostics.ndjson"))
        #expect(diagnostics.contains { $0.code == "profileDiscoveryFailed" })
    }

    /// Bug fix regression: `build()` used to always pass `previousFiles: nil` to `computeSnapshot`,
    /// so the mtime-based rehash-skip fast path never engaged on the real build path (only direct
    /// `computeSnapshot` unit tests exercised it). This drives the fast path through `build()` itself.
    @Test func build_reusesPreviousHashForUnchangedFileViaPublishedManifest() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let generic = StubProfile(id: "generic-file-graph", version: 1, score: 10)

        let first = try await build(root: root, previousManifest: nil, profiles: [generic])
        try ProjectRagStore.publish(root: root, tmpVersionDir: first.tmpVersionDir)

        let currentId = try String(contentsOf: root.appendingPathComponent(".dab-index/CURRENT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filesNdjsonURL = root.appendingPathComponent(".dab-index/versions/\(currentId)/files.ndjson")
        let publishedFiles = try readNdjson(ProjectFileRecord.self, at: filesNdjsonURL)
        let publishedRecord = try #require(publishedFiles.first { $0.path == "a.txt" })

        // Corrupt the just-published sha256 (mtime untouched) — if `build()`'s fast path actually
        // reads this previous version via `ProjectRagStore.previousFiles`, the corrupted digest
        // resurfaces in the next build instead of a freshly computed one.
        let corrupted = ProjectFileRecord(path: publishedRecord.path, sha256: "deadbeef", size: publishedRecord.size, mtimeNs: publishedRecord.mtimeNs)
        let corruptedLine = String(decoding: try JSONEncoder().encode(corrupted), as: UTF8.self)
        try corruptedLine.write(to: filesNdjsonURL, atomically: true, encoding: .utf8)

        let second = try await build(root: root, previousManifest: first.manifest, profiles: [generic])
        defer { try? FileManager.default.removeItem(at: second.tmpVersionDir) }

        let secondFiles = try readNdjson(ProjectFileRecord.self, at: second.tmpVersionDir.appendingPathComponent("files.ndjson"))
        let secondRecord = try #require(secondFiles.first { $0.path == "a.txt" })
        #expect(secondRecord.sha256 == "deadbeef", "build() must thread ProjectRagStore.previousFiles into computeSnapshot's rehash-skip fast path")
    }
}

@Suite("ProjectRagBuilder.build with real profiles")
struct ProjectRagBuilderRealProfilesTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-rag-builder-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ root: URL, _ relativePath: String, _ content: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Regression test for the primary-profile-selection bug: `GenericFileGraphProfile.matches`
    /// used to always return 100, which a specialized profile's max score of 90 (apple-native/
    /// typescript-node) could never beat — so generic always won as primary even on an
    /// Objective-C project, and the specialized profile's richer symbol/edge extraction never
    /// reached the published index. Uses the real `GenericFileGraphProfile` + `AppleNativeProfile`
    /// (not stubs), so a regression in either profile's actual `matches` score is also caught here.
    @Test func appleNativeProfileWinsOverGenericAsPrimaryOnRealObjcProject() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(root, "Sample.xcodeproj/project.pbxproj", """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tobjectVersion = 56;
        \tobjects = {

        /* Begin PBXNativeTarget section */
        \t\tAAAA0000AAAA0000AAAA0001 /* SampleApp */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = AAAA0000AAAA0000AAAA0002 /* Build configuration list for PBXNativeTarget "SampleApp" */;
        \t\t\tbuildPhases = (
        \t\t\t);
        \t\t\tdependencies = (
        \t\t\t\tAAAA0000AAAA0000AAAA0003 /* PBXTargetDependency */,
        \t\t\t);
        \t\t\tname = SampleApp;
        \t\t\tproductName = SampleApp;
        \t\t};
        \t\tAAAA0000AAAA0000AAAA0004 /* SampleKit */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = AAAA0000AAAA0000AAAA0005 /* Build configuration list for PBXNativeTarget "SampleKit" */;
        \t\t\tbuildPhases = (
        \t\t\t);
        \t\t\tdependencies = (
        \t\t\t);
        \t\t\tname = SampleKit;
        \t\t\tproductName = SampleKit;
        \t\t};
        /* End PBXNativeTarget section */

        /* Begin PBXTargetDependency section */
        \t\tAAAA0000AAAA0000AAAA0003 /* PBXTargetDependency */ = {
        \t\t\tisa = PBXTargetDependency;
        \t\t\ttarget = AAAA0000AAAA0000AAAA0004 /* SampleKit */;
        \t\t\ttargetProxy = AAAA0000AAAA0000AAAA0006 /* PBXContainerItemProxy */;
        \t\t};
        /* End PBXTargetDependency section */

        \t};
        \trootObject = AAAA0000AAAA0000AAAA0007 /* Project object */;
        }
        """)
        try writeFile(root, "SampleApp/AppDelegate.h", """
        #import <UIKit/UIKit.h>

        @interface AppDelegate : UIResponder
        - (BOOL)applicationDidFinishLaunching;
        @end
        """)
        try writeFile(root, "SampleApp/AppDelegate.m", """
        #import "AppDelegate.h"

        @implementation AppDelegate
        - (BOOL)applicationDidFinishLaunching {
            return YES;
        }
        @end
        """)

        let result = try await build(
            root: root, previousManifest: nil,
            profiles: [GenericFileGraphProfile(), AppleNativeProfile()]
        )
        defer { try? FileManager.default.removeItem(at: result.tmpVersionDir) }

        #expect(result.manifest.profileId == "apple-native")
        #expect(result.manifest.semanticCoverage == "full")

        let symbols = try readNdjson(RagSymbol.self, at: result.tmpVersionDir.appendingPathComponent("symbols.ndjson"))
        #expect(symbols.contains { $0.kind == "interface" && $0.name == "AppDelegate" })
        #expect(symbols.contains { $0.kind == "selector" && $0.name == "applicationDidFinishLaunching" })

        let edges = try readNdjson(RagEdge.self, at: result.tmpVersionDir.appendingPathComponent("edges.ndjson"))
        #expect(edges.contains {
            $0.kind == "target-dependency" && $0.fromModuleId == "SampleApp" && $0.toModuleId == "SampleKit"
        })
        #expect(edges.contains {
            $0.kind == "import" && $0.fromModuleId == "SampleApp/AppDelegate.m" && $0.toModuleId == "SampleApp/AppDelegate.h"
        })
    }
}
