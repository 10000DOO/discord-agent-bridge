import Foundation

// Share a markdown document into a Discord thread: open a document thread, attach the
// original `.md`, and post the file's own text (never an AI re-summary) as the body.
// Pure core port of TS `src/discord/documentShare.ts` — Discord I/O is injected via
// `DocumentShareChannel` so the library stays free of DiscordBM (same pattern as
// PermissionPresenter / Confinement).
//
// Deliberate boundaries (TS documentShare.ts §1–3):
//  1. Absolute paths resolve as-is; relative against session cwd. Existence, regular-file,
//     extension allowlist, size, and binary (NUL) checks apply. Paths *outside* the session
//     folder ARE allowed for share (unlike attach_file confinement).
//  2. Body posts through `deliverAnswer` so tables/mermaid render as PNG when an
//     ImageRenderFn is injected; otherwise plain `DiscordText.chunkMessage`.
//  3. `escape` ShareErrorCode is retained for i18n/compat but is no longer produced.

/// Per-cause rejection code. Edge localizes via `doc.error.<code>`; core stays i18n-free.
public enum ShareErrorCode: String, Sendable, Equatable, Codable, CaseIterable {
    case notFound
    case escape
    case tooLarge
    case notMarkdown
    case notFile
}

/// full = whole file (within maxBytes); preview = first previewMaxChars + notice; attachment_only = .md only.
public typealias BodyMode = String  // "full" | "preview" | "attachment_only"

public struct DocumentShareOptions: Sendable, Equatable {
    public var maxBytes: Int
    public var bodyMode: BodyMode
    public var previewMaxChars: Int
    public var extensions: [String]

    public init(
        maxBytes: Int = 524_288,
        bodyMode: BodyMode = "preview",
        previewMaxChars: Int = 8000,
        extensions: [String] = [".md", ".markdown"]
    ) {
        self.maxBytes = maxBytes
        self.bodyMode = bodyMode
        self.previewMaxChars = previewMaxChars
        self.extensions = extensions
    }

    public static let `default` = DocumentShareOptions()

    /// From global config `documentShare` (render's `?? DEFAULT` idiom).
    public init(section: DocumentShareSection?) {
        let d = DocumentShareOptions.default
        self.maxBytes = section?.maxBytes ?? d.maxBytes
        self.bodyMode = section?.bodyMode ?? d.bodyMode
        self.previewMaxChars = section?.previewMaxChars ?? d.previewMaxChars
        self.extensions = section?.extensions ?? d.extensions
    }
}

public struct ShareResult: Sendable, Equatable, Error {
    public var ok: Bool
    /// Created thread name (`📄 <basename>`, truncated) — success only.
    public var threadName: String?
    /// Display path: relative to cwd when under cwd, else absolute — success only.
    public var path: String?
    /// Rejection cause — failure only.
    public var code: ShareErrorCode?
    /// Display-formatted size limit (e.g. `512.0 KiB`) — `tooLarge` only.
    public var max: String?

    public init(
        ok: Bool,
        threadName: String? = nil,
        path: String? = nil,
        code: ShareErrorCode? = nil,
        max: String? = nil
    ) {
        self.ok = ok
        self.threadName = threadName
        self.path = path
        self.code = code
        self.max = max
    }

    public static func reject(_ code: ShareErrorCode, max: String? = nil) -> ShareResult {
        ShareResult(ok: false, code: code, max: max)
    }

    /// Uncoded failure (no live session / no sink) — edge maps to `router.noSession`.
    public static let noSession = ShareResult(ok: false)

    /// JSON for reverse-RPC `host.file.share` result (TS ShareResult 1:1).
    public func asJSONValue() -> JSONValue {
        var o: [String: JSONValue] = ["ok": .bool(ok)]
        if let threadName { o["threadName"] = .string(threadName) }
        if let path { o["path"] = .string(path) }
        if let code { o["code"] = .string(code.rawValue) }
        if let max { o["max"] = .string(max) }
        return .object(o)
    }
}

/// Validated + loaded document ready to post (no Discord side-effects yet).
public struct LoadedDocument: Sendable, Equatable {
    public var resolvedPath: String
    public var displayPath: String
    public var basename: String
    public var byteSize: Int
    public var fileData: Data
    public var content: String
    public var threadName: String
    public var metaLine: String
    /// Body text to post after the attachment message; nil for `attachment_only`.
    public var bodyText: String?
}

/// Discord-agnostic thread: send content and/or one file attachment.
public struct DocumentShareThread: Sendable {
    public var send: @Sendable (_ content: String?, _ file: (name: String, data: Data)?) async throws -> Void

    public init(send: @escaping @Sendable (_ content: String?, _ file: (name: String, data: Data)?) async throws -> Void) {
        self.send = send
    }
}

/// Discord-agnostic channel that can open a document thread.
public struct DocumentShareChannel: Sendable {
    public var startThread: @Sendable (_ name: String) async throws -> DocumentShareThread

    public init(startThread: @escaping @Sendable (_ name: String) async throws -> DocumentShareThread) {
        self.startThread = startThread
    }
}

/// Discord thread name hard cap (TS `THREAD_NAME_LIMIT` in format.ts).
public let documentThreadNameLimit = 100

/// Appended when a preview is cut short. Full document is always the first attachment.
public let documentPreviewNotice = "\n\n… (preview truncated — full document attached above)"

// MARK: - Pure load / validate

