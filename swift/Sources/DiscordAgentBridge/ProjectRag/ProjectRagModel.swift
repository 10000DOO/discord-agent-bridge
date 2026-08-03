import Foundation

/// Shared data contract for the project RAG feature (WO-1, docs/project-rag-generic-indexing.md §6 WO-1).
/// Pure data types + the `ProjectRagProfile` protocol only — no IO/actor/network code lives here.
/// `ProjectRagBuilder` (WO-2), `ProjectRagStore` (WO-3), the profile implementations (WO-4~7),
/// `ProjectRagCoordinator` (WO-12), and the CLI (WO-13) all depend on this single file.

/// One indexed file's identity + fast-prefilter metadata (root-relative path).
public struct ProjectFileRecord: Sendable, Codable, Equatable {
    public var path: String       // root 기준 상대경로
    public var sha256: String
    public var size: Int
    public var language: String?
    public var role: String?      // 예: "public-header"
    public var mtimeNs: Int64     // 빠른 사전필터 용도, 신뢰 근거 아님(원 설계 §6.2)

    public init(path: String, sha256: String, size: Int, language: String? = nil, role: String? = nil, mtimeNs: Int64) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.language = language
        self.role = role
        self.mtimeNs = mtimeNs
    }
}

/// Result of enumerating + hashing the project tree at a point in time.
public struct ProjectRagSnapshot: Sendable {
    public var files: [ProjectFileRecord]
    public var digest: String     // 정렬된 "path+sha256" 목록의 SHA-256(원 설계 §6.2)

    public init(files: [ProjectFileRecord], digest: String) {
        self.files = files
        self.digest = digest
    }
}

/// A coarse grouping of files (e.g. a directory, an SPM target, an Xcode target).
public struct RagModule: Sendable, Codable, Equatable {
    public var id: String; public var displayName: String; public var paths: [String]

    public init(id: String, displayName: String, paths: [String]) {
        self.id = id
        self.displayName = displayName
        self.paths = paths
    }
}

/// A single named symbol candidate (class/function/selector/etc.) discovered by a profile.
public struct RagSymbol: Sendable, Codable, Equatable {
    public var name: String; public var kind: String; public var path: String; public var line: Int; public var moduleId: String?

    public init(name: String, kind: String, path: String, line: Int, moduleId: String? = nil) {
        self.name = name
        self.kind = kind
        self.path = path
        self.line = line
        self.moduleId = moduleId
    }
}

/// A directed relationship between two modules (import/include/target dependency), with a source pointer.
public struct RagEdge: Sendable, Codable, Equatable {
    public var kind: String; public var fromModuleId: String; public var toModuleId: String; public var path: String; public var line: Int

    public init(kind: String, fromModuleId: String, toModuleId: String, path: String, line: Int) {
        self.kind = kind
        self.fromModuleId = fromModuleId
        self.toModuleId = toModuleId
        self.path = path
        self.line = line
    }
}

/// A non-fatal note from discovery (e.g. an excluded large file, a parse skip).
public struct RagDiagnostic: Sendable, Codable, Equatable {
    public var code: String; public var message: String; public var path: String?

    public init(code: String, message: String, path: String? = nil) {
        self.code = code
        self.message = message
        self.path = path
    }
}

/// Everything one `ProjectRagProfile.discover` call produced.
public struct ProfileDiscovery: Sendable {
    public var modules: [RagModule]; public var symbols: [RagSymbol]; public var edges: [RagEdge]; public var diagnostics: [RagDiagnostic]

    public init(modules: [RagModule] = [], symbols: [RagSymbol] = [], edges: [RagEdge] = [], diagnostics: [RagDiagnostic] = []) {
        self.modules = modules
        self.symbols = symbols
        self.edges = edges
        self.diagnostics = diagnostics
    }
}

/// A language/build-system-specific indexing strategy (`generic-file-graph`, `objc-xcode`, `swift-spm-xcode`,
/// `typescript-node` — WO-4~7). `matches` scores applicability 0...100 (원 설계 §5.1); `discover` does the
/// actual (LLM-free, R6) parsing.
public protocol ProjectRagProfile: Sendable {
    var id: String { get }
    var version: Int { get }
    func matches(root: URL, files: [ProjectFileRecord]) -> Int   // 0...100, 원 설계 §5.1
    func discover(root: URL, files: [ProjectFileRecord]) async throws -> ProfileDiscovery
}

