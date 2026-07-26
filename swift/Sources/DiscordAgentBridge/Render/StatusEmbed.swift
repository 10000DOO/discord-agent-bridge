import Foundation

// Pinned session status embed (TS `src/discord/renderers/statusEmbed.ts`).
// Pure builder → StatusEmbedSpec; dab maps to DiscordBM Embed.

public struct StatusEmbedField: Sendable, Equatable {
    public var name: String
    public var value: String
    public var inline: Bool

    public init(name: String, value: String, inline: Bool = false) {
        self.name = name
        self.value = value
        self.inline = inline
    }
}

public struct StatusEmbedSpec: Sendable, Equatable {
    public var title: String
    public var color: Int
    public var fields: [StatusEmbedField]
    public var footer: String?

    public init(title: String, color: Int, fields: [StatusEmbedField], footer: String? = nil) {
        self.title = title
        self.color = color
        self.fields = fields
        self.footer = footer
    }
}

public struct SessionStatus: Sendable, Equatable {
    public var mode: String
    public var cwd: String
    public var sessionId: String?
    public var permMode: String
    /// Whether the backend supports the usage/limits panel (false → Codex footer).
    public var usagePanel: Bool

    public init(
        mode: String,
        cwd: String,
        sessionId: String? = nil,
        permMode: String,
        usagePanel: Bool
    ) {
        self.mode = mode
        self.cwd = cwd
        self.sessionId = sessionId
        self.permMode = permMode
        self.usagePanel = usagePanel
    }
}

/// Labels (TS i18n status.* / perm.* / resume.status.title).
public enum StatusEmbedLabels {
    public static var title: String { I18n.t("status.title") }
    /// `/agent resume` + resume-wizard intro (TS `resume.status.title`).
    public static var resumeTitle: String { I18n.t("resume.status.title") }
    public static var mode: String { I18n.t("status.mode") }
    public static var permMode: String { I18n.t("status.permMode") }
    public static var cwd: String { I18n.t("status.cwd") }
    public static var session: String { I18n.t("status.session") }
    public static var usageCodex: String { I18n.t("status.usage.codex") }
}

/// Channel intro body under the status embed (TS `cmd.start.intro`).
public var sessionStatusIntroContent: String { I18n.t("cmd.start.intro") }

/// Human label for a permMode code (Claude + Codex vocabularies).
public func permModeLabel(_ perm: String) -> String {
    switch perm {
    case "default": return I18n.t("perm.default")
    case "acceptEdits": return I18n.t("perm.acceptEdits")
    case "bypassPermissions": return I18n.t("perm.bypassPermissions")
    case "plan": return I18n.t("perm.plan")
    case "dontAsk": return I18n.t("perm.dontAsk")
    case "auto": return I18n.t("perm.auto")
    case "read-only": return I18n.t("perm.read-only")
    case "workspace-write": return I18n.t("perm.workspace-write")
    case "danger-full-access": return I18n.t("perm.danger-full-access")
    default: return perm
    }
}

public func buildStatusEmbed(
    _ status: SessionStatus,
    title: String = StatusEmbedLabels.title
) -> StatusEmbedSpec {
    let fields: [StatusEmbedField] = [
        StatusEmbedField(name: StatusEmbedLabels.mode, value: status.mode, inline: true),
        StatusEmbedField(name: StatusEmbedLabels.permMode, value: permModeLabel(status.permMode), inline: true),
        StatusEmbedField(name: StatusEmbedLabels.cwd, value: "`\(status.cwd)`"),
        StatusEmbedField(name: StatusEmbedLabels.session, value: "`\(status.sessionId ?? "—")`"),
    ]
    let footer: String? = status.usagePanel ? nil : StatusEmbedLabels.usageCodex
    return StatusEmbedSpec(
        title: title,
        color: DiscordColors.idle,
        fields: fields,
        footer: footer
    )
}

/// Status embed for `/agent resume` (TS `postResumeIntro` title override).
public func buildResumeStatusEmbed(_ status: SessionStatus) -> StatusEmbedSpec {
    buildStatusEmbed(status, title: StatusEmbedLabels.resumeTitle)
}

/// usagePanel capability for a backend (TS mode.capabilities.usagePanel defaults).
public func backendSupportsUsagePanel(_ backend: Backend) -> Bool {
    defaultCapabilities(for: backend).usagePanel
}
