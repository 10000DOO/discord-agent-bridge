import Crypto
import Foundation

/// Snapshot computation + build orchestration for the project RAG feature (WO-2,
/// docs/project-rag-generic-indexing.md §6 WO-2). Pure/async free functions — no actor, no
/// publish/CURRENT handling (that is `ProjectRagStore`, WO-3, D1/3-2(A)).

public enum ProjectRagBuilderError: Error {
    /// `root` does not exist or is not a directory.
    case rootNotFound
    /// `build` was called with an empty `profiles` list (there is always at least
    /// `generic-file-graph` in real runtime configuration).
    case noProfiles
    /// Snapshot digest kept changing across retries — sources were being edited concurrently
    /// with the build (원 설계 §10 "sourceChanging").
    case sourceChanging
}

private let defaultExcludedDirectoryNames: Set<String> = [
    ".git", ".svn", ".hg", ".dab-index", ".claude", "node_modules", "Pods", "DerivedData", "build", ".build", "dist", "vendor"
]
private let maxIndexableFileSizeBytes = 5 * 1024 * 1024 // 5 MiB (원 설계 §6.1)

/// Enumerates `root` (`FileManager.default.enumerator(atPath:)`, mirrors
/// `Codex/CodexDiscovery.swift:160`), hashes every included file, and returns the digest of the
/// sorted `path+sha256` list (원 설계 §6.2). Files whose `path`+`mtimeNs` match `previousFiles`
/// reuse the previous SHA-256 instead of rehashing.
public func computeSnapshot(root: URL, previousFiles: [ProjectFileRecord]?) throws -> ProjectRagSnapshot {
    try snapshotAndDiagnostics(root: root, previousFiles: previousFiles).snapshot
}

/// `build` orchestrates one full index cycle: pick a primary profile, always merge
/// `generic-file-graph`, write artifacts into a project-local tmp dir, and return that dir +
/// manifest for `ProjectRagStore.publish` (WO-3) to rename into place.
public func build(
    root: URL,
    previousManifest: ProjectRagManifest?,
    profiles: [ProjectRagProfile]
) async throws -> ProjectRagBuildResult {
    guard !profiles.isEmpty else { throw ProjectRagBuilderError.noProfiles }

    // Only look up the previous build's files when there is one — `computeSnapshot`'s mtime-based
    // rehash-skip fast path (원 설계 §6.2) needs it, but re-reading it on every retry attempt below
    // would be wasted IO since the CURRENT version's files.ndjson doesn't change mid-build.
    let previousFiles = previousManifest != nil ? ProjectRagStore.previousFiles(root: root) : nil

    let maxAttempts = 3 // initial attempt + up to 2 retries on concurrent source edits (원 설계 §10)
    for attempt in 1...maxAttempts {
        let (snapshotBefore, snapshotDiagnostics) = try snapshotAndDiagnostics(root: root, previousFiles: previousFiles)

        let scored = profiles.map { (profile: $0, score: $0.matches(root: root, files: snapshotBefore.files)) }
        var primary = scored[0].profile
        var bestScore = scored[0].score
        // Tie-break: later entries in `profiles` win (more specific profiles sort last, 원 설계 §5.2).
        for entry in scored.dropFirst() where entry.score >= bestScore {
            bestScore = entry.score
            primary = entry.profile
        }
        let genericProfile = profiles.first { $0.id == "generic-file-graph" }

        var modules: [RagModule] = []
        var symbols: [RagSymbol] = []
        var edges: [RagEdge] = []
        var diagnostics = snapshotDiagnostics
        var semanticCoverage = "generic"
        var contributingProfile = genericProfile ?? primary

        if let genericProfile {
            let generic = try await genericProfile.discover(root: root, files: snapshotBefore.files)
            modules += generic.modules
            symbols += generic.symbols
            edges += generic.edges
            diagnostics += generic.diagnostics
        }

        if primary.id != "generic-file-graph" {
            do {
                let result = try await primary.discover(root: root, files: snapshotBefore.files)
                modules += result.modules
                symbols += result.symbols
                edges += result.edges
                diagnostics += result.diagnostics
                // ponytail: always "full" on success — ProfileDiscovery (frozen in WO-1) carries no
                // partial-coverage signal yet. Upgrade path once a profile (WO-5~7) needs to report
                // partial: add a reserved RagDiagnostic code (or a field) it can emit and check for here.
                semanticCoverage = "full"
                contributingProfile = primary
            } catch {
                diagnostics.append(RagDiagnostic(code: "profileDiscoveryFailed", message: "\(primary.id): \(error)", path: nil))
                semanticCoverage = "generic"
                contributingProfile = genericProfile ?? primary
            }
        }

        let (snapshotAfter, _) = try snapshotAndDiagnostics(root: root, previousFiles: snapshotBefore.files)
        guard snapshotAfter.digest == snapshotBefore.digest else {
            if attempt == maxAttempts { throw ProjectRagBuilderError.sourceChanging }
            continue
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let manifest = ProjectRagManifest(
            schemaVersion: 1,
            generatorVersion: readAppVersion(),
            createdAt: now,
            projectKey: sha256Hex(root.standardizedFileURL.resolvingSymlinksInPath().path),
            projectRootDisplay: root.standardizedFileURL.lastPathComponent,
            profileId: contributingProfile.id,
            profileVersion: contributingProfile.version,
            configDigest: configDigest(root: root),
            snapshotDigest: snapshotAfter.digest,
            semanticCoverage: semanticCoverage,
            statsFiles: snapshotBefore.files.count,
            statsModules: modules.count,
            statsSymbols: symbols.count,
            statsEdges: edges.count,
            lastSuccessfulRefreshAt: now
        )

        // Project-local tmp (not FileManager.default.temporaryDirectory) — ProjectRagStore.publish
        // must rename tmpVersionDir into versions/<id>/ on the same volume (WO-3, D1/3-2(A)).
        let tmpVersionDir = root.appendingPathComponent(".dab-index/tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpVersionDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: tmpVersionDir.appendingPathComponent("manifest.json"))
        try writeNdjson(snapshotBefore.files, to: tmpVersionDir.appendingPathComponent("files.ndjson"), encoder: encoder)
        try writeNdjson(modules, to: tmpVersionDir.appendingPathComponent("modules.ndjson"), encoder: encoder)
        try writeNdjson(symbols, to: tmpVersionDir.appendingPathComponent("symbols.ndjson"), encoder: encoder)
        try writeNdjson(edges, to: tmpVersionDir.appendingPathComponent("edges.ndjson"), encoder: encoder)
        try writeNdjson(diagnostics, to: tmpVersionDir.appendingPathComponent("diagnostics.ndjson"), encoder: encoder)

        return ProjectRagBuildResult(tmpVersionDir: tmpVersionDir, manifest: manifest)
    }
    throw ProjectRagBuilderError.sourceChanging // unreachable — loop above always returns or throws
}

// MARK: - snapshot internals

private func snapshotAndDiagnostics(
    root: URL,
    previousFiles: [ProjectFileRecord]?
) throws -> (snapshot: ProjectRagSnapshot, diagnostics: [RagDiagnostic]) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ProjectRagBuilderError.rootNotFound
    }
    let previousByPath = Dictionary(uniqueKeysWithValues: (previousFiles ?? []).map { ($0.path, $0) })
    let (files, diagnostics) = walkProjectTree(root: root, previousByPath: previousByPath)
    let sortedFiles = files.sorted { $0.path < $1.path }
    let digest = sha256Hex(sortedFiles.map { $0.path + $0.sha256 }.joined(separator: "\n"))
    return (ProjectRagSnapshot(files: sortedFiles, digest: digest), diagnostics)
}

