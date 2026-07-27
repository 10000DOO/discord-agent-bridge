import Foundation

// Read-only file browse/download, realpath-confined to the session workspace
// (TS `fileDownload.ts`). Every browsed/downloaded path is realpath-resolved and
// must stay inside the workspace root — a symlink pointing outside the root is
// caught, not just a literal `..`. Pure FS logic — unit-testable with temp dirs.
//
// No Discord UI wiring (TS also leaves this as a library only). Future slash/UI
// can call `browse` / `download` and turn `OutgoingFile` into an attachment.

/// Thrown when a browse/download path escapes the workspace root.
public struct WorkspaceEscapeError: Error, CustomStringConvertible, Equatable {
    public let requestedPath: String

    public init(requestedPath: String) {
        self.requestedPath = requestedPath
    }

    public var description: String {
        "Path escapes the workspace: \(requestedPath)"
    }
}

/// One directory listing entry (TS `DirEntry`).
public struct DirEntry: Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Path + display name for a Discord attachment (TS `OutgoingFile` path form).
public struct OutgoingFile: Sendable, Equatable {
    public var path: String
    public var name: String

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// Confined workspace browser/downloader (TS `FileDownload` class).
public final class FileDownload: @unchecked Sendable {
    private let root: String

    public init(workspaceRoot: String) {
        self.root = realpathOrResolve(workspaceRoot)
    }

    /// List entries of a directory inside the workspace. Dotfiles hidden; dirs first, then name.
    /// Throws `WorkspaceEscapeError` when `relativeDir` escapes the root.
    public func browse(relativeDir: String = ".") throws -> [DirEntry] {
        let target = try resolveConfined(relativeDir)
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: target)
        var entries: [DirEntry] = []
        for name in names where !name.hasPrefix(".") {
            let full = (target as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            entries.append(DirEntry(name: name, isDirectory: isDir.boolValue))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return entries
    }

    /// Resolve a download target inside the workspace. Throws `WorkspaceEscapeError` on escape,
    /// or a plain `FileDownloadError` when missing / not a file.
    public func download(relativePath: String) throws -> OutgoingFile {
        let target = try resolveConfined(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
            throw FileDownloadError.notFound(relativePath)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: target),
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else {
            throw FileDownloadError.notAFile(relativePath)
        }
        return OutgoingFile(path: target, name: (target as NSString).lastPathComponent)
    }

    private func resolveConfined(_ requested: String) throws -> String {
        let joined: String
        if (requested as NSString).isAbsolutePath {
            joined = requested
        } else {
            joined = (root as NSString).appendingPathComponent(requested)
        }
        let resolved = realpathOrResolve(joined)
        guard isWithin(root: root, child: resolved) else {
            throw WorkspaceEscapeError(requestedPath: requested)
        }
        return resolved
    }
}

public enum FileDownloadError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case notAFile(String)

    public var description: String {
        switch self {
        case .notFound(let p): return "File not found: \(p)"
        case .notAFile(let p): return "Not a file: \(p)"
        }
    }
}
