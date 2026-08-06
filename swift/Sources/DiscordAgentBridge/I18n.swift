import Foundation

// User-facing string catalog (TS `src/discord/i18n.ts`).
// Flat keys; default locale `ko`. Missing key in active locale → ko → key itself.
// `{name}` placeholders interpolate from vars (unknown left visible).

public enum AppLocale: String, Sendable, Equatable, CaseIterable {
    case ko
    case en
}

/// Global fallback language plus request-local overrides. Discord events for different guilds
/// run concurrently, so the selected server language must not be stored as mutable global state.
public enum I18n {
    private static let active = LockedBox(AppLocale.ko)
    @TaskLocal private static var requestLocale: AppLocale?

    public static func setLocale(_ locale: AppLocale) {
        active.withLock { $0 = locale }
    }

    public static func getLocale() -> AppLocale {
        requestLocale ?? active.withLock { $0 }
    }

    public static func withLocale<T>(_ locale: AppLocale, operation: () async throws -> T) async rethrows -> T {
        try await $requestLocale.withValue(locale) {
            try await operation()
        }
    }

    /// Parse config.locale (unknown / empty → ko).
    public static func resolveLocale(_ raw: String?) -> AppLocale {
        guard let raw, let loc = AppLocale(rawValue: raw) else { return .ko }
        return loc
    }

    /// A guild's locale overrides the process setting only when it is explicitly persisted.
    /// Missing server configuration must retain the configured global fallback, not reset to ko.
    public static func resolveServerLocale(_ raw: String?) -> AppLocale {
        guard let raw, !raw.isEmpty else { return getLocale() }
        return resolveLocale(raw)
    }

    /// Apply global config.locale (boot + /config autosave).
    public static func applyFromConfigLocale(_ raw: String?) {
        setLocale(resolveLocale(raw))
    }

    /// Resolve `key` in `locale` (default: active), fall back ko → key, then interpolate.
    public static func t(
        _ key: String,
        _ vars: [String: String] = [:],
        locale: AppLocale? = nil
    ) -> String {
        let loc = locale ?? getLocale()
        let template = catalogs[loc]?[key] ?? catalogs[.ko]?[key] ?? key
        return interpolate(template, vars: vars)
    }

    // MARK: - interpolate