/// Resolve + validate + read. Rejected paths never open a thread. Returns either a loaded
/// document or a coded `ShareResult` failure (never throws for known rejections).
public func loadShareableDocument(
    cwd: String,
    path: String,
    options: DocumentShareOptions = .default
) -> Result<LoadedDocument, ShareResult> {
    // (a) Resolve. Absolute → as-is; relative → against cwd. realpath of deepest existing ancestor.
    let root = realpathOrResolve(cwd)
    let joined: String
    if (path as NSString).isAbsolutePath {
        joined = path
    } else {
        joined = (cwd as NSString).appendingPathComponent(path)
    }
    let resolved = realpathOrResolve(joined)

    // (b) Existence + regular file.
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
        return .failure(.reject(.notFound))
    }
    if isDir.boolValue {
        return .failure(.reject(.notFile))
    }
    let attrs: [FileAttributeKey: Any]
    do {
        attrs = try FileManager.default.attributesOfItem(atPath: resolved)
    } catch {
        // Race: gone between exists and attributes → notFound (TS ENOENT path).
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
            return .failure(.reject(.notFound))
        }
        // Unexpected I/O — surface as throw via Result-less path by mapping to notFound for
        // the known missing case; other errors rethrow through shareDocument.
        return .failure(.reject(.notFound))
    }
    if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
        return .failure(.reject(.notFile))
    }
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0

    // (c) Extension allowlist (case-insensitive, with leading dot).
    let ext = fileExtension(of: resolved)
    let allowed = options.extensions.map { $0.lowercased() }
    if !allowed.contains(ext) {
        return .failure(.reject(.notMarkdown))
    }

    // (d) Size guard.
    if size > options.maxBytes {
        let maxLabel = String(format: "%.1f KiB", Double(options.maxBytes) / 1024.0)
        return .failure(.reject(.tooLarge, max: maxLabel))
    }

    // (e) Read + binary sniff (NUL). Before any thread open.
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: resolved))
    } catch {
        return .failure(.reject(.notFound))
    }
    if data.contains(0) {
        return .failure(.reject(.notFile))
    }
    let content = String(decoding: data, as: UTF8.self)

    let basename = (resolved as NSString).lastPathComponent
    let displayPath = isWithin(root: root, child: resolved)
        ? relativePath(from: root, to: resolved)
        : resolved
    let threadName = DiscordText.clip("📄 " + basename, limit: documentThreadNameLimit)
    let metaLine = "`\(displayPath)` · \(String(format: "%.1f", Double(size) / 1024.0)) KiB"

    let bodyText: String?
    switch options.bodyMode {
    case "attachment_only":
        bodyText = nil
    case "full":
        bodyText = content
    default: // "preview" (and unknown → preview, matching defaults)
        if content.count > options.previewMaxChars {
            let end = content.index(content.startIndex, offsetBy: options.previewMaxChars)
            bodyText = String(content[..<end]) + documentPreviewNotice
        } else {
            bodyText = content
        }
    }

    return .success(LoadedDocument(
        resolvedPath: resolved,
        displayPath: displayPath,
        basename: basename,
        byteSize: size,
        fileData: data,
        content: content,
        threadName: threadName,
        metaLine: metaLine,
        bodyText: bodyText
    ))
}

// MARK: - Share (load + post)

/// Load then post via the injected channel sink. Known rejections return coded `ShareResult`
/// without opening a thread. Sink / unexpected I/O errors throw (edge owns try/catch).
public func shareDocument(
    cwd: String,
    path: String,
    options: DocumentShareOptions = .default,
    channel: DocumentShareChannel,
    renderImage: ImageRenderFn? = nil
) async throws -> ShareResult {
    let loaded: LoadedDocument
    switch loadShareableDocument(cwd: cwd, path: path, options: options) {
    case .failure(let res):
        return res
    case .success(let doc):
        loaded = doc
    }

    // (f + g) Open document thread.
    let thread = try await channel.startThread(loaded.threadName)

    // (h) Meta + original .md attachment (always).
    try await thread.send(loaded.metaLine, (name: loaded.basename, data: loaded.fileData))

    // (i) Body per bodyMode — deliverAnswer (tables/mermaid → PNG when renderer present).
    if let body = loaded.bodyText {
        try await deliverAnswer(
            body,
            options: DeliverOptions(
                renderImage: renderImage,
                emit: { payload in
                    if let name = payload.fileName, let data = payload.fileData {
                        try await thread.send(payload.content, (name: name, data: data))
                    } else {
                        try await thread.send(payload.content, nil)
                    }
                }
            )
        )
    }

    // (j)
    return ShareResult(ok: true, threadName: loaded.threadName, path: loaded.displayPath)
}

// MARK: - Process-wide reverse-RPC / slash host

/// Discord-agnostic share sink keyed by channel (wired once from `dab` at boot).
/// Absent → uncoded failure (no live Discord sink), matching TS shareDocumentFor backstop.
public actor DocumentShareHost {
    public static let shared = DocumentShareHost()

    public typealias ShareFn = @Sendable (_ channelId: String, _ path: String) async throws -> ShareResult

    private var shareFn: ShareFn?

    public init() {}

    public func setShareHandler(_ fn: @escaping ShareFn) {
        shareFn = fn
    }

    public func share(channelId: String, path: String) async throws -> ShareResult {
        guard let shareFn else { return .noSession }
        return try await shareFn(channelId, path)
    }
}

// MARK: - Private path helpers

/// `path.extname` analogue — lowercased, includes leading `.` (or `""` when none).
private func fileExtension(of path: String) -> String {
    let base = (path as NSString).lastPathComponent
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
    return String(base[dot...]).lowercased()
}

/// Components after `root` joined with `/`. Empty when equal. Both absolute/realpath-resolved.
private func relativePath(from root: String, to child: String) -> String {
    let r = pathComponents(root)
    let c = pathComponents(child)
    if c.count < r.count { return child }
    return c.dropFirst(r.count).joined(separator: "/")
}

private func pathComponents(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}
