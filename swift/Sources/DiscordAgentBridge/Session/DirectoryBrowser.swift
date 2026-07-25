import Foundation

// MARK: - W11-b2 slice2: pure filesystem folder browser (TS directoryBrowser.ts parity)
//
// List dirs, go up/into, select cwd. No Discord types. Optional allowedRoots confine;
// when omitted/empty the browser is unbounded (navigate to filesystem root '/').
// Session file-access confinement is separate (Confinement.swift) and unaffected.
//
// custom_id scheme (DabMain / wizard handle):
//   dir:into   string-select value = child folder name
//   dir:up     button — parent
//   dir:here   button — commit cwd / advance wizard
//   cancel     button — cancel wizard
//
// ponytail: dir:resume / dir:create / dir:manual / dir:panel omitted in slice2 UI.
//   goTo(_:) is available for tests + future manual-path modal; pickFolder = slice3.

private let maxSelectOptions = 25
private let maxLabelLength = 95

public struct DirectoryBrowserOptions: Sendable, Equatable {
    /// Absolute directories the user may browse within. Empty/nil = unbounded.
    public var allowedRoots: [String]
    /// Start path; clamped to first root when out of bounds (bounded mode).
    public var startPath: String?
    /// Offer native host picker button (slice3). Default off.
    public var nativePanel: Bool

    public init(
        allowedRoots: [String] = [],
        startPath: String? = nil,
        nativePanel: Bool = false
    ) {
        self.allowedRoots = allowedRoots
        self.startPath = startPath
        self.nativePanel = nativePanel
    }
}

public final class DirectoryBrowser: @unchecked Sendable {
    /// Confinement roots, or nil when unbounded.
    private let roots: [String]?
    private let nativePanel: Bool
    private var current: String

    public init(options: DirectoryBrowserOptions = DirectoryBrowserOptions()) {
        let bounded = !options.allowedRoots.isEmpty
        self.roots = bounded
            ? options.allowedRoots.map { Self.resolvePath($0) }
            : nil
        self.nativePanel = options.nativePanel
        let fallbackStart = self.roots?.first ?? NSHomeDirectory()
        let start: String
        if let sp = options.startPath {
            start = Self.resolvePath(sp)
        } else {
            start = fallbackStart
        }
        self.current = Self.confine(start, roots: self.roots) ? start : fallbackStart
    }

    /// Convenience: bounded/unbounded from roots + start.
    public convenience init(
        allowedRoots: [String] = [],
        startPath: String? = nil,
        nativePanel: Bool = false
    ) {
        self.init(options: DirectoryBrowserOptions(
            allowedRoots: allowedRoots,
            startPath: startPath,
            nativePanel: nativePanel
        ))
    }

    public func cwd() -> String { current }

    /// Immediate subdirectories: non-dot first (alpha), then dot folders (alpha); cap 25.
    public func listChildren() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: current) else { return [] }
        var dirs: [String] = []
        for name in names {
            let full = (current as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            dirs.append(name)
        }
        dirs.sort { a, b in
            let ah = a.hasPrefix("."), bh = b.hasPrefix(".")
            if ah != bh { return !ah } // non-dot first
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        if dirs.count > maxSelectOptions {
            return Array(dirs.prefix(maxSelectOptions))
        }
        return dirs
    }

    /// Descend into a child. false if missing / not a dir / escapes roots.
    @discardableResult
    public func into(_ childName: String) -> Bool {
        let target = Self.resolvePath(current, childName)
        guard Self.confine(target, roots: roots) else { return false }
        guard Self.isDirectory(target) else { return false }
        current = target
        return true
    }

    /// Go up one level. false at filesystem root or root boundary (bounded).
    @discardableResult
    public func up() -> Bool {
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current { return false }
        guard Self.confine(parent, roots: roots) else { return false }
        current = parent
        return true
    }

    /// Jump to absolute path (manual path / tests). Same confinement as into/up.
    @discardableResult
    public func goTo(_ target: String) -> Bool {
        let resolved = Self.resolvePath(target)
        guard Self.confine(resolved, roots: roots) else { return false }
        guard Self.isDirectory(resolved) else { return false }
        current = resolved
        return true
    }

    /// Select current folder as session cwd.
    public func select() -> String { current }

    /// Folder-step UI (select + up/here/cancel). Pure data → DiscordBM via discordPayload.
    public func render() -> WizardView {
        let children = listChildren()
        let title = "폴더 선택"
        let description =
            "세션 작업 폴더를 고르세요. 하위 폴더를 선택하거나 ⬆ 상위 · ✅ 이 폴더로 시작.\n\n현재: `\(current)`"

        let options: [WizardSelectOption]
        if children.isEmpty {
            options = [WizardSelectOption(label: "(하위 폴더 없음)", value: "__none__")]
        } else {
            options = children.map {
                WizardSelectOption(label: Self.clip($0, maxLabelLength), value: $0)
            }
        }
        let selectRow = WizardRow(components: [
            .select(
                customId: "dir:into",
                placeholder: children.isEmpty ? "(하위 폴더 없음)" : "하위 폴더로 이동",
                options: options
            ),
        ])
        // slice2: into/up/here/cancel only.
        // ponytail: dir:resume · dir:create · dir:manual · dir:panel → slice3+ (modal/native).
        let buttons: [WizardComponent] = [
            .button(
                customId: "dir:up",
                label: "⬆ 상위",
                style: .secondary,
                disabled: !canGoUp()
            ),
            .button(customId: "dir:here", label: "✅ 이 폴더로 시작", style: .success, disabled: false),
            .button(customId: "cancel", label: "취소", style: .secondary, disabled: false),
        ]
        // nativePanel reserved; button not rendered until slice3 pickFolder wiring.
        _ = nativePanel
        return WizardView(title: title, description: description, rows: [
            selectRow,
            WizardRow(components: buttons),
        ])
    }

    private func canGoUp() -> Bool {
        let parent = (current as NSString).deletingLastPathComponent
        return parent != current && Self.confine(parent, roots: roots)
    }

    // MARK: Path helpers

    private static func confine(_ target: String, roots: [String]?) -> Bool {
        let resolved = resolvePath(target)
        guard let roots else { return true }
        return roots.contains { isWithin(root: $0, child: resolved) }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Node `path.resolve` analogue — absolute + collapse `.`/`..` lexically.
    private static func resolvePath(_ path: String) -> String {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        let joined = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }

    private static func resolvePath(_ base: String, _ child: String) -> String {
        if (child as NSString).isAbsolutePath {
            return resolvePath(child)
        }
        return URL(fileURLWithPath: base).appendingPathComponent(child).standardizedFileURL.path
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}

/// custom_ids owned by the folder browser (wizard routing).
public func isDirectoryBrowserCustomId(_ customId: String) -> Bool {
    switch customId {
    case "dir:into", "dir:up", "dir:here":
        return true
    default:
        return false
    }
}