/// Persisted `versions/<id>/manifest.json` contents — the freshness/identity record for one build.
public struct ProjectRagManifest: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var generatorVersion: String   // readAppVersion() 값 그대로(Update/Version.swift:82)
    public var createdAt: String          // ISO-8601 UTC
    public var projectKey: String         // SHA-256(정규화 경로), 원 설계 §4 하단
    public var projectRootDisplay: String // root의 마지막 경로 요소만(원 설계 §4)
    public var profileId: String
    public var profileVersion: Int
    public var configDigest: String
    public var snapshotDigest: String
    public var gitHead: String?
    public var gitDirty: Bool?
    public var semanticCoverage: String   // "full" | "partial" | "generic"
    public var statsFiles: Int
    public var statsModules: Int
    public var statsSymbols: Int
    public var statsEdges: Int
    public var lastSuccessfulRefreshAt: String

    public init(
        schemaVersion: Int,
        generatorVersion: String,
        createdAt: String,
        projectKey: String,
        projectRootDisplay: String,
        profileId: String,
        profileVersion: Int,
        configDigest: String,
        snapshotDigest: String,
        gitHead: String? = nil,
        gitDirty: Bool? = nil,
        semanticCoverage: String,
        statsFiles: Int,
        statsModules: Int,
        statsSymbols: Int,
        statsEdges: Int,
        lastSuccessfulRefreshAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatorVersion = generatorVersion
        self.createdAt = createdAt
        self.projectKey = projectKey
        self.projectRootDisplay = projectRootDisplay
        self.profileId = profileId
        self.profileVersion = profileVersion
        self.configDigest = configDigest
        self.snapshotDigest = snapshotDigest
        self.gitHead = gitHead
        self.gitDirty = gitDirty
        self.semanticCoverage = semanticCoverage
        self.statsFiles = statsFiles
        self.statsModules = statsModules
        self.statsSymbols = statsSymbols
        self.statsEdges = statsEdges
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
    }
}

/// 원 설계 §6.3 — CURRENT manifest 대비 현재 스냅샷의 최신성 상태.
public enum IndexFreshness: String, Sendable, Codable { case fresh, building, stale, failed, missing }

/// `ProjectRagBuilder.build` 결과 — 아직 publish 전, tmp 디렉터리에 놓인 산출물(D1/3-2(A)).
public struct ProjectRagBuildResult: Sendable {
    public var tmpVersionDir: URL; public var manifest: ProjectRagManifest

    public init(tmpVersionDir: URL, manifest: ProjectRagManifest) {
        self.tmpVersionDir = tmpVersionDir
        self.manifest = manifest
    }
}

/// `ProjectRagCoordinator.ensureIndexed` 결과.
public struct ProjectRagEnsureResult: Sendable {
    public var freshness: IndexFreshness; public var projectRagEnabled: Bool; public var errorSummary: String?

    public init(freshness: IndexFreshness, projectRagEnabled: Bool, errorSummary: String? = nil) {
        self.freshness = freshness
        self.projectRagEnabled = projectRagEnabled
        self.errorSummary = errorSummary
    }
}

/// `dab rag query` / `project_search` MCP 조회 요청.
public struct ProjectRagQueryRequest: Sendable {
    public var paths: [String] = []; public var symbols: [String] = []; public var terms: [String] = []
    public var limitModules: Int = 4; public var limitSymbols: Int = 12

    public init(paths: [String] = [], symbols: [String] = [], terms: [String] = [], limitModules: Int = 4, limitSymbols: Int = 12) {
        self.paths = paths
        self.symbols = symbols
        self.terms = terms
        self.limitModules = limitModules
        self.limitSymbols = limitSymbols
    }
}

/// `dab rag query` / `project_search` MCP 조회 응답 — 원문 없이 후보 포인터만(R6).
public struct ProjectRagQueryResult: Sendable, Encodable {
    public var freshness: IndexFreshness; public var indexVersion: String?
    public var modules: [RagModule]; public var symbols: [RagSymbol]; public var edges: [RagEdge]
    public var warnings: [String]   // 예: ["stale"], ["partial"] — 원문 없음(R6)

    public init(freshness: IndexFreshness, indexVersion: String? = nil, modules: [RagModule] = [], symbols: [RagSymbol] = [], edges: [RagEdge] = [], warnings: [String] = []) {
        self.freshness = freshness
        self.indexVersion = indexVersion
        self.modules = modules
        self.symbols = symbols
        self.edges = edges
        self.warnings = warnings
    }
}