    private static func interpolate(_ template: String, vars: [String: String]) -> String {
        guard !vars.isEmpty else { return template }
        var out = template
        for (name, value) in vars {
            out = out.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return out
    }

    // MARK: - catalogs

    private static let catalogs: [AppLocale: [String: String]] = [
        .ko: ko,
        .en: en,
    ]

    private static let ko: [String: String] = [
        // Auth / router
        "auth.denied": "권한이 없습니다: {reason}",
        "auth.denied.bare": "권한이 없습니다.",
        "router.noSession": "이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요.",
        "router.turn.queued": "대기열에 추가했어요 (#{depth}).",
        "cmd.error": "명령을 처리하지 못했어요: {error}",
        "cmd.error.generic": "명령을 처리하지 못했어요. 잠시 후 다시 시도해 주세요.",
        "turn.deliveryFailed": "⚠️ 답변을 전송하는 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.",

        // Boot / setup guidance
        "boot.noConfig": "설정이 없습니다. 먼저 셋업을 실행하세요:  dab --setup",
        "boot.noToken": "토큰이 설정되지 않았습니다 — --setup을 다시 실행하세요.",
        "setup.rolesInDiscord": "역할은 봇을 서버에 초대한 뒤 Discord에서 `/config` 명령으로 클릭 설정하세요.",
        "setup.defaultsInDiscord": "모델·언어·권한 등 기본값은 봇 초대 후 Discord `/config`에서 설정하세요.",

        // Slash stop / clear / close
        "cmd.stop.done": "세션을 중지했어요.",
        "cmd.stopAll.done": "모든 세션을 중지했어요 ({count}개).",
        "cmd.clear.done": "대화 컨텍스트를 비웠어요. 같은 폴더·설정으로 새 세션을 시작했습니다.",
        "cmd.clear.doneWithModules":
            "대화 컨텍스트를 비웠어요. 같은 폴더·설정으로 새 세션을 시작했고, 하위 모듈 세션 {count}개도 함께 비웠습니다.",
        "cmd.clear.public": "🧹 이 채널 대화 컨텍스트를 비웠어요. 이전 맥락은 이어지지 않습니다.",
        "cmd.close.done": "세션을 종료하고 보관했어요.",
        "cmd.resume.none": "재개할 수 있는 세션이 없어요. 새로 시작하려면 `/agent start` 를 사용하세요.",
        "cmd.resume.rebound": "이 채널을 다시 연결했어요.",
        "cmd.start.intro":
            "이 채널에서 에이전트와 대화하세요. 메시지를 보내면 작업이 시작됩니다. `/agent close` 로 세션을 종료하고 채널을 정리할 수 있어요.",
        "cmd.start.launched": "세션 시작 마법사를 열었어요.",
        "cmd.start.channelCreated": "세션 채널 생성됨: {channel}",
        "cmd.setup.done": "채널 구성을 완료했어요. {control} 에서 `/agent start` 로 세션을 시작하세요.",
        "cmd.setup.alreadyDone": "이미 채널 구성이 모두 되어 있어요. {control} 에서 `/agent start` 로 세션을 시작하세요.",
        "cmd.setup.unavailable":
            "채널을 만들 수 없어요. 봇에 \"채널 관리(Manage Channels)\" 권한이 있는지 확인하세요.",
        "cmd.config.opened":
            "역할·기본값 설정 패널을 열었어요. ① 역할을 고르고 저장, ② 아래 기본값은 고르면 바로 저장돼요.",
        "cmd.config.denied": "`/config` 는 실제 Discord 서버 관리자(Administrator)만 사용할 수 있어요.",

        // Mode / model / effort / perm
        "cmd.mode.switched": "백엔드를 {backend} 로 바꿨어요.",
        "cmd.mode.freshContext":
            "⚠️ {backend} 로 바꾸면 이 채널은 새 대화로 시작돼요. 이전 맥락은 안 넘어갑니다.",
        "cmd.mode.unavailable":
            "`{backend}` 백엔드는 사용할 수 없어요. 현재 세션은 그대로 유지했어요.",
        "cmd.perm.switched": "권한 설정을 바꿨어요: {perm}",
        "cmd.model.switched":
            "이 세션의 모델을 바꿨어요: {model} (다음 응답부터 적용, 대화는 유지)",
        "cmd.model.unsupported":
            "이 백엔드는 세션 중 모델 변경을 지원하지 않아요 (Claude만 가능).",
        "cmd.model.failed": "모델 변경에 실패했어요. 터미널 로그를 확인해 주세요.",
        "cmd.effort.switched":
            "이 세션의 추론 강도를 바꿨어요: {effort} (다음 응답부터 적용, 대화는 유지)",
        "cmd.effort.unsupported": "이 백엔드는 세션 중 추론 강도 변경을 지원하지 않아요.",
        "cmd.effort.failed": "추론 강도 변경에 실패했어요. 터미널 로그를 확인해 주세요.",

        // Interrupt
        "cmd.interrupt.button": "⏹️ 중단",
        "cmd.interrupt.done": "현재 작업을 중단했어요. 이어서 대화할 수 있어요.",
        "cmd.interrupt.none": "중단할 실행 중인 작업이 없어요.",

        // Result line
        "result.done": "완료",
        "result.cost": "비용",
        "result.tokens": "토큰",
        "result.duration": "소요",

        // Stream
        "stream.responding": "응답 중…",
        "stream.responded": "응답 완료",
        "stream.thinking": "생각 중…",
        "stream.thought": "{sec}초 동안 생각함",

        // Status
        "status.title": "세션 상태",
        "status.mode": "모드",
        "status.cwd": "작업 폴더",
        "status.session": "세션 ID",
        "status.permMode": "권한 모드",
        "status.usage.codex": "사용량/한도 정보 없음 (Codex CLI 제한)",
        "resume.status.title": "세션 재개됨",
        "resume.done": "세션 재개됨: {channel}",
        "resume.none": "재개할 세션이 없습니다.",

        // Backend labels
        "backend.claude": "Claude Code",
        "backend.codex": "Codex",
        "backend.custom": "Custom",

        // Permission
        "perm.request.title": "권한 요청",
        "perm.request.body": "**도구:** {tool}\n\n{input}",
        "perm.button.allow": "허용",
        "perm.button.always": "항상 허용",
        "perm.button.deny": "거부",
        "perm.decided.allow": "허용됨",
        "perm.decided.always": "항상 허용됨",
        "perm.decided.deny": "거부됨",
        "perm.default": "기본 (매번 확인)",
        "perm.acceptEdits": "편집 자동 승인",
        "perm.bypassPermissions": "전체 자동 승인 (⚠️ 위험)",
        "perm.plan": "플랜 (읽기 전용)",
        "perm.dontAsk": "사전 승인만 허용 (미승인 거부)",
        "perm.auto": "자동 판단 (모델이 승인/거부)",
        "perm.read-only": "읽기 전용 (실행 시 확인)",
        "perm.workspace-write": "작업 폴더 쓰기 허용",
        "perm.danger-full-access": "전체 접근 (⚠️ 샌드박스 없음)",

        // Tool thread
        "thread.work": "작업 내역",
        "tool.error": "오류",
        "tool.lines": "{n}줄",
        "tool.noOutput": "출력 없음",
        "transcript.working": "작업 중…",

        // Usage / stats
        "usage.title": "Claude 사용량",
        "usage.title.grok": "Grok 사용량",
        "usage.title.codex": "Codex 사용량",
        "usage.fiveHour": "5시간",
        "usage.weekly": "주간",
        "usage.weeklyOpus": "주간 (Opus)",
        "usage.weeklySonnet": "주간 (Sonnet)",
        "usage.context": "컨텍스트",
        "usage.resets": "초기화 {reset}",
        "usage.clearHint": "/clear 시 ~{tokens} 토큰 절약",
        "usage.session": "세션 구성",
        "usage.tools": "이번 턴 도구",
        "usage.agents": "서브에이전트",
        "usage.perm": "권한: {perm}",
        "usage.elapsed.min": "{m}분",
        "usage.elapsed.hourMin": "{h}시간 {m}분",
        "usage.elapsed.dayHour": "{d}일 {h}시간",
        "usage.duration.sec": "{s}초",
        "usage.duration.minSec": "{m}분 {s}초",
        // R3 WO-10: UsageEmbed.swift/UsageFormat.swift — 카탈로그에 없던 개념만 최소 신규 키
        "usage.overage": "추가 사용량",
        "usage.rateLimitAlert": "📊 사용량 한도 알림",
        "usage.sessionConfig": "세션 설정",
        "usage.model": "설정 모델: {model}",
        "usage.effort": "추론: {effort}",
        "usage.model.auto": "자동 선택",
        "usage.effort.default": "기본값",
        "usage.actualModel": "실제 모델: {model}",
        "stats.title": "📊 Agent Stats",
        "stats.active": "활성 세션 ({n})",
        "stats.none": "활성 세션이 없어요.",
        "stats.more": "외 {n}개 더…",
        "stats.bindings": "세션 바인딩",
        "stats.bindings.value": "활성 {active} · 보관 {archived}",
        "stats.usage": "Claude 사용량 (전역)",
        "stats.usage.unavailable": "Claude 구독 로그인(OAuth) 상태에서만 표시됩니다.",

        // File download
        "file.escape": "워크스페이스를 벗어난 경로는 다운로드할 수 없습니다.",
        "file.notFound": "파일을 찾을 수 없습니다.",
        "file.notFile": "파일이 아닙니다.",

        // Doc
        "doc.shared": "문서를 스레드에 공유했어요: `{path}`",
        "doc.error.notFound": "파일을 찾을 수 없어요: `{path}`",
        "doc.error.escape": "경로를 공유할 수 없어요.",
        "doc.error.tooLarge": "파일이 너무 커요 (최대 {max}).",
        "doc.error.notMarkdown": "마크다운(.md)만 공유할 수 있어요.",
        "doc.error.notFile": "파일이 아니에요(디렉터리/바이너리): `{path}`",

        // Wizard (common)
        "wizard.title": "세션 시작",
        "wizard.step.folder": "1/5단계 · 폴더",
        "wizard.step.backend": "2/5단계 · 백엔드를 선택하고 \"다음\"을 누르세요.",
        "wizard.step.model": "3/5단계 · 모델을 선택하고 \"다음\"을 누르세요.",
        "wizard.step.effort": "4/5단계 · 추론 수준을 선택하고 \"다음\"을 누르세요.",
        "wizard.step.perm": "5/5단계 · 권한을 선택하고 \"✅ 시작\"을 누르세요.",
        "wizard.confirm": "`{cwd}` 에서 {backend} 세션을 시작할까요? (권한: {perm})",
        "wizard.started": "세션을 시작했어요. 백엔드 {backend} · 폴더 `{cwd}`",
        "wizard.cancelled": "세션 시작을 취소했어요.",
        "wizard.cancel": "취소",
        "wizard.next": "다음",
        "wizard.back": "⬅ 이전",
        "wizard.start": "✅ 시작",
        "wizard.profile.advanced": "고급: 권한 모드 직접 선택",
        "wizard.recfg.title": "에이전트 전환 — {backend}",
        "wizard.recfg.step.model": "1/3단계 · 모델을 선택하고 \"다음\"을 누르세요.",
        "wizard.recfg.step.effort": "2/3단계 · 추론 수준을 선택하고 \"다음\"을 누르세요.",
        "wizard.recfg.step.perm": "3/3단계 · 권한을 선택하고 \"✅ 전환\"을 누르세요.",
        "wizard.recfg.start": "✅ 전환",
        "wizard.recfg.cancelled": "에이전트 전환을 취소했어요.",

        // Directory browser
        "dir.up": "⬆ 상위 폴더",
        "dir.select": "하위 폴더로 이동…",
        "dir.here": "✅ 이 폴더로 시작",
        "dir.resume": "세션 재개",
        "dir.create": "📁 폴더 만들기",
        "dir.empty": "(하위 폴더 없음)",
        "dir.escape": "허용된 범위를 벗어난 경로입니다.",
        "dir.create.title": "새 폴더 만들기",
        "dir.create.label": "폴더 이름",
        "dir.create.placeholder": "예: my-project",
        "dir.create.invalid": "폴더 이름이 올바르지 않아요. `/`, `..`, 절대 경로는 쓸 수 없어요.",
        "dir.create.failed": "폴더를 만들지 못했어요: {error}",
        "dir.create.done": "폴더를 만들었어요: {name}",
        "dir.manual": "📝 경로 직접 입력",
        "dir.manual.title": "경로 직접 입력",
        "dir.manual.label": "절대 경로",
        "dir.manual.placeholder": "예: /Volumes/SourceCode/MyProject",
        "dir.manual.notabs": "절대 경로를 입력하세요 (예: `/Users/...` 또는 `/Volumes/...`).",
        "dir.manual.invalid": "이동할 수 없는 경로예요: `{path}` (존재하지 않거나, 폴더가 아니거나, 허용 범위 밖).",
        "dir.manual.done":
            "경로로 이동했어요: `{path}`\n`✅ 이 폴더로 시작`을 눌러 이 폴더에서 세션을 시작하세요.",
        "dir.panel": "🖥️ Mac에서 폴더 선택",
        "dir.panel.prompt": "Discord 세션 프로젝트 폴더 선택",
        "dir.panel.wait": "🖥️ Mac 화면에 폴더 선택 창을 열었어요. Mac에서 폴더를 선택하세요… (2분 내)",
        "dir.panel.cancelled": "폴더 선택을 취소했어요.",
        "dir.panel.timeout": "폴더 선택 창을 2분이 지나 닫았어요. Mac 앞에 있을 때 사용하세요.",
        "dir.panel.busy": "이미 폴더 선택 창이 열려 있어요. Mac 화면을 확인하세요.",
        "dir.panel.error": "폴더 선택 창을 열지 못했어요: {err}",
        "dir.guide":
            "작업할 **프로젝트 폴더**를 고르세요. 목록에서 하위 폴더로 들어가거나 `⬆ 상위 폴더`로 올라간 뒤, `✅ 이 폴더로 시작`을 누르세요.",
        "dir.current": "현재 위치",

        // Resume-from-folder + presets
        "resume.step.backend": "재개할 백엔드를 선택하고 \"다음\"을 누르세요.",
        "resume.step.pick": "재개할 세션을 선택하세요.",
        "resume.select.placeholder": "세션 선택…",
        "resume.time.now": "방금",
        "resume.time.min": "{n}분 전",
        "resume.time.hour": "{n}시간 전",
        "resume.time.day": "{n}일 전",
        "preset.step.pick": "프리셋을 선택하세요.",
        "preset.pick.placeholder": "프리셋 선택…",
        "preset.summary": "{backend} · {model} · {effort} · {perm}",
        "preset.direct": "🆕 직접 설정",
        "preset.delete.button": "🗑 삭제",
        "preset.delete.active": "삭제할 프리셋을 선택하세요.",
        "preset.save.button": "💾 프리셋으로 저장",
        "preset.save.title": "프리셋 저장",
        "preset.save.label": "프리셋 이름",
        "preset.save.placeholder": "예: claude-opus-plan",
        "preset.saved": "프리셋을 저장했어요: {name}",
        "preset.save.none": "저장할 최근 세션 설정이 없어요.",
        "preset.backend.unavailable": "이 프리셋의 백엔드({backend})를 지금은 쓸 수 없어요.",

        // Update
        "update.title": "🔄 새 버전이 있어요",
        "update.body":
            "`discord-agent-bridge` {latest} 버전이 나왔어요 (현재 {current}).\n지금 업데이트할까요? 관리자만 결정할 수 있어요.\n**예**를 누르면 설치 후 새 버전으로 바로 재시작합니다 (진행 중 작업은 종료돼요).",
        "update.button.yes": "예, 업데이트",
        "update.button.no": "아니오",
        "update.decided.approved": "업데이트 진행 중…",
        "update.decided.dismissed": "이 버전 건너뜀",
        "update.busy": "이미 업데이트가 진행 중이에요.",
        "update.installing": "업데이트 설치를 시작합니다…",
        "update.restartRequested":
            "✅ 설치 완료. 서비스를 재시작하는 중이에요 (잠시 후 결과 메시지가 옵니다)…",
        "update.installed":
            "✅ 설치 완료. 서비스를 재시작하는 중이에요 (잠시 후 결과 메시지가 옵니다)…",
        "update.restartConfirmed": "✅ 업데이트 완료. 새 버전이 정상적으로 기동했어요.",
        "update.installFailed":
            "❌ 자동 업데이트 설치에 실패했어요. 수동으로 `bash swift/scripts/install.sh` 후 재시작해 주세요.",
        "update.dismissed": "이 버전 알림을 껐어요. 더 새 버전이 나오면 다시 알려드릴게요.",
        "update.denied": "자동 업데이트는 서버 관리자(Administrator) 또는 admin 티어만 결정할 수 있어요.",
        "update.manualOnly":
            "자동 설치 경로를 찾지 못했어요. 전체 체크아웃에서 `bash swift/scripts/install.sh`로 수동 업데이트하세요.",
        "update.restartFailed":
            "⚠️ 설치는 완료됐지만 서비스 재기동에 실패했어요. `launchctl`/`brew services`로 수동 재시작해 주세요. 로그: `~/.dab/logs/supervised-relaunch.log`",
        "update.manualRestartRequired":
            "⚠️ 설치는 완료됐지만 서비스 재기동에 실패했어요. `launchctl`/`brew services`로 수동 재시작해 주세요. 로그: `~/.dab/logs/supervised-relaunch.log`",
        "update.homebrewInProgress":
            "설치를 시작했어요. 몇 분 안에 재시작 결과를 별도로 알려드릴게요.",
        "update.homebrewUnavailable":
            "이 설치는 Homebrew인데 자동 업데이트 스크립트를 찾지 못했어요. 소스 설치 경로는 쓰지 않습니다. 터미널에서 `brew update && brew upgrade dab && brew services restart dab` 를 실행해 주세요.",
        "update.upToDate": "최신 버전이에요.",
        "update.checkFailed": "버전 확인에 실패했어요 (네트워크/레지스트리).",
        "update.disabled": "자동 업데이트가 꺼져 있어요 (`autoUpdate.enabled=false`).",

        // Render setup (Chromium install prompt)
        "render.setup.prompt":
            "🖼 표·다이어그램을 **이미지로** 보시겠어요? 렌더링에 필요한 Chromium(약 300MB)을 설치할 수 있어요. 설치하지 않아도 답변은 원문 텍스트로 정상 표시됩니다.",
        "render.setup.install": "설치",
        "render.setup.decline": "나중에",
        "render.setup.unavailable": "이 호스트에서는 설치를 사용할 수 없어요.",
        "render.setup.declined": "알겠어요. 나중에 `/config` 에서 설치할 수 있어요.",
        "render.setup.already": "이미 사용 가능한 브라우저가 있어요. 이미지 렌더링이 켜졌습니다.",
        "render.setup.installing": "Chromium을 내려받는 중이에요… (백그라운드, 몇 분 걸릴 수 있어요)",
        "render.setup.progress": "⏬ **Chromium 설치 중**\n`{bar}` {pct}%",
        "render.setup.done": "✅ 설치 완료! 이제 표·다이어그램이 이미지로 렌더링됩니다.",
        "render.setup.failed": "설치에 실패했어요. 잠시 후 `/config` 에서 다시 시도해 주세요.",

        // Watchdog
        "watchdog.idle":
            "약 3분 동안 새 활동이 없습니다. 아직 긴 작업을 하는 중일 수도 있고, 멈췄을 수도 있습니다. 채널 위쪽·스레드를 확인해 보거나, 작업이 끝났는지 에이전트한테 물어보세요.",

        // Config panel (/config)
        "config.title": "역할·기본값 설정",
        "config.intro":
            "① 역할: 봇을 쓸 사람의 Discord 역할을 고르고 **저장**하세요. 본인(관리자)이 가진 역할을 **admin**에 넣으면 다 됩니다.\n② 아래 기본값(백엔드·모델·권한·언어)은 **고르면 바로 저장**됩니다.\nClaude·Codex는 각자 홈(`~/.claude`, `~/.codex`)을 자동으로 사용하며, **작업할 프로젝트 폴더는 `/agent start` 할 때 고릅니다.**",
        "config.role.admin.placeholder": "admin 역할 (설정·stop-all)",
        "config.role.execute.placeholder": "execute 역할 (세션 시작·명령 실행)",
        "config.role.readOnly.placeholder": "read-only 역할 (읽기 전용)",
        "config.default.backend.placeholder": "기본 백엔드",
        "config.default.model.placeholder": "기본 모델",
        "config.default.effort.placeholder": "기본 추론 수준",
        "config.default.permMode.placeholder": "권한 모드 (기본)",
        "config.default.locale.placeholder": "봇 언어",
        "config.save": "저장",
        "config.saved":
            "이 서버 설정을 저장했어요.\n• admin: {admin}\n• execute: {execute}\n• read-only: {readOnly}\n• 기본 백엔드: {backend} · 모델: {model} · 권한: {perm}",
        "config.autosaved.locale": "언어를 저장했어요: {locale}",
        "config.autosaved.backend": "기본 백엔드를 저장했어요: {backend}",
        "config.autosaved.model": "기본 모델을 저장했어요: {model}",
        "config.autosaved.effort": "기본 추론 수준을 저장했어요: {effort}",
        "config.autosaved.permMode": "권한 모드를 저장했어요: {perm}",
        "config.notif.button": "🔔 알림 설정",
        "config.notif.title": "이벤트 알림 설정",
        "config.notif.intro":
            "세션의 주요 이벤트(완료·에러)를 상태 채널로 한 줄 요약해 보냅니다.\n현재 상태: **{state}**\n아래에서 상태 채널을 고르고, 버튼으로 켜고 끌 수 있어요. 채널을 비우면 `/setup` 이 만든 기본 상태 채널을 사용합니다.",
        "config.notif.on": "켜짐",
        "config.notif.off": "꺼짐",
        "config.notif.enable": "알림 켜기",
        "config.notif.disable": "알림 끄기",
        "config.notif.channel.placeholder": "상태 채널 선택 (비우면 기본 상태 채널)",
        "config.render.button": "🖼 이미지 렌더",
        "config.render.title": "표·다이어그램 이미지 렌더링",
        "config.render.intro":
            "답변의 표(table)와 mermaid 다이어그램을 이미지로 렌더링해 첨부합니다.\n현재 상태: **{state}**\n렌더링에는 Chromium이 필요합니다. 시스템 Chrome이 있으면 그대로 쓰고, 없으면 아래 **설치**로 내려받을 수 있어요(약 300MB, 백그라운드).",
        "config.render.on": "켜짐",
        "config.render.off": "꺼짐",
        "config.render.enable": "렌더 켜기",
        "config.render.disable": "렌더 끄기",
        "config.render.install": "Chromium 설치/재설치",
        "config.access.title": "👤 사용자 예외 권한",
        "config.access.intro": "선택한 사용자에게만 기본 권한보다 우선하는 예외 tier를 설정합니다.",
        "config.access.default": "기본 권한: **{tier}**",
        "config.access.selected": "선택: {user} → **{tier}**",
        "config.access.override": "저장된 예외: **{tier}**",
        "config.access.inherited": "저장된 예외 없음 — 기본 권한을 적용합니다.",
        "config.access.noSelection": "사용자를 선택하세요",
        "config.access.user.placeholder": "예외를 설정할 사용자 (1명)",
        "config.access.tier.placeholder": "적용할 권한 tier",
        "config.access.tier.admin": "admin",
        "config.access.tier.execute": "execute",
        "config.access.tier.read-only": "read-only",
        "config.access.tier.none": "none (완전 차단)",
        "config.access.apply": "예외 저장",
        "config.access.reset": "기본값으로 복귀",
        "config.access.selectUser": "먼저 사용자를 선택하세요.",
        "config.access.saveFailed": "사용자 예외 권한 저장 실패: {error}",
        "config.locale.ko": "한국어 (ko)",
        "config.locale.en": "English (en)",

        // R3 WO-4: Redmine setup modal + issue-select command (dab/DabMain.swift)
        "redmine.config.title": "레드마인 연동 설정",
        "redmine.config.urlLabel": "레드마인 주소",
        "redmine.config.apiKeyLabel": "API 키",
        "redmine.config.projectLabel": "프로젝트(선택, 비우면 전체)",
        "redmine.issueSelect.needsSetup": "먼저 `/redmine`으로 설정하세요.",
        "redmine.issueSelect.empty": "조건에 맞는 이슈가 없습니다.",
        "redmine.issueSelect.prompt": "레드마인 이슈를 선택하세요.",
        "redmine.issueSelect.fetchFailed": "레드마인 이슈 조회에 실패했어요: {error}",
        "redmine.issueSelect.placeholder.paged": "이슈 목록 ({index}/{total})",
        "redmine.issueSelect.placeholder.single": "이슈 선택",

        // R3 WO-5: Redmine config-save + session picker/issue delivery (dab/DabMain.swift)
        "redmine.session.cipherUnavailable":
            "레드마인 연동을 저장할 수 없어요: 서버에 `DAB_REDMINE_KEY_SECRET`이 설정되지 않았습니다. 운영자에게 문의하세요.",
        "redmine.session.configSaved": "레드마인 연동 설정이 완료됐어요. `#{channel}` 채널에서 알림을 확인하세요.",
        "redmine.session.configSaveFailed": "레드마인 연동 설정에 실패했어요: {error}",
        "redmine.session.configNotFound": "레드마인 설정을 찾을 수 없어요. `/redmine`으로 먼저 설정하세요.",
        "redmine.session.issueGone": "선택한 이슈를 더 이상 찾을 수 없어요.",
        "redmine.session.issueFetchFailed": "이슈 조회에 실패했어요: {error}",
        "redmine.session.selectPrompt": "세션을 선택하세요.",
        "redmine.session.notFound": "세션을 찾을 수 없어요.",
        "redmine.session.confirmDeliver": "이슈 #{issueId} → <#{channel}> 에 전달할까요?",
        "redmine.session.requested": "요청했어요: <#{channel}>",
        "redmine.session.issueGoneNotice": "⚠️ 선택한 이슈(#{issueId})를 더 이상 찾을 수 없어요.",
        "redmine.session.issueFetchFailedNotice": "⚠️ 이슈 조회에 실패했어요: {error}",
        "redmine.session.deliverCancelled": "전달을 취소했어요.",
        "session.ownerOrAdminRequired": "이 채널 세션의 소유자 또는 관리자만 새 세션으로 바꿀 수 있어요.",
        // NOTE: WO-5 소속이지만 실제 기능은 프리셋 저장 — preset.* 접두어로 명명(옵션 B, preset.save.* 옆 배치)
        "preset.save.invalidName": "프리셋 이름은 1~100자여야 해요.",
        "preset.save.failed": "프리셋 저장 실패: {error}",

        // R3 WO-6: DabMain.swift remaining hardcoded replies
        "perm.request.notAuthorized": "이 결정은 세션 승인자만 할 수 있어요 (또는 이미 처리됨/만료).",
        "cmd.model.missingValue": "model 값이 필요합니다.",
        "cmd.effort.missingValue": "effort 값이 필요합니다.",
        "cmd.mode.unknownBackend": "알 수 없는 backend",
        "cmd.perm.missingValue": "perm 값이 필요합니다.",
        "cmd.unknownSubcommand": "알 수 없는 서브커맨드: {name}",
        "stats.versionLine": "\n**버전** `{version}`{dismissed}",
        "stats.dismissedSuffix": " · 무시 `{version}`",
        "config.loadFailed": "config.json을 읽을 수 없어요. 설정 파일을 확인하세요: {error}",
        "cmd.doc.missingPath": "path 값이 필요합니다.",
        "doc.error.shareFailed": "문서 공유에 실패했어요. 잠시 후 다시 시도하세요.",
        "update.notReady": "업데이터가 아직 준비되지 않았어요. 잠시 후 다시 시도하세요.",
        "wizard.sessionMissing": "마법사 세션이 없습니다. `/agent start`로 다시 열어주세요.",
        "wizard.notOwner": "이 마법사는 연 사람만 조작할 수 있어요.",
        "wizard.resumeSessionMissing": "재개 마법사 세션이 없습니다. `/agent start` → 세션 재개로 다시 열어주세요.",
        "wizard.recfg.noSession": "전환 실패: 이 채널에 바인딩된 세션이 없습니다.",
        "wizard.recfg.noSelection": "전환 실패 (선택 없음).",
        "wizard.recfg.saveFailed": "세션 설정을 저장하지 못했습니다. 기존 세션은 변경되지 않았습니다.",
        "wizard.recfg.bound":
            "이 채널이 {backend} 세션에 바인딩됨. cwd={cwd}. 이제 접두사 없이 메시지를 보내면 됩니다.",
        "wizard.start.noSelection": "시작 실패 (선택 없음).",
        "wizard.unknownModal": "알 수 없는 모달입니다.",
        "cmd.attachment.failed": "첨부 처리 실패: {error}",
        "turnTimeout.prompt": "다시 시작할까요?",
        "turnTimeout.newSessionReady": "새 세션이 준비됐어요. 메시지를 다시 보내주시면 새 세션으로 시작돼요.",

        // R3 WO-7: RedmineKickoffPrompt.swift
        "redmine.kickoff.prompt":
            "**#{issueId} {subject}**\n\n{description}\n\n위 내용 간단히 파악해줘.",

        // R3 WO-8: RedmineSessionPicker.swift
        "redmine.session.newSession": "🆕 신규 세션",
        "redmine.session.placeholder.paged": "세션 목록 ({index}/{total})",
        "redmine.session.placeholder.single": "세션 선택",

        // R3 WO-9: AutoUpdateWiring.swift (formatUpdateCheckReply)
        "update.check.current": " (현재 `{version}`)",
        "update.check.upToDateCurrent": " 현재 `{version}`",
        "update.check.registrySuffix": " / 레지스트리 `{version}`",
        "update.check.dismissed":
            "새 버전 `{latest}` 이(가) 있지만 무시됨 (현재 `{current}`). 더 새 버전이 나오면 다시 알려드려요.",
        "update.check.available": "새 버전 `{latest}` 사용 가능 (현재 `{current}`).",

        // R3 WO-11: ConfigPanel.swift save-failure notices + access button
        "config.autosaved.roleFailed": "역할 저장 실패: {error}",
        "config.autosaved.backendFailed": "backend 저장 실패: {error}",
        "config.autosaved.modelFailed": "model 저장 실패: {error}",
        "config.autosaved.effortFailed": "effort 저장 실패: {error}",
        "config.autosaved.permModeFailed": "permMode 저장 실패: {error}",
        "config.autosaved.notifFailed": "알림 저장 실패: {error}",
        "config.autosaved.notifChannelFailed": "상태 채널 저장 실패: {error}",
        "config.autosaved.renderFailed": "render 저장 실패: {error}",
        "config.autosaved.chromiumFailed": "chromium 저장 실패: {error}",
        // ConfigPanel.swift:656 — WO-11 목록엔 없었으나 실제로 하드코딩 한글이 남아있어 추가 발견(완료판정이 파일 전체 기준이라 포함)
        "config.autosaved.localeFailed": "locale 저장 실패: {error}",
        "config.access.button": "👤 예외 권한",

        // R3 WO-12: UpdateButton.swift (redmine issue buttons + turn-timeout retry buttons)
        "redmine.issue.button.start": "착수",
        "redmine.issue.button.cancel": "취소",
        "redmine.issue.button.confirm": "확인",
        "redmine.issue.button.started": "착수함",
        "redmine.issue.button.cancelled": "취소함",
        "redmine.issue.button.done": "완료",
        "redmine.issue.button.restart": "재착수",
        "turnTimeout.button.yes": "예",
        "turnTimeout.button.no": "아니오",
        "turnTimeout.button.confirmed": "확인함",

        // R3 WO-13: SessionNotifier.swift (status-channel one-line notifications)
        "notify.result.done": "✅ <#{channel}> 완료",
        "notify.result.tokens": " · {tokensIn}/{tokensOut} tok",
        "notify.result.duration": " · {ms}ms",
        "notify.result.cost": " · ${cost}",
        "notify.error": "❌ <#{channel}> 에러: {message}",
        "notify.rateLimit": "📊 <#{channel}> 사용량 한도 · {windows}",
        "notify.rateLimit.base": "📊 <#{channel}> 사용량 한도",
        "notify.rateLimit.type": " · {label}",
        "notify.rateLimit.utilization": " · 사용량 {util}%",
        "notify.rateLimit.reset": " · 리셋 {time}",
        "notify.toolUse": "🔧 <#{channel}> {name}",

        // R3 WO-14: CodexTurnAccumulator.swift (CodexProgressLabels)
        "codex.progress.working": "작업 중",
        "codex.progress.commandExecution": "명령 실행 중",
        "codex.progress.fileChange": "파일 수정 중",
        "codex.progress.fileSearch": "파일 탐색 중",
        "codex.progress.webSearch": "웹 검색 중",
        "codex.progress.image": "이미지 생성 중",
        "codex.progress.mcpToolCall": "도구 실행 중",
        "codex.progress.collabAgentToolCall": "서브에이전트 작업 중",
        "codex.progress.fileChangeCount": "{count}개 파일",

        // R3 WO-15: AppServerClient.swift
        "codex.notInstalled": "`codex` CLI를 찾을 수 없습니다. 설치 여부와 PATH를 확인하세요.",
        "codex.notLoggedIn":
            "Codex에 로그인되어 있지 않습니다. 터미널에서 `codex login`을 실행한 뒤 다시 시도하세요.",

        // R3 (found beyond WO-6 scope): AcpClient.swift — Grok equivalent of codex.notInstalled/notLoggedIn
        "grok.notInstalled": "`grok` CLI를 찾을 수 없습니다. 설치 여부와 PATH를 확인하세요.",
        "grok.notLoggedIn":
            "Grok에 로그인되어 있지 않습니다. 터미널에서 `grok login`을 실행한 뒤 다시 시도하세요.",

        // R3 WO-16: RedmineIssueEmbedSpec.swift
        "redmine.embed.project": "프로젝트",
        "redmine.embed.targetVersion": "목표 버전",

        // R3 WO-17: SessionPersist.swift
        "session.fallbackNotice": "⚠️ 이전 세션 복구 실패 — 새 세션으로 시작합니다.",

        // design_orchestration_project_scoped_command.md §4.9: project-scoped /orchestration
        "orchestration.wrongChannel":
            "이 명령어는 세션 채널(프로젝트 폴더가 연결된 채널)에서만 사용할 수 있습니다.",
        "orchestration.project.installFailed": "오케스트레이션 설치에 실패했어요: {errors}",
        "orchestration.project.installed":
            "프로젝트 `.claude/`(CLAUDE.md + agents/ + skills/)를 `{cwd}` 기준으로 설치했어요.",
        "orchestration.project.freshContextNotice":
            "다음 메시지부터 이 채널은 새 세션으로 다시 연결되고, 프로젝트 설정(`.claude/`)만 적용돼요.",
        "orchestration.project.backedUp": "이전 설정을 `{path}`로 백업했어요.",

        // design_orchestration_module_agents.md WO-1: set category + lead-channel move/rename
        "orchestration.category.moved":
            "`{category}` 카테고리로 이동하고 채널 이름을 `{channel}`로 바꿨어요.",
        "orchestration.category.failed":
            "⚠️ 카테고리 이동에 실패했어요. 채널은 그대로 유지돼요.",
        "orchestration.restart.modulesClosed":
            "이전 오케스트레이션의 모듈 채널 {n}개를 정리했어요.",

        // design_orchestration_module_agents.md WO-10: start spec card (drop down 4 + 시작/취소)
        "orchestration.wizard.title": "오케스트레이션 시작 스펙",
        "orchestration.wizard.description":
            "총괄과 모듈 담당자가 쓸 모델·추론정도를 고르세요. `시작`을 누르기 전에는 아무 것도 만들어지지 않아요.",
        "orchestration.wizard.omodel": "총괄 모델",
        "orchestration.wizard.oeffort": "총괄 추론정도",
        "orchestration.wizard.mmodel": "모듈 공통 모델",
        "orchestration.wizard.meffort": "모듈 공통 추론정도",
        "orchestration.wizard.tag.lead": "총괄",
        "orchestration.wizard.tag.module": "모듈",
        "orchestration.wizard.cancelled": "오케스트레이션 시작을 취소했어요.",
        "orchestration.wizard.confirmed": "확정된 스펙으로 오케스트레이션을 준비하고 있어요…",
        "orchestration.wizard.backendNotClaude":
            "이 채널의 백엔드가 Claude가 아니어서 오케스트레이션을 시작할 수 없어요. `/mode backend claude`로 바꾼 뒤 다시 시도하세요.",
        "orchestration.wizard.sessionMissing": "카드 세션이 없어요. `/orchestration`을 다시 실행해 주세요.",
        "orchestration.wizard.appliedSpec":
            "총괄 모델·추론정도를 `{model}` / {effort}로 적용했어요. 모듈 채널은 `{moduleModel}` / {moduleEffort}로 시작돼요.",
        "orchestration.wizard.appliedSpecFailed":
            "⚠️ 총괄 모델·추론정도(`{model}` / {effort}) 적용에는 실패했어요. 세션은 정상적으로 시작됐으니 `/model`·`/effort`로 다시 설정해 주세요.",
        // Keep at or under 32 scalars (§8-1 C15 house rule for user-facing Korean surfaces).
        // WO-9: says only what is actually known. The list is missing for two reasons that look
        // identical from here (no session yet / warm-up still running), and telling a channel that
        // is mid-conversation to "start the conversation first" was simply false.
        "run.noSession": "명령 목록 불러오는 중 — 잠시 후 다시 열어 주세요",
        // WO-7 modal. Discord's own limits apply here (label 45 / placeholder 100), not the
        // 32-scalar slash-description rule above — these go out through I18n.t, not the spec.
        "run.modal.label": "프롬프트 (선택 · 여러 줄 가능)",
        "run.modal.placeholder": "명령에 넘길 내용을 적어 주세요. 비워두고 제출하면 명령만 실행돼요.",
        "run.started": "`/{command}` 를 실행할게요.",
        "run.unavailable":
            "`/{command}` 는 지금 이 채널의 백엔드에서 쓸 수 없어요. `/command` 를 다시 열어 목록에서 골라 주세요.",
        "run.nameTooLong": "`{command}` 는 이름이 너무 길어 실행할 수 없어요.",
        // WO-10 /command-list. Message body, sent through I18n.t — NOT bound by the 32-scalar slash
        // description rule above (that one only applies to registered command descriptions).
        "help.header": "**{backend}** 백엔드가 지원하는 명령 {count}개",
        "help.plugins": "플러그인",
        "help.more": "…외 {count}개 더 있어요.",
        // The reason this command exists, so it must survive truncation: the picker's 25-item cap,
        // that typing searches past it, and that an unlisted name still runs if typed in full.
        "help.tip": "ℹ️ `/command` 목록에는 25개까지만 보여요. 몇 글자만 입력하면 나머지도 검색되고, 목록에 없는 이름이라도 그대로 입력하면 실행돼요.",
    ]

    /// English overrides (major slash/error/stream paths). Absent keys fall back to ko.
    private static let en: [String: String] = [
        "auth.denied": "Permission denied: {reason}",
        "auth.denied.bare": "Permission denied.",
        "router.noSession": "No session bound to this channel. Run `/agent start` first.",
        "router.turn.queued": "Queued (#{depth}).",
        "cmd.error": "Could not process the command: {error}",
        "cmd.error.generic": "Could not process the command. Please try again shortly.",
        "turn.deliveryFailed": "⚠️ Something went wrong sending the answer. Please try again shortly.",

        "boot.noConfig": "No configuration found. Run setup first:  dab --setup",
        "boot.noToken": "Discord token is not set — run --setup again.",
        "setup.rolesInDiscord":
            "After inviting the bot to your server, set up roles by clicking through the Discord `/config` command.",
        "setup.defaultsInDiscord":
            "Set defaults like model, language, and permissions in Discord `/config` after inviting the bot.",
        "cmd.stop.done": "Stopped the session.",
        "cmd.stopAll.done": "Stopped all sessions ({count}).",
        "cmd.clear.done":
            "Cleared conversation context. Started a fresh session with the same folder and settings.",
        "cmd.clear.doneWithModules":
            "Cleared conversation context and started a fresh session with the same folder and settings. Also cleared {count} module session(s).",
        "cmd.clear.public":
            "🧹 Cleared this channel's conversation context. Prior context will not carry over.",
        "cmd.close.done": "Closed the session and archived it.",
        "cmd.resume.none": "No session to resume. Use `/agent start` to start a new one.",
        "cmd.resume.rebound": "Reconnected this channel.",
        "cmd.start.intro":
            "Chat with the agent in this channel. Sending a message starts work. Use `/agent close` to end the session and clean up the channel.",
        "cmd.start.launched": "Opened the session start wizard.",
        "cmd.start.channelCreated": "Session channel created: {channel}",
        "cmd.setup.done": "Channel setup complete. Start a session with `/agent start` in {control}.",
        "cmd.setup.alreadyDone":
            "Channel setup is already complete. Start a session with `/agent start` in {control}.",
        "cmd.setup.unavailable":
            "Could not create channels. Check that the bot has Manage Channels permission.",
        "cmd.config.opened":
            "Opened the roles & defaults panel. ① Pick roles and save, ② defaults below save on change.",
        "cmd.config.denied": "Only an actual Discord server Administrator can use `/config`.",

        "cmd.mode.switched": "Switched backend to {backend}.",
        "cmd.mode.freshContext":
            "⚠️ Switching to {backend} starts a fresh conversation in this channel. Prior context does not carry over.",
        "cmd.mode.unavailable":
            "The `{backend}` backend is unavailable. Kept the current session unchanged.",
        "cmd.perm.switched": "Updated permission settings: {perm}",
        "cmd.model.switched":
            "Switched this session’s model to {model} (applies from the next turn; conversation kept).",
        "cmd.model.unsupported":
            "This backend does not support switching the model mid-session (Claude only).",
        "cmd.model.failed": "Failed to switch the model. Check the terminal logs.",
        "cmd.effort.switched":
            "Switched this session’s reasoning effort to {effort} (applies from the next turn; conversation kept).",
        "cmd.effort.unsupported":
            "This backend does not support switching the reasoning effort mid-session.",
        "cmd.effort.failed": "Failed to switch the reasoning effort. Check the terminal logs.",

        "cmd.interrupt.button": "⏹️ Stop",
        "cmd.interrupt.done": "Stopped the current task. You can keep the conversation going.",
        "cmd.interrupt.none": "No running task to stop.",

        "result.done": "Done",
        "result.cost": "Cost",
        "result.tokens": "Tokens",
        "result.duration": "Duration",

        "stream.responding": "Responding…",
        "stream.responded": "Response complete",
        "stream.thinking": "Thinking…",
        "stream.thought": "Thought for {sec}s",

        "status.title": "Session status",
        "status.mode": "Mode",
        "status.cwd": "Working folder",
        "status.session": "Session ID",
        "status.permMode": "Permission mode",
        "status.usage.codex": "usage/limits unavailable (Codex CLI limitation)",
        "resume.status.title": "Session resumed",
        "resume.done": "Session resumed: {channel}",
        "resume.none": "No session to resume.",

        "backend.claude": "Claude Code",
        "backend.codex": "Codex",
        "backend.custom": "Custom",

        "perm.request.title": "Permission request",
        "perm.request.body": "**Tool:** {tool}\n\n{input}",
        "perm.button.allow": "Allow",
        "perm.button.always": "Always allow",
        "perm.button.deny": "Deny",
        "perm.decided.allow": "Allowed",
        "perm.decided.always": "Always allowed",
        "perm.decided.deny": "Denied",
        "perm.default": "Default (ask each time)",
        "perm.acceptEdits": "Auto-approve edits",
        "perm.bypassPermissions": "Bypass all permissions (⚠️ dangerous)",
        "perm.plan": "Plan (read-only)",
        "perm.dontAsk": "Pre-approved only (deny unapproved)",
        "perm.auto": "Auto (model decides)",
        "perm.read-only": "Read-only (confirm on run)",
        "perm.workspace-write": "Workspace write allowed",
        "perm.danger-full-access": "Full access (⚠️ no sandbox)",

        "thread.work": "Work log",
        "tool.error": "Error",
        "tool.lines": "{n} lines",
        "tool.noOutput": "no output",
        "transcript.working": "working…",

        "usage.title": "Claude usage",
        "usage.title.grok": "Grok usage",
        "usage.title.codex": "Codex usage",
        "usage.fiveHour": "5-hour",
        "usage.weekly": "Weekly",
        "usage.weeklyOpus": "Weekly (Opus)",
        "usage.weeklySonnet": "Weekly (Sonnet)",
        "usage.context": "Context",
        "usage.resets": "Resets {reset}",
        "usage.clearHint": "~{tokens} tokens saved with /clear",
        "usage.session": "Session config",
        "usage.tools": "Tools this turn",
        "usage.agents": "Subagents",
        "usage.perm": "Permission: {perm}",
        "usage.elapsed.min": "{m}m",
        "usage.elapsed.hourMin": "{h}h {m}m",
        "usage.elapsed.dayHour": "{d}d {h}h",
        "usage.duration.sec": "{s}s",
        "usage.duration.minSec": "{m}m {s}s",
        "usage.overage": "Overage",
        "usage.rateLimitAlert": "📊 Rate limit alert",
        "usage.sessionConfig": "Session settings",
        "usage.model": "Configured model: {model}",
        "usage.effort": "Reasoning: {effort}",
        "usage.model.auto": "Auto-selected",
        "usage.effort.default": "Default",
        "usage.actualModel": "Actual model: {model}",
        "stats.title": "📊 Agent Stats",
        "stats.active": "Active sessions ({n})",
        "stats.none": "No active sessions.",
        "stats.more": "and {n} more…",
        "stats.bindings": "Session bindings",
        "stats.bindings.value": "Active {active} · Archived {archived}",
        "stats.usage": "Claude usage (global)",
        "stats.usage.unavailable": "Only shown when signed in with a Claude subscription (OAuth).",

        "file.escape": "Paths outside the workspace cannot be downloaded.",
        "file.notFound": "File not found.",
        "file.notFile": "Not a file.",

        "doc.shared": "Shared the document into a thread: `{path}`",
        "doc.error.notFound": "File not found: `{path}`",
        "doc.error.escape": "The path cannot be shared.",
        "doc.error.tooLarge": "The file is too large (max {max}).",
        "doc.error.notMarkdown": "Only markdown (.md) files can be shared.",
        "doc.error.notFile": "Not a file (directory/binary): `{path}`",

        "wizard.title": "Start session",
        "wizard.step.folder": "Step 1/5 · Folder",
        "wizard.step.backend": "Step 2/5 · Pick a backend and press \"Next\".",
        "wizard.step.model": "Step 3/5 · Pick a model and press \"Next\".",
        "wizard.step.effort": "Step 4/5 · Pick a reasoning level and press \"Next\".",
        "wizard.step.perm": "Step 5/5 · Pick permissions and press \"✅ Start\".",
        "wizard.confirm": "Start a {backend} session in `{cwd}`? (permission: {perm})",
        "wizard.started": "Started session. Backend {backend} · folder `{cwd}`",
        "wizard.cancelled": "Cancelled session start.",
        "wizard.cancel": "Cancel",
        "wizard.next": "Next",
        "wizard.back": "⬅ Back",
        "wizard.start": "✅ Start",
        "wizard.profile.advanced": "Advanced: choose permission mode manually",
        "wizard.recfg.title": "Switch agent — {backend}",
        "wizard.recfg.step.model": "Step 1/3 · Pick a model and press \"Next\".",
        "wizard.recfg.step.effort": "Step 2/3 · Pick a reasoning level and press \"Next\".",
        "wizard.recfg.step.perm": "Step 3/3 · Pick permissions and press \"✅ Switch\".",
        "wizard.recfg.start": "✅ Switch",
        "wizard.recfg.cancelled": "Agent switch cancelled.",

        "dir.up": "⬆ Parent folder",
        "dir.select": "Go into a subfolder…",
        "dir.here": "✅ Start in this folder",
        "dir.resume": "Resume session",
        "dir.create": "📁 Create folder",
        "dir.empty": "(No subfolders)",
        "dir.escape": "This path is outside the allowed range.",
        "dir.create.title": "Create new folder",
        "dir.create.label": "Folder name",
        "dir.create.placeholder": "e.g. my-project",
        "dir.create.invalid": "Invalid folder name. `/`, `..`, and absolute paths are not allowed.",
        "dir.create.failed": "Failed to create folder: {error}",
        "dir.create.done": "Created folder: {name}",
        "dir.manual": "📝 Enter path manually",
        "dir.manual.title": "Enter path manually",
        "dir.manual.label": "Absolute path",
        "dir.manual.placeholder": "e.g. /Volumes/SourceCode/MyProject",
        "dir.manual.notabs": "Enter an absolute path (e.g. `/Users/...` or `/Volumes/...`).",
        "dir.manual.invalid": "Cannot go to `{path}` (does not exist, is not a folder, or is out of bounds).",
        "dir.manual.done":
            "Moved to `{path}`.\nPress `✅ Start in this folder` to start the session here.",
        "dir.panel": "🖥️ Pick folder on Mac",
        "dir.panel.prompt": "Choose the project folder for the Discord session",
        "dir.panel.wait": "🖥️ Opened a folder picker on the Mac. Pick a folder there… (within 2 min)",
        "dir.panel.cancelled": "Folder pick cancelled.",
        "dir.panel.timeout": "Closed the folder picker after 2 minutes. Use this when you are at the Mac.",
        "dir.panel.busy": "A folder picker is already open. Check the Mac screen.",
        "dir.panel.error": "Could not open the folder picker: {err}",
        "dir.guide":
            "Pick the **project folder** to work in. Go into a subfolder from the list or go up with `⬆ Parent folder`, then press `✅ Start in this folder`.",
        "dir.current": "Current location",

        "resume.step.backend": "Pick the backend to resume and press \"Next\".",
        "resume.step.pick": "Pick the session to resume.",
        "resume.select.placeholder": "Select a session…",
        "resume.time.now": "Just now",
        "resume.time.min": "{n}m ago",
        "resume.time.hour": "{n}h ago",
        "resume.time.day": "{n}d ago",
        "preset.step.pick": "Pick a preset.",
        "preset.pick.placeholder": "Select a preset…",
        "preset.summary": "{backend} · {model} · {effort} · {perm}",
        "preset.direct": "🆕 Set up manually",
        "preset.delete.button": "🗑 Delete",
        "preset.delete.active": "Select a preset to delete.",
        "preset.save.button": "💾 Save as preset",
        "preset.save.title": "Save preset",
        "preset.save.label": "Preset name",
        "preset.save.placeholder": "e.g. claude-opus-plan",
        "preset.saved": "Saved preset: {name}",
        "preset.save.none": "No recent session config to save.",
        "preset.backend.unavailable": "Preset backend ({backend}) is unavailable.",

        "update.title": "🔄 A new version is available",
        "update.body":
            "`discord-agent-bridge` {latest} is available (current {current}).\nUpdate now? Only an admin can decide.\nPressing **Yes** installs it and restarts into the new version immediately (in-flight work is dropped).",
        "update.button.yes": "Yes, update",
        "update.button.no": "No",
        "update.decided.approved": "Updating…",
        "update.decided.dismissed": "Version skipped",
        "update.busy": "An update is already in progress.",
        "update.installing": "Starting the update install…",
        "update.restartRequested":
            "✅ Installed. Restarting the service (a result message will follow)…",
        "update.installed":
            "✅ Installed. Restarting the service (a result message will follow)…",
        "update.restartConfirmed": "✅ Update complete. The new version is running.",
        "update.installFailed":
            "❌ Auto-update failed to install. Run `bash swift/scripts/install.sh` manually, then restart.",
        "update.dismissed": "Muted this version. I’ll notify you again when a newer one ships.",
        "update.denied": "Only a server Administrator or the admin tier can decide auto-updates.",
        "update.manualOnly":
            "Could not find an auto-install path. From a full checkout run `bash swift/scripts/install.sh` to update manually.",
        "update.restartFailed":
            "⚠️ Installed, but service relaunch failed. Restart manually via launchctl/brew services. Log: `~/.dab/logs/supervised-relaunch.log`",
        "update.manualRestartRequired":
            "⚠️ Installed, but service relaunch failed. Restart manually via launchctl/brew services. Log: `~/.dab/logs/supervised-relaunch.log`",
        "update.homebrewInProgress":
            "Installation started. I’ll let you know the restart result separately in a few minutes.",
        "update.homebrewUnavailable":
            "This install is Homebrew but the self-update script was not found. The source-install path will not run. Run `brew update && brew upgrade dab && brew services restart dab` in a terminal.",
        "update.upToDate": "Already up to date.",
        "update.checkFailed": "Version check failed (network/registry).",
        "update.disabled": "Auto-update is off (`autoUpdate.enabled=false`).",

        "render.setup.prompt":
            "🖼 Want tables and diagrams shown as **images**? You can install Chromium (~300MB) for rendering. Without it, answers still display fine as plain text.",
        "render.setup.install": "Install",
        "render.setup.decline": "Later",
        "render.setup.unavailable": "Install isn't available on this host.",
        "render.setup.declined": "Got it — you can install it later from `/config`.",
        "render.setup.already": "A usable browser is already available. Image rendering is on.",
        "render.setup.installing": "Downloading Chromium… (running in background, may take a few minutes)",
        "render.setup.progress": "⏬ **Installing Chromium**\n`{bar}` {pct}%",
        "render.setup.done": "✅ Installed! Tables and diagrams will now render as images.",
        "render.setup.failed": "Install failed. Please try again later from `/config`.",

        "watchdog.idle":
            "No new activity for about 3 minutes. It may still be working on a long task, or it may have stalled. Check above in the channel and any threads, or ask the agent whether the work finished.",

        "config.title": "Roles & defaults settings",
        "config.intro":
            "① Roles: pick the Discord roles allowed to use the bot and **Save**. Put your own (admin) role into **admin** and you're done.\n② The defaults below (backend, model, permission, language) **save as soon as you pick them**.\nClaude and Codex each use their own home (`~/.claude`, `~/.codex`) automatically — **the project folder to work in is picked when you run `/agent start`.**",
        "config.role.admin.placeholder": "admin role (config, stop-all)",
        "config.role.execute.placeholder": "execute role (start sessions, run commands)",
        "config.role.readOnly.placeholder": "read-only role (view only)",
        "config.default.backend.placeholder": "Default backend",
        "config.default.model.placeholder": "Default model",
        "config.default.effort.placeholder": "Default reasoning effort",
        "config.default.permMode.placeholder": "Permission mode (default)",
        "config.default.locale.placeholder": "Bot language",
        "config.save": "Save",
        "config.saved":
            "Saved this server's settings.\n• admin: {admin}\n• execute: {execute}\n• read-only: {readOnly}\n• Default backend: {backend} · model: {model} · permission: {perm}",
        "config.autosaved.locale": "Saved language: {locale}",
        "config.autosaved.backend": "Saved default backend: {backend}",
        "config.autosaved.model": "Saved default model: {model}",
        "config.autosaved.effort": "Saved default reasoning effort: {effort}",
        "config.autosaved.permMode": "Saved permission mode: {perm}",
        "config.notif.button": "🔔 Notification settings",
        "config.notif.title": "Event notification settings",
        "config.notif.intro":
            "Sends a one-line summary of key session events (done, error) to the status channel.\nCurrent state: **{state}**\nPick a status channel below and toggle it on/off with the buttons. Leave it empty to use the default status channel `/setup` created.",
        "config.notif.on": "On",
        "config.notif.off": "Off",
        "config.notif.enable": "Turn on notifications",
        "config.notif.disable": "Turn off notifications",
        "config.notif.channel.placeholder": "Select status channel (defaults to the setup status channel if empty)",
        "config.render.button": "🖼 Image rendering",
        "config.render.title": "Table/diagram image rendering",
        "config.render.intro":
            "Renders tables and mermaid diagrams in answers as attached images.\nCurrent state: **{state}**\nRendering requires Chromium. The system Chrome is used if present; otherwise you can download it below with **Install** (~300MB, in background).",
        "config.render.on": "On",
        "config.render.off": "Off",
        "config.render.enable": "Turn on rendering",
        "config.render.disable": "Turn off rendering",
        "config.render.install": "Install/reinstall Chromium",
        "config.access.title": "👤 Member policy exception",
        "config.access.intro": "Set a final tier exception for only the selected member.",
        "config.access.default": "Default tier: **{tier}**",
        "config.access.selected": "Selected: {user} → **{tier}**",
        "config.access.override": "Saved exception: **{tier}**",
        "config.access.inherited": "No saved exception — the default tier applies.",
        "config.access.noSelection": "Select a user",
        "config.access.user.placeholder": "Member to override (one user)",
        "config.access.tier.placeholder": "Tier to apply",
        "config.access.tier.admin": "admin",
        "config.access.tier.execute": "execute",
        "config.access.tier.read-only": "read-only",
        "config.access.tier.none": "none (block completely)",
        "config.access.apply": "Save exception",
        "config.access.reset": "Restore default",
        "config.access.selectUser": "Select a user first.",
        "config.access.saveFailed": "Could not save the member exception: {error}",
        "config.locale.ko": "한국어 (ko)",
        "config.locale.en": "English (en)",

        // R3 WO-4: Redmine setup modal + issue-select command (dab/DabMain.swift)
        "redmine.config.title": "Redmine integration setup",
        "redmine.config.urlLabel": "Redmine URL",
        "redmine.config.apiKeyLabel": "API key",
        "redmine.config.projectLabel": "Project (optional, empty = all)",
        "redmine.issueSelect.needsSetup": "Set up `/redmine` first.",
        "redmine.issueSelect.empty": "No issues match the criteria.",
        "redmine.issueSelect.prompt": "Select a Redmine issue.",
        "redmine.issueSelect.fetchFailed": "Failed to fetch Redmine issues: {error}",
        "redmine.issueSelect.placeholder.paged": "Issue list ({index}/{total})",
        "redmine.issueSelect.placeholder.single": "Select an issue",

        // R3 WO-5: Redmine config-save + session picker/issue delivery (dab/DabMain.swift)
        "redmine.session.cipherUnavailable":
            "Can't save the Redmine integration: `DAB_REDMINE_KEY_SECRET` is not set on the server. Contact your operator.",
        "redmine.session.configSaved":
            "Redmine integration is set up. Check notifications in the `#{channel}` channel.",
        "redmine.session.configSaveFailed": "Failed to set up the Redmine integration: {error}",
        "redmine.session.configNotFound": "Redmine configuration not found. Set it up with `/redmine` first.",
        "redmine.session.issueGone": "The selected issue can no longer be found.",
        "redmine.session.issueFetchFailed": "Failed to fetch the issue: {error}",
        "redmine.session.selectPrompt": "Select a session.",
        "redmine.session.notFound": "Session not found.",
        "redmine.session.confirmDeliver": "Deliver issue #{issueId} to <#{channel}>?",
        "redmine.session.requested": "Requested: <#{channel}>",
        "redmine.session.issueGoneNotice": "⚠️ The selected issue (#{issueId}) can no longer be found.",
        "redmine.session.issueFetchFailedNotice": "⚠️ Failed to fetch the issue: {error}",
        "redmine.session.deliverCancelled": "Cancelled delivery.",
        "session.ownerOrAdminRequired":
            "Only this channel session's owner or an admin can switch to a new session.",
        // NOTE: filed under WO-5 but the actual feature is preset saving — named with the preset.* prefix (Option B, see preset.save.*)
        "preset.save.invalidName": "Preset name must be 1–100 characters.",
        "preset.save.failed": "Failed to save the preset: {error}",

        // R3 WO-6: DabMain.swift remaining hardcoded replies
        "perm.request.notAuthorized":
            "Only the session approver can make this decision (or it was already handled/expired).",
        "cmd.model.missingValue": "A `model` value is required.",
        "cmd.effort.missingValue": "An `effort` value is required.",
        "cmd.mode.unknownBackend": "Unknown backend",
        "cmd.perm.missingValue": "A `perm` value is required.",
        "cmd.unknownSubcommand": "Unknown subcommand: {name}",
        "stats.versionLine": "\n**Version** `{version}`{dismissed}",
        "stats.dismissedSuffix": " · dismissed `{version}`",
        "config.loadFailed": "Can't read config.json. Check the config file: {error}",
        "cmd.doc.missingPath": "A `path` value is required.",
        "doc.error.shareFailed": "Failed to share the document. Please try again shortly.",
        "update.notReady": "The updater isn't ready yet. Please try again shortly.",
        "wizard.sessionMissing": "No wizard session found. Reopen it with `/agent start`.",
        "wizard.notOwner": "Only the person who opened this wizard can use it.",
        "wizard.resumeSessionMissing":
            "No resume-wizard session found. Reopen it via `/agent start` → Resume session.",
        "wizard.recfg.noSession": "Switch failed: no session is bound to this channel.",
        "wizard.recfg.noSelection": "Switch failed (nothing selected).",
        "wizard.recfg.saveFailed":
            "Failed to save the session settings. The existing session was not changed.",
        "wizard.recfg.bound":
            "This channel is now bound to a {backend} session. cwd={cwd}. Just send messages without a prefix now.",
        "wizard.start.noSelection": "Start failed (nothing selected).",
        "wizard.unknownModal": "Unknown modal.",
        "cmd.attachment.failed": "Failed to process the attachment: {error}",
        "turnTimeout.prompt": "Start again?",
        "turnTimeout.newSessionReady": "A new session is ready. Send a message to start it.",

        // R3 WO-7: RedmineKickoffPrompt.swift
        "redmine.kickoff.prompt":
            "**#{issueId} {subject}**\n\n{description}\n\nPlease briefly review the above.",

        // R3 WO-8: RedmineSessionPicker.swift
        "redmine.session.newSession": "🆕 New session",
        "redmine.session.placeholder.paged": "Session list ({index}/{total})",
        "redmine.session.placeholder.single": "Select a session",

        // R3 WO-9: AutoUpdateWiring.swift (formatUpdateCheckReply)
        "update.check.current": " (current `{version}`)",
        "update.check.upToDateCurrent": " current `{version}`",
        "update.check.registrySuffix": " / registry `{version}`",
        "update.check.dismissed":
            "New version `{latest}` is available but dismissed (current `{current}`). We'll let you know again when a newer one ships.",
        "update.check.available": "New version `{latest}` is available (current `{current}`).",

        // R3 WO-11: ConfigPanel.swift save-failure notices + access button
        "config.autosaved.roleFailed": "Failed to save roles: {error}",
        "config.autosaved.backendFailed": "Failed to save backend: {error}",
        "config.autosaved.modelFailed": "Failed to save model: {error}",
        "config.autosaved.effortFailed": "Failed to save effort: {error}",
        "config.autosaved.permModeFailed": "Failed to save permission mode: {error}",
        "config.autosaved.notifFailed": "Failed to save notification settings: {error}",
        "config.autosaved.notifChannelFailed": "Failed to save the status channel: {error}",
        "config.autosaved.renderFailed": "Failed to save render setting: {error}",
        "config.autosaved.chromiumFailed": "Failed to save chromium setting: {error}",
        // ConfigPanel.swift:656 — not in the WO-11 list, but still hardcoded Korean in the file (found live; included since the pass criteria is file-wide)
        "config.autosaved.localeFailed": "Failed to save locale: {error}",
        "config.access.button": "👤 Access",

        // R3 WO-12: UpdateButton.swift (redmine issue buttons + turn-timeout retry buttons)
        "redmine.issue.button.start": "Start",
        "redmine.issue.button.cancel": "Cancel",
        "redmine.issue.button.confirm": "Confirm",
        "redmine.issue.button.started": "Started",
        "redmine.issue.button.cancelled": "Cancelled",
        "redmine.issue.button.done": "Done",
        "redmine.issue.button.restart": "Restart",
        "turnTimeout.button.yes": "Yes",
        "turnTimeout.button.no": "No",
        "turnTimeout.button.confirmed": "Confirmed",

        // R3 WO-13: SessionNotifier.swift (status-channel one-line notifications)
        "notify.result.done": "✅ <#{channel}> done",
        "notify.result.tokens": " · {tokensIn}/{tokensOut} tok",
        "notify.result.duration": " · {ms}ms",
        "notify.result.cost": " · ${cost}",
        "notify.error": "❌ <#{channel}> error: {message}",
        "notify.rateLimit": "📊 <#{channel}> usage limit · {windows}",
        "notify.rateLimit.base": "📊 <#{channel}> usage limit",
        "notify.rateLimit.type": " · {label}",
        "notify.rateLimit.utilization": " · usage {util}%",
        "notify.rateLimit.reset": " · resets {time}",
        "notify.toolUse": "🔧 <#{channel}> {name}",

        // R3 WO-14: CodexTurnAccumulator.swift (CodexProgressLabels)
        "codex.progress.working": "Working",
        "codex.progress.commandExecution": "Running command",
        "codex.progress.fileChange": "Editing file",
        "codex.progress.fileSearch": "Searching files",
        "codex.progress.webSearch": "Searching the web",
        "codex.progress.image": "Generating image",
        "codex.progress.mcpToolCall": "Running tool",
        "codex.progress.collabAgentToolCall": "Subagent working",
        "codex.progress.fileChangeCount": "{count} file(s)",

        // R3 WO-15: AppServerClient.swift
        "codex.notInstalled": "Can't find the `codex` CLI. Check that it's installed and on PATH.",
        "codex.notLoggedIn": "Not logged in to Codex. Run `codex login` in a terminal, then try again.",
        "grok.notInstalled": "Can't find the `grok` CLI. Check that it's installed and on PATH.",
        "grok.notLoggedIn": "Not logged in to Grok. Run `grok login` in a terminal, then try again.",

        // R3 WO-16: RedmineIssueEmbedSpec.swift
        "redmine.embed.project": "Project",
        "redmine.embed.targetVersion": "Target version",

        // R3 WO-17: SessionPersist.swift
        "session.fallbackNotice": "⚠️ Failed to restore the previous session — starting a new one.",

        // design_orchestration_project_scoped_command.md §4.9: project-scoped /orchestration
        "orchestration.wrongChannel":
            "This command can only be used in a session channel bound to a project folder.",
        "orchestration.project.installFailed": "Failed to install orchestration: {errors}",
        "orchestration.project.installed":
            "Installed the project `.claude/` (CLAUDE.md + agents/ + skills/) under `{cwd}`.",
        "orchestration.project.freshContextNotice":
            "From the next message, this channel reconnects with a fresh session using only the project's `.claude/` settings.",
        "orchestration.project.backedUp": "Backed up the previous configuration to `{path}`.",

        "orchestration.category.moved":
            "Moved into the `{category}` category and renamed the channel to `{channel}`.",
        "orchestration.category.failed":
            "⚠️ Failed to move the category. The channel stays as-is.",
        "orchestration.restart.modulesClosed":
            "Cleaned up {n} module channel(s) from the previous orchestration run.",

        // design_orchestration_module_agents.md WO-10: start spec card (4 dropdowns + Start/Cancel)
        "orchestration.wizard.title": "Orchestration start spec",
        "orchestration.wizard.description":
            "Pick the model/effort the lead and modules will use. Nothing is created until you press Start.",
        "orchestration.wizard.omodel": "Lead model",
        "orchestration.wizard.oeffort": "Lead effort",
        "orchestration.wizard.mmodel": "Module model (shared)",
        "orchestration.wizard.meffort": "Module effort (shared)",
        "orchestration.wizard.tag.lead": "Lead",
        "orchestration.wizard.tag.module": "Module",
        "orchestration.wizard.cancelled": "Cancelled starting orchestration.",
        "orchestration.wizard.confirmed": "Setting up orchestration with the confirmed spec…",
        "orchestration.wizard.backendNotClaude":
            "This channel's backend isn't Claude, so orchestration can't start. Switch with `/mode backend claude` and try again.",
        "orchestration.wizard.sessionMissing": "No card session found. Run `/orchestration` again.",
        "orchestration.wizard.appliedSpec":
            "Applied lead model/effort `{model}` / {effort}. Module channels will start at `{moduleModel}` / {moduleEffort}.",
        "orchestration.wizard.appliedSpecFailed":
            "⚠️ Failed to apply the lead model/effort (`{model}` / {effort}). The session started fine — set them again with `/model`/`/effort`.",
        "run.noSession": "Loading the command list — reopen /command in a moment",
        "run.modal.label": "Prompt (optional, multi-line)",
        "run.modal.placeholder": "Anything to pass to the command. Submit it empty to run the command on its own.",
        "run.started": "Running `/{command}`.",
        "run.unavailable":
            "`/{command}` isn't available on this channel's backend right now. Open `/command` again and pick from the list.",
        "run.nameTooLong": "`{command}` has too long a name to run.",
        "help.header": "**{backend}** backend supports {count} commands",
        "help.plugins": "Plugins",
        "help.more": "…and {count} more.",
        "help.tip": "ℹ️ `/command`'s picker shows only 25 at a time. Type a few letters to search the rest — and a name that never shows up there still runs if you type it out in full.",
    ]
}
