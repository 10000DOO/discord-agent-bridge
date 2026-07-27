import Foundation

// Discord message attachments → confined paths under the session workspace
// (TS `messageRouter.ts` downloadAttachments + sanitizeName). Pure FS + injectable
// fetch so unit tests never hit the network.

/// Relative dir under the session cwd (TS `ATTACHMENT_DIR`).
public let attachmentDirName = ".dab-attachments"

/// One inbound file for a turn (TS `TurnInput.files` entry).
public struct TurnFile: Sendable, Equatable {
    public var path: String
    public var mime: String?

    public init(path: String, mime: String? = nil) {
        self.path = path
        self.mime = mime
    }
}

/// Narrow attachment view (url / name / contentType) — DiscordBM Attachment maps 1:1.
public struct IncomingAttachment: Sendable, Equatable {
    public var url: String
    public var name: String?
    public var contentType: String?

    public init(url: String, name: String? = nil, contentType: String? = nil) {
        self.url = url
        self.name = name
        self.contentType = contentType
    }
}

public enum AttachmentDownloadError: Error, CustomStringConvertible, Equatable {
    case escapesWorkspace(String)
    case fetchFailed(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .escapesWorkspace(let p):
            return "Attachment path escapes the workspace: \(p)"
        case .fetchFailed(let m):
            return "Attachment fetch failed: \(m)"
        case .writeFailed(let m):
            return "Attachment write failed: \(m)"
        }
    }
}

/// Injectable download of attachment bytes (tests inject fixed Data).
public typealias FetchBytes = @Sendable (String) async throws -> Data

/// Default HTTP fetch via URLSession (production path in `dab`).
public func defaultFetchBytes(url: String) async throws -> Data {
    guard let u = URL(string: url) else {
        throw AttachmentDownloadError.fetchFailed("invalid url")
    }
    let (data, response) = try await URLSession.shared.data(from: u)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        throw AttachmentDownloadError.fetchFailed("HTTP \(http.statusCode)")
    }
    return data
}

/// Reduce a Discord attachment filename to a safe basename (no path separators / traversal).
/// Mirrors TS `sanitizeName` (messageRouter.ts).
public func sanitizeAttachmentName(_ name: String) -> String {
    var base = (name as NSString).lastPathComponent
    base = base
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
    if base.isEmpty || base == "." || base == ".." { return "attachment" }
    return base
}

/// Download each attachment under `cwd/.dab-attachments`, realpath-confined to the workspace.
/// Empty list → empty array. Throws on confinement escape or I/O failure.
public func downloadAttachments(
    cwd: String,
    attachments: [IncomingAttachment],
    fetchBytes: FetchBytes = defaultFetchBytes
) async throws -> [TurnFile] {
    if attachments.isEmpty { return [] }
    let root = realpathOrResolve(cwd)
    let dirJoined = (root as NSString).appendingPathComponent(attachmentDirName)
    var dir = try confineAttachmentPath(root: root, candidate: dirJoined)
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // Re-confine after mkdir: a pre-planted symlink at .dab-attachments now realpaths.
    dir = try confineAttachmentPath(root: root, candidate: dir)

    // Per-call subdirectory keyed by a fresh UUID: two messages on the same channel can now
    // download concurrently (gateway-event-loop-serialized.md parallelizes messageCreate), so a
    // shared attachment filename must not let one turn's write silently clobber another's
    // in-flight file. The sanitized name stays the final path component either way.
    let callDirJoined = (dir as NSString).appendingPathComponent(UUID().uuidString)
    var callDir = try confineAttachmentPath(root: root, candidate: callDirJoined)
    try FileManager.default.createDirectory(atPath: callDir, withIntermediateDirectories: true)
    callDir = try confineAttachmentPath(root: root, candidate: callDir)

    var files: [TurnFile] = []
    for att in attachments {
        let name = sanitizeAttachmentName(att.name ?? "attachment")
        let dest = try confineAttachmentPath(
            root: root,
            candidate: (callDir as NSString).appendingPathComponent(name)
        )
        let bytes: Data
        do {
            bytes = try await fetchBytes(att.url)
        } catch let e as AttachmentDownloadError {
            throw e
        } catch {
            throw AttachmentDownloadError.fetchFailed(String(describing: error))
        }
        do {
            try bytes.write(to: URL(fileURLWithPath: dest), options: .atomic)
        } catch {
            throw AttachmentDownloadError.writeFailed(String(describing: error))
        }
        let mime = att.contentType.flatMap { $0.isEmpty ? nil : $0 }
        files.append(TurnFile(path: dest, mime: mime))
    }
    return files
}

/// Append absolute paths as text hints for backends that lack native file input
/// (Codex/Grok best-effort). Mirrors TS `appendNonImageHints` shape without image split.
public func appendAttachedFileHints(text: String, files: [TurnFile]) -> String {
    if files.isEmpty { return text }
    let lines = files.map { "Attached file: \($0.path)" }
    let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { return lines.joined(separator: "\n") }
    return base + "\n\n" + lines.joined(separator: "\n")
}

/// Extension allowlist for "this is an image" (TS `turnFiles.ts` `IMAGE_EXTS`).
private let imageFileExtensions: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".webp"]

/// A `TurnFile` classified image/non-image with a resolved mime, for multimodal prompt building
/// (TS `ClassifiedTurnFile`/`classifyTurnFiles`, `modes/shared/turnFiles.ts`).
public struct ClassifiedTurnFile: Sendable, Equatable {
    public var path: String
    public var mime: String
    public var isImage: Bool
}

/// Split turn files into image vs non-image, resolving a mime for each. A file is an image when
/// its declared mime starts with `image/` OR its extension is a known image extension (TS: OR of
/// both checks).
public func classifyTurnFiles(_ files: [TurnFile]) -> [ClassifiedTurnFile] {
    files.map { f in
        let ext = "." + (f.path as NSString).pathExtension.lowercased()
        let fromMime = f.mime?.hasPrefix("image/") ?? false
        let fromExt = imageFileExtensions.contains(ext)
        let isImage = fromMime || fromExt
        let mime: String
        if let m = f.mime, !m.isEmpty {
            mime = m
        } else if let m = mimeFromImageExtension(ext) {
            mime = m
        } else {
            mime = isImage ? "image/png" : "application/octet-stream"
        }
        return ClassifiedTurnFile(path: f.path, mime: mime, isImage: isImage)
    }
}

/// Read an image file's bytes as base64 for a vision/ACP image prompt block (TS `readImageBase64`).
/// Throws (turn fails) on read failure — no fallback, matching TS's uncaught sync `fs.readFileSync`.
public func readImageBase64(path: String) throws -> String {
    try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()
}

private func mimeFromImageExtension(_ ext: String) -> String? {
    switch ext {
    case ".png": return "image/png"
    case ".jpg", ".jpeg": return "image/jpeg"
    case ".gif": return "image/gif"
    case ".webp": return "image/webp"
    default: return nil
    }
}

// MARK: - Private

/// Realpath-confine `candidate` to `root`; throw when it escapes.
func confineAttachmentPath(root: String, candidate: String) throws -> String {
    let resolved = realpathOrResolve(candidate)
    guard isWithin(root: root, child: resolved) else {
        throw AttachmentDownloadError.escapesWorkspace(candidate)
    }
    return resolved
}
