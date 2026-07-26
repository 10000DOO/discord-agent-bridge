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

/// Korean labels (TS i18n status.* / perm.* / resume.status.title).
public enum StatusEmbedLabels {
    public static let title = "세션 상태"
    /// `/agent resume` + resume-wizard intro (TS `resume.status.title`).
    public static let resumeTitle = "세션 재개됨"
    public static let mode = "모드"
    public static let permMode = "권한 모드"
    public static let cwd = "작업 폴더"
    public static let session = "세션 ID"
    public static let usageCodex = "사용량/한도 정보 없음 (Codex CLI 제한)"
}

/// Channel intro body under the status embed (TS `cmd.start.intro`).
public let sessionStatusIntroContent =
    "이 채널에서 에이전트와 대화하세요. 메시지를 보내면 작업이 시작됩니다. `/agent close` 로 세션을 종료하고 채널을 정리할 수 있어요."

/// Human label for a permMode code (Claude + Codex vocabularies).
public func permModeLabel(_ perm: String) -> String {
    switch perm {
    case "default": return "기본 (매번 확인)"
    case "acceptEdits": return "편집 자동 승인"
    case "bypassPermissions": return "전체 자동 승인 (⚠️ 위험)"
    case "plan": return "플랜 (읽기 전용)"
    case "dontAsk": return "사전 승인만 허용 (미승인 거부)"
    case "auto": return "자동 판단 (모델이 승인/거부)"
    case "read-only": return "읽기 전용 (실행 시 확인)"
    case "workspace-write": return "작업 폴더 쓰기 허용"
    case "danger-full-access": return "전체 접근 (⚠️ 샌드박스 없음)"
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
