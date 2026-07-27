import Foundation

// MARK: - W11-b2: pure filesystem folder browser (TS directoryBrowser.ts parity)
//
// List dirs, go up/into, select cwd. No Discord types. Optional allowedRoots confine;
// when omitted/empty the browser is unbounded (navigate to filesystem root '/').
// Session file-access confinement is separate (Confinement.swift) and unaffected.
//
// custom_id scheme (DabMain / wizard handle):
//   dir:into   string-select value = child folder name
//   dir:up     button — parent
//   dir:here   button — commit cwd / advance wizard
//   dir:create button — open create-folder modal (handled in DabMain)
//   dir:manual button — open absolute-path modal (handled in DabMain)
//   dir:panel  button — native host picker when `nativePanel` (handled in DabMain)
//   dir:resume button — start Resume Session flow (ResumeWizard; handled in DabMain)
//   cancel     button — cancel wizard

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

    /// Jump to absolute path (manual path / native panel / tests). Same confinement as into/up.
    @discardableResult
    public func goTo(_ target: String) -> Bool {
        let resolved = Self.resolvePath(target)
        guard Self.confine(resolved, roots: roots) else { return false }
        guard Self.isDirectory(resolved) else { return false }
        current = resolved
        return true
    }

    /// Create a direct child folder under cwd (modal submit). Safe name + confine; optional enter.
    public func createChild(_ name: String, enter: Bool = true) -> DirCreateResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeFolderName(trimmed) else { return .invalidName }
        let parent = current
        let target = (parent as NSString).appendingPathComponent(trimmed)
        // Defense in depth: parent of target must still be current (no separator tricks).
        guard (target as NSString).deletingLastPathComponent == parent else { return .invalidName }
        guard Self.confine(target, roots: roots) else { return .escaped }
        do {
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        } catch {
            return .failed(String(describing: error))
        }
        if enter {
            _ = into(trimmed)
        }
        return .ok(path: target)
    }

    /// Select current folder as session cwd.
    public func select() -> String { current }

    /// Folder-step UI (select + up/here/create/cancel + manual/[panel]). Pure data → DiscordBM.
    public func render() -> WizardView {
        let children = listChildren()
        let title = I18n.t("wizard.step.folder")
        // TS `directoryBrowser.ts:render()`: guide text + current-location label + path.
        let description = I18n.t("dir.guide") + "\n\n" + I18n.t("dir.current") + ": `\(current)`"

        let options: [WizardSelectOption]
        if children.isEmpty {
            options = [WizardSelectOption(label: I18n.t("dir.empty"), value: "__none__")]
        } else {
            options = children.map {
                WizardSelectOption(label: Self.clip($0, maxLabelLength), value: $0)
            }
        }
        let selectRow = WizardRow(components: [
            .select(
                customId: "dir:into",
                placeholder: children.isEmpty ? I18n.t("dir.empty") : I18n.t("dir.select"),
                options: options
            ),
        ])
        // Row1 ≤5 (Discord limit): up · here · resume · create · cancel. Row2: manual · optional panel.
        let actionButtons: [WizardComponent] = [
            .button(
                customId: "dir:up",
                label: I18n.t("dir.up"),
                style: .secondary,
                disabled: !canGoUp()
            ),
            .button(customId: "dir:here", label: I18n.t("dir.here"), style: .success, disabled: false),
            .button(customId: "dir:resume", label: I18n.t("dir.resume"), style: .primary, disabled: false),
            .button(customId: "dir:create", label: I18n.t("dir.create"), style: .secondary, disabled: false),
            .button(customId: "cancel", label: I18n.t("wizard.cancel"), style: .secondary, disabled: false),
        ]
        var pathButtons: [WizardComponent] = [
            .button(customId: "dir:manual", label: I18n.t("dir.manual"), style: .secondary, disabled: false),
        ]
        if nativePanel {
            pathButtons.append(
                .button(customId: "dir:panel", label: I18n.t("dir.panel"), style: .secondary, disabled: false)
            )
        }
        return WizardView(title: title, description: description, rows: [
            selectRow,
            WizardRow(components: actionButtons),
            WizardRow(components: pathButtons),
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

/// Result of `createChild` (modal mkdir).
public enum DirCreateResult: Equatable, Sendable {
    case ok(path: String)
    case invalidName
    case escaped
    case failed(String)
}

/// True when `name` is a safe single path segment for 📁 create (TS `isSafeFolderName`).
public func isSafeFolderName(_ name: String) -> Bool {
    if name.isEmpty { return false }
    if name == "." || name == ".." { return false }
    if name.contains("/") || name.contains("\\") { return false }
    if (name as NSString).isAbsolutePath { return false }
    // basename must match exactly (no trailing separators / weird segments).
    if (name as NSString).lastPathComponent != name { return false }
    return true
}

/// custom_ids owned by the folder browser (wizard routing + DabMain modal/panel).
public func isDirectoryBrowserCustomId(_ customId: String) -> Bool {
    switch customId {
    case "dir:into", "dir:up", "dir:here",
         "dir:create", "dir:manual", "dir:panel",
         "dir:resume":
        return true
    default:
        return false
    }
}

// MARK: - G-P1-06 favorites → browseRoots (TS app.ts / slashCommands)

/// Map global `AppConfig.favorites` → `DirectoryBrowser` `allowedRoots`.
///
/// TS: `browseRoots: config.favorites` then
/// `allowedRoots` only when `browseRoots.length > 0` (empty → unbounded, Fix 1).
/// Empty/whitespace-only entries are dropped so a blank favorite cannot confine the browser.
public func browseRoots(fromFavorites favorites: [String]) -> [String] {
    favorites
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}
