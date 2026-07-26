import Foundation

// realpath-based workspace confinement — pure helpers ported 1:1 from TS
// `sessionOrchestrator.ts:838-875` (findConfinementViolation / realpathOrResolve / isWithin).
//
// Consumed by `attachFileConfined` / `resolveConfinedAttachPath` (host.file.attach) and
// turn inbound `files` pre-filter when present. TOCTOU note below still applies.
// NOTE(원본 sessionOrchestrator.ts:834-837 주석): 이 검사는 TOCTOU 프리필터일 뿐이다(체크 후 tail
//   컴포넌트가 심링크로 교체될 수 있음). 최종 가드는 파일 open 지점에 있어야 하며, 이 함수를 유일한
//   confinement 집행으로 취급하지 말 것.

/// Return the first `files` entry whose realpath escapes the workspace `cwd`, or nil if every file is
/// confined. Resolves symlinks by realpath-ing the deepest existing ancestor of each path (a file need
/// not exist yet), so a symlink pointing outside the workspace is caught, not just a literal `..`.
/// Mirrors TS `findConfinementViolation` (sessionOrchestrator.ts:838-846).
public func findConfinementViolation(cwd: String, files: [String]) -> String? {
    if files.isEmpty { return nil }
    let root = realpathOrResolve(cwd)
    for file in files {
        let resolved = realpathOrResolve(resolveAgainst(cwd, file))
        if !isWithin(root: root, child: resolved) { return file }
    }
    return nil
}

/// Realpath a path, falling back to the realpath of its deepest existing ancestor joined with the
/// non-existent tail — so confinement holds for paths that do not exist yet while still resolving
/// symlinks in the part that does. Mirrors TS `realpathOrResolve` (sessionOrchestrator.ts:852-868).
public func realpathOrResolve(_ target: String) -> String {
    let abs = lexicalAbsolute(target)
    var existing = abs
    var tail: [String] = []
    while !FileManager.default.fileExists(atPath: existing) {
        let parent = (existing as NSString).deletingLastPathComponent
        if parent == existing { break } // reached the filesystem root
        tail.insert((existing as NSString).lastPathComponent, at: 0)
        existing = parent
    }
    guard let realExisting = realpathC(existing) else { return abs }
    return tail.reduce(realExisting) { ($0 as NSString).appendingPathComponent($1) }
}

/// True when `child` is the same as, or nested under, `root`. Compares path components (not string
/// prefixes) so it is not fooled by shared prefixes (e.g. /ws vs /ws-evil). Both inputs are expected
/// to be absolute + symlink-resolved (as returned by `realpathOrResolve`). Mirrors TS `isWithin`
/// (sessionOrchestrator.ts:872-875), which uses `path.relative` for the same reason.
public func isWithin(root: String, child: String) -> Bool {
    let rootComps = components(root)
    let childComps = components(child)
    if childComps.count < rootComps.count { return false }
    for (r, c) in zip(rootComps, childComps) where r != c { return false }
    return true
}

// MARK: - Private

/// `path.resolve(cwd, file)` — an absolute `file` wins; otherwise it is joined onto `cwd`.
private func resolveAgainst(_ cwd: String, _ file: String) -> String {
    (file as NSString).isAbsolutePath ? file : (cwd as NSString).appendingPathComponent(file)
}

/// Make absolute (against the process cwd if relative) and collapse `.`/`..` lexically, without
/// touching the filesystem or resolving symlinks — matching Node `path.resolve`. Symlink resolution
/// happens only later, via `realpathC` on the existing ancestor.
private func lexicalAbsolute(_ p: String) -> String {
    let raw = (p as NSString).isAbsolutePath
        ? p
        : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
    return URL(fileURLWithPath: raw).standardized.path
}

/// Split an absolute path into its non-empty components (drops leading/trailing/duplicate slashes).
private func components(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// POSIX `realpath(3)` — the 1:1 analogue of `fs.realpathSync`. nil on failure (e.g. broken symlink
/// loop / permission), letting `realpathOrResolve` fall back to the lexical absolute.
private func realpathC(_ path: String) -> String? {
    guard let buf = realpath(path, nil) else { return nil }
    defer { free(buf) }
    return String(cString: buf)
}