private func walkProjectTree(
    root: URL,
    previousByPath: [String: ProjectFileRecord]
) -> (files: [ProjectFileRecord], diagnostics: [RagDiagnostic]) {
    var files: [ProjectFileRecord] = []
    var diagnostics: [RagDiagnostic] = []
    guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
        return (files, diagnostics)
    }

    for case let relPath as String in enumerator {
        let components = relPath.split(separator: "/").map(String.init)
        if let last = components.last, defaultExcludedDirectoryNames.contains(last) {
            enumerator.skipDescendants()
        }
        if components.contains(where: defaultExcludedDirectoryNames.contains) {
            continue
        }

        let fullPath = (root.path as NSString).appendingPathComponent(relPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
        if isDir.boolValue { continue }

        let attrs = enumerator.fileAttributes
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > maxIndexableFileSizeBytes {
            diagnostics.append(RagDiagnostic(
                code: "excludedLargeFile",
                message: "exceeds \(maxIndexableFileSizeBytes)-byte limit (\(size) bytes)",
                path: relPath
            ))
            continue
        }
        let mtimeNs: Int64 = {
            guard let modDate = attrs?[.modificationDate] as? Date else { return 0 }
            return Int64(modDate.timeIntervalSince1970 * 1_000_000_000)
        }()

        if let previous = previousByPath[relPath], previous.mtimeNs == mtimeNs {
            files.append(ProjectFileRecord(path: relPath, sha256: previous.sha256, size: size, mtimeNs: mtimeNs))
            continue
        }
        guard let data = FileManager.default.contents(atPath: fullPath) else {
            diagnostics.append(RagDiagnostic(code: "readFailed", message: "could not read file contents", path: relPath))
            continue
        }
        files.append(ProjectFileRecord(path: relPath, sha256: sha256Hex(data), size: size, mtimeNs: mtimeNs))
    }
    return (files, diagnostics)
}

// MARK: - manifest/hash helpers

/// SHA-256 of `.dab-index/config.json` if the user created one, else a stable digest for "no
/// config" — this file is never auto-generated (원 설계 §6.1) and Builder only ever reads it.
private func configDigest(root: URL) -> String {
    let configPath = root.appendingPathComponent(".dab-index/config.json")
    guard let data = try? Data(contentsOf: configPath) else { return sha256Hex(Data()) }
    return sha256Hex(data)
}

private func writeNdjson<T: Encodable>(_ records: [T], to url: URL, encoder: JSONEncoder) throws {
    var lines: [String] = []
    lines.reserveCapacity(records.count)
    for record in records {
        lines.append(String(decoding: try encoder.encode(record), as: UTF8.self))
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
}
