import Foundation

/// Reads/writes the on-disk `.dab-index/` project RAG store: the `CURRENT` pointer, immutable
/// `versions/<id>/` directories, and the read-only `dab rag query` candidate lookup (WO-3,
/// docs/project-rag-generic-indexing.md §6 WO-3). An enum of static functions — mirrors
/// `OrchestrationInstaller`'s namespace-only shape (D3): writes are already serialized by
/// `ProjectRagCoordinator` (one build task per project), and concurrent reads only need the
/// OS-level atomic rename `publish` performs, so no extra actor isolation is added here.
public enum ProjectRagStore {

    /// The on-disk manifest schema version this Store understands (원 설계 §7 example: `"schemaVersion": 1`).
    private static let currentSchemaVersion = 1

    // MARK: - Freshness

    /// Decodes the manifest the `CURRENT` pointer names, or nil if there is no index yet or the
    /// on-disk state is missing/corrupt (never throws — callers treat both the same as "no index").
    public static func currentManifest(root: URL) -> ProjectRagManifest? {
        guard let versionDir = currentVersionDir(root: root) else { return nil }
        guard let data = try? Data(contentsOf: versionDir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(ProjectRagManifest.self, from: data)
    }

    /// Decodes the CURRENT version's `files.ndjson` for `ProjectRagBuilder.computeSnapshot`'s
    /// mtime-based rehash-skip fast path (원 설계 §6.2) — nil when there is no previous index yet.
    public static func previousFiles(root: URL) -> [ProjectFileRecord]? {
        guard let versionDir = currentVersionDir(root: root) else { return nil }
        return readNDJSON(versionDir.appendingPathComponent("files.ndjson"), as: ProjectFileRecord.self)
    }

    /// `.missing` when there is no `CURRENT` index yet; otherwise `.fresh` iff `schemaVersion` plus
    /// all of `profileId`/`profileVersion`/`configDigest`/`snapshotDigest` still match what's on
    /// disk, `.stale` otherwise (원 설계 §6.3, R4). The caller (`ProjectRagCoordinator`, WO-12)
    /// recomputes this full identity before deciding whether a rebuild is needed — this Store never
    /// re-derives profile selection or config loading itself (that stays `ProjectRagBuilder`'s job).
    public static func freshness(
        root: URL,
        profileId: String,
        profileVersion: Int,
        configDigest: String,
        snapshotDigest: String
    ) -> IndexFreshness {
        guard let manifest = currentManifest(root: root) else { return .missing }
        guard manifest.schemaVersion == currentSchemaVersion,
              manifest.profileId == profileId,
              manifest.profileVersion == profileVersion,
              manifest.configDigest == configDigest,
              manifest.snapshotDigest == snapshotDigest
        else {
            return .stale
        }
        return .fresh
    }

    // MARK: - Publish

    /// Moves `tmpVersionDir` into `versions/<id>/` (id = its own last path component, assigned by
    /// `ProjectRagBuilder` under `.dab-index/tmp/<uuid>/`) then atomically swaps `CURRENT` to point
    /// at it: write `CURRENT.new`, fsync, `replaceItemAt` (same tmp-write+fsync+rename shape as
    /// `ConfigStore.writeSecureJSON`, `ConfigStore.swift:462-476`, D3/P3). The version move happens
    /// first and independently of the `CURRENT` swap, so a failure at either step never leaves
    /// `CURRENT` pointing at a partial write — it simply stays at whatever it pointed to before.
    public static func publish(root: URL, tmpVersionDir: URL) throws {
        let dabIndex = dabIndexDir(root: root)
        let versionsDir = dabIndex.appendingPathComponent("versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        let id = tmpVersionDir.lastPathComponent
        let destination = versionsDir.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmpVersionDir, to: destination)

        let currentURL = dabIndex.appendingPathComponent("CURRENT")
        let currentNewURL = dabIndex.appendingPathComponent("CURRENT.new")
        try Data("\(id)\n".utf8).write(to: currentNewURL)
        if let handle = try? FileHandle(forWritingTo: currentNewURL) {
            handle.synchronizeFile()
            try? handle.close()
        }
        if FileManager.default.fileExists(atPath: currentURL.path) {
            _ = try FileManager.default.replaceItemAt(currentURL, withItemAt: currentNewURL)
        } else {
            try FileManager.default.moveItem(at: currentNewURL, to: currentURL)
        }
        ensureGitignored(root: root)
    }

    /// Adds a `.dab-index/` line to the target project's `.gitignore`, only when this is a git repo
    /// with an existing `.gitignore` that doesn't already have the entry (원 설계 §2.2 D12 — explicit
    /// exception to "no auto-editing target project files"; reuses the old R2 procedure,
    /// docs/orchestration-lsp-and-project-index.md D4/3-6). Never creates a `.gitignore` that doesn't
    /// already exist.
    private static func ensureGitignored(root: URL) {
        let gitDir = root.appendingPathComponent(".git")
        let gitignoreURL = root.appendingPathComponent(".gitignore")
        guard FileManager.default.fileExists(atPath: gitDir.path),
              let content = try? String(contentsOf: gitignoreURL, encoding: .utf8),
              !content.components(separatedBy: .newlines).contains(".dab-index/")
        else { return }
        let updated = (content.hasSuffix("\n") ? content : content + "\n") + ".dab-index/\n"
        try? updated.write(to: gitignoreURL, atomically: true, encoding: .utf8)
    }

    /// Keeps `CURRENT` plus the 2 most-recently-created other versions; deletes the rest (원 설계 §7).
    /// Ranked by each version's own `manifest.json.createdAt`, not directory name or filesystem
    /// mtime, since `ProjectRagBuilder` assigns plain UUID ids with no timestamp prefix to sort by.
    public static func pruneOldVersions(root: URL) {
        let dabIndex = dabIndexDir(root: root)
        let versionsDir = dabIndex.appendingPathComponent("versions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: versionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        let currentId = currentVersionId(root: root)
        let others = entries.filter { $0.lastPathComponent != currentId }
        let formatter = ISO8601DateFormatter()
        let ranked = others.sorted { lhs, rhs in
            (manifestCreatedAt(at: lhs, formatter: formatter) ?? .distantPast)
                > (manifestCreatedAt(at: rhs, formatter: formatter) ?? .distantPast)
        }
        for stale in ranked.dropFirst(2) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: - Legacy cache migration (R2/D11)

    /// Deletes the old text-cache files (`PROJECT_INDEX.md`+`fingerprint`) this feature replaces, if
    /// either is present. Returns whether anything was removed; never touches `CURRENT`/`versions/`.
    public static func removeLegacyCacheIfPresent(root: URL) -> Bool {
        let dabIndex = dabIndexDir(root: root)
        let indexMd = dabIndex.appendingPathComponent("PROJECT_INDEX.md")
        let fingerprint = dabIndex.appendingPathComponent("fingerprint")
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexMd.path) || fm.fileExists(atPath: fingerprint.path) else {
            return false
        }
        try? fm.removeItem(at: indexMd)
        try? fm.removeItem(at: fingerprint)
        return true
    }

    // MARK: - Query

    /// Candidate lookup for `dab rag query`/`project_search` — pointers only, never source text
    /// (R6). Trusts `CURRENT` wholesale rather than re-hashing the project tree on every call (see
    /// `freshness`'s doc comment and §6 WO-3 "구현 결정"): this is the interactive read path, real
    /// revalidation belongs to `/orchestration` and the hourly scheduler, so a present index is
    /// always reported `.fresh` here (never re-derives `.stale` from this call).
    public static func query(root: URL, request: ProjectRagQueryRequest) -> ProjectRagQueryResult {
        guard let manifest = currentManifest(root: root), let versionDir = currentVersionDir(root: root) else {
            return ProjectRagQueryResult(freshness: .missing, warnings: ["missing"])
        }

        let modules = readNDJSON(versionDir.appendingPathComponent("modules.ndjson"), as: RagModule.self)
        let symbols = readNDJSON(versionDir.appendingPathComponent("symbols.ndjson"), as: RagSymbol.self)
        let edges = readNDJSON(versionDir.appendingPathComponent("edges.ndjson"), as: RagEdge.self)

        // Ranking order (원 설계 §9): exact symbol > selector/name prefix > changed-path의 같은 모듈 >
        // import/include/target edge > exact keyword.
        let changedPaths = Set(request.paths)
        let changedModuleIds = Set(modules.filter { !Set($0.paths).isDisjoint(with: changedPaths) }.map(\.id))
        let edgeConnectedModuleIds = Set(edges.flatMap { edge -> [String] in
            if changedModuleIds.contains(edge.fromModuleId) { return [edge.toModuleId] }
            if changedModuleIds.contains(edge.toModuleId) { return [edge.fromModuleId] }
            return []
        })
        let exactSymbolModuleIds = Set(symbols.filter { request.symbols.contains($0.name) }.compactMap(\.moduleId))
        let prefixSymbolModuleIds = Set(symbols.filter { isSelectorOrNamePrefixMatch($0.name, queries: request.symbols) }.compactMap(\.moduleId))

        let rankedSymbols = symbols
            .map { symbol in
                (symbol, symbolScore(symbol, request: request, changedModuleIds: changedModuleIds, edgeConnectedModuleIds: edgeConnectedModuleIds))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.path != rhs.0.path { return lhs.0.path < rhs.0.path }
                if lhs.0.line != rhs.0.line { return lhs.0.line < rhs.0.line }
                return lhs.0.name < rhs.0.name
            }
            .map(\.0)

        let rankedModules = modules
            .map { module in
                (
                    module,
                    moduleScore(
                        module, request: request,
                        exactSymbolModuleIds: exactSymbolModuleIds, prefixSymbolModuleIds: prefixSymbolModuleIds,
                        changedModuleIds: changedModuleIds, edgeConnectedModuleIds: edgeConnectedModuleIds
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            }
            .map(\.0)

        let limitedModules = Array(rankedModules.prefix(max(0, request.limitModules)))
        let limitedSymbols = Array(rankedSymbols.prefix(max(0, request.limitSymbols)))

        // Edges are scoped to the (already-limited) returned modules rather than truncated by a
        // separate limit — `ProjectRagQueryRequest` has no `limitEdges` field (WO-1).
        let finalModuleIds = Set(limitedModules.map(\.id))
        let relatedEdges = edges
            .filter { finalModuleIds.contains($0.fromModuleId) || finalModuleIds.contains($0.toModuleId) }
            .sorted { lhs, rhs in
                if lhs.fromModuleId != rhs.fromModuleId { return lhs.fromModuleId < rhs.fromModuleId }
                if lhs.toModuleId != rhs.toModuleId { return lhs.toModuleId < rhs.toModuleId }
                if lhs.path != rhs.path { return lhs.path < rhs.path }
                return lhs.line < rhs.line
            }

        var warnings: [String] = []
        if manifest.semanticCoverage == "partial" { warnings.append("partial") }

        return ProjectRagQueryResult(
            freshness: .fresh,
            indexVersion: versionDir.lastPathComponent,
            modules: limitedModules,
            symbols: limitedSymbols,
            edges: relatedEdges,
            warnings: warnings
        )
    }

    // MARK: - Ranking helpers

    private static func isSelectorOrNamePrefixMatch(_ name: String, queries: [String]) -> Bool {
        queries.contains { name.hasPrefix($0) || $0.hasPrefix(name) }
    }

    private static func symbolScore(
        _ symbol: RagSymbol,
        request: ProjectRagQueryRequest,
        changedModuleIds: Set<String>,
        edgeConnectedModuleIds: Set<String>
    ) -> Int {
        if request.symbols.contains(symbol.name) { return 5 } // exact symbol
        if isSelectorOrNamePrefixMatch(symbol.name, queries: request.symbols) { return 4 } // selector/name prefix
        if let moduleId = symbol.moduleId, changedModuleIds.contains(moduleId) { return 3 } // changed path의 같은 모듈
        if let moduleId = symbol.moduleId, edgeConnectedModuleIds.contains(moduleId) { return 2 } // import/include/target edge
        if request.terms.contains(symbol.name) { return 1 } // exact keyword
        return 0
    }

    private static func moduleScore(
        _ module: RagModule,
        request: ProjectRagQueryRequest,
        exactSymbolModuleIds: Set<String>,
        prefixSymbolModuleIds: Set<String>,
        changedModuleIds: Set<String>,
        edgeConnectedModuleIds: Set<String>
    ) -> Int {
        if exactSymbolModuleIds.contains(module.id) { return 5 }
        if prefixSymbolModuleIds.contains(module.id) { return 4 }
        if changedModuleIds.contains(module.id) { return 3 }
        if edgeConnectedModuleIds.contains(module.id) { return 2 }
        if request.terms.contains(where: { module.displayName.contains($0) || module.id.contains($0) }) { return 1 }
        return 0
    }

    // MARK: - IO helpers

    private static func dabIndexDir(root: URL) -> URL {
        root.appendingPathComponent(".dab-index", isDirectory: true)
    }

    private static func currentVersionId(root: URL) -> String? {
        let currentFile = dabIndexDir(root: root).appendingPathComponent("CURRENT")
        guard let raw = try? String(contentsOf: currentFile, encoding: .utf8) else { return nil }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func currentVersionDir(root: URL) -> URL? {
        guard let id = currentVersionId(root: root) else { return nil }
        return dabIndexDir(root: root).appendingPathComponent("versions", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    private static func manifestCreatedAt(at versionDir: URL, formatter: ISO8601DateFormatter) -> Date? {
        guard let data = try? Data(contentsOf: versionDir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(ProjectRagManifest.self, from: data) else { return nil }
        return formatter.date(from: manifest.createdAt)
    }

    private static func readNDJSON<T: Decodable>(_ url: URL, as type: T.Type) -> [T] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(T.self, from: lineData)
        }
    }
}
