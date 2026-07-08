// Korean-default localizable bot messages (§4, §11 item 14). Every user-facing
// bot string flows through t(key, vars?): a flat catalog keyed by dotted names,
// default locale 'ko'. A missing key falls back to the key itself (so a typo is
// visible, never a blank string), and {placeholders} are interpolated from vars.
//
// The catalog is intentionally flat and local to the discord layer — core stays
// transport-agnostic. 7b/8 sets the active locale from config.locale (§8.1).

export type Locale = 'ko' | 'en';

// The default active locale; overridden at boot from config.locale.
let activeLocale: Locale = 'ko';

export function setLocale(locale: Locale): void {
  activeLocale = locale;
}

export function getLocale(): Locale {
  return activeLocale;
}

// Flat message catalog per locale. Korean is the source of truth (default); the
// English map need only cover keys that have an English rendering — a key absent
// from the active locale falls back to 'ko', then to the key itself.
type Catalog = Record<string, string>;

const ko: Catalog = {
  // Wizard (steps: 폴더 → 백엔드 → 모델 → 추론수준 → 권한 → 시작)
  'wizard.title': '세션 시작',
  'wizard.step.folder': '1/5단계 · 폴더',
  'wizard.step.backend': '2/5단계 · 백엔드를 선택하고 "다음"을 누르세요.',
  'wizard.step.model': '3/5단계 · 모델을 선택하고 "다음"을 누르세요.',
  'wizard.step.effort': '4/5단계 · 추론 수준을 선택하고 "다음"을 누르세요.',
  'wizard.step.perm': '5/5단계 · 권한을 선택하고 "✅ 시작"을 누르세요.',
  'wizard.confirm': '`{cwd}` 에서 {backend} 세션을 시작할까요? (권한: {perm})',
  'wizard.started': '세션을 시작했어요. 백엔드 {backend} · 폴더 `{cwd}`',
  'wizard.cancelled': '세션 시작을 취소했어요.',
  'wizard.cancel': '취소',
  'wizard.next': '다음',
  'wizard.start': '✅ 시작',
  'wizard.profile.advanced': '고급: 권한 모드 직접 선택',
  // /config panel (role tiers + defaults, clicked in Discord)
  'config.title': '역할·기본값 설정',
  'config.intro':
    '① 역할: 봇을 쓸 사람의 Discord 역할을 고르고 **저장**하세요. 본인(관리자)이 가진 역할을 **admin**에 넣으면 다 됩니다.\n② 아래 기본값(백엔드·모델·권한·언어)은 **고르면 바로 저장**됩니다.\nClaude·Codex는 각자 홈(`~/.claude`, `~/.codex`)을 자동으로 사용하며, **작업할 프로젝트 폴더는 `/agent start` 할 때 고릅니다.**',
  'config.role.admin.placeholder': 'admin 역할 (설정·stop-all)',
  'config.role.execute.placeholder': 'execute 역할 (세션 시작·명령 실행)',
  'config.role.readOnly.placeholder': 'read-only 역할 (읽기 전용)',
  'config.default.backend.placeholder': '기본 백엔드',
  'config.default.model.placeholder': '기본 모델',
  'config.default.effort.placeholder': '기본 추론 수준',
  'config.default.permMode.placeholder': '권한 모드 (기본)',
  'config.default.locale.placeholder': '봇 언어',
  'config.locale.ko': '한국어 (ko)',
  'config.locale.en': 'English (en)',
  'config.save': '저장',
  'config.saved':
    '이 서버 설정을 저장했어요.\n• admin: {admin}\n• execute: {execute}\n• read-only: {readOnly}\n• 기본 백엔드: {backend} · 모델: {model} · 권한: {perm}',
  // Auto-save notices: each /config select persists ONE field immediately.
  'config.autosaved.locale': '언어를 저장했어요: {locale}',
  'config.autosaved.backend': '기본 백엔드를 저장했어요: {backend}',
  'config.autosaved.model': '기본 모델을 저장했어요: {model}',
  'config.autosaved.effort': '기본 추론 수준을 저장했어요: {effort}',
  'config.autosaved.permMode': '권한 모드를 저장했어요: {perm}',
  // Notifications sub-panel (🔔): forward session 이벤트(완료·에러)를 상태 채널로 요약 전송.
  'config.notif.button': '🔔 알림 설정',
  'config.notif.title': '이벤트 알림 설정',
  'config.notif.intro':
    '세션의 주요 이벤트(완료·에러)를 상태 채널로 한 줄 요약해 보냅니다.\n현재 상태: **{state}**\n아래에서 상태 채널을 고르고, 버튼으로 켜고 끌 수 있어요. 채널을 비우면 `/init` 이 만든 기본 상태 채널을 사용합니다.',
  'config.notif.on': '켜짐',
  'config.notif.off': '꺼짐',
  'config.notif.enable': '알림 켜기',
  'config.notif.disable': '알림 끄기',
  'config.notif.channel.placeholder': '상태 채널 선택 (비우면 기본 상태 채널)',
  // Backend / permission mode labels
  'backend.claude': 'Claude Code',
  'backend.codex': 'Codex',
  // Confirmation/notice labels (NOT the dropdown OPTION labels — those are English,
  // sourced from providerCatalog). Used in save/switch notices and the wizard confirm.
  'perm.default': '기본 (매번 확인)',
  'perm.acceptEdits': '편집 자동 승인',
  'perm.bypassPermissions': '전체 자동 승인 (⚠️ 위험)',
  'perm.plan': '플랜 (읽기 전용)',
  'perm.dontAsk': '사전 승인만 허용 (미승인 거부)',
  'perm.auto': '자동 판단 (모델이 승인/거부)',
  // Codex-native sandbox modes (shown in the status embed for a Codex session).
  'perm.read-only': '읽기 전용 (실행 시 확인)',
  'perm.workspace-write': '작업 폴더 쓰기 허용',
  'perm.danger-full-access': '전체 접근 (⚠️ 샌드박스 없음)',
  // Directory browser
  'dir.up': '⬆ 상위 폴더',
  'dir.select': '하위 폴더로 이동…',
  'dir.here': '✅ 이 폴더로 시작',
  'dir.resume': '세션 재개',
  'dir.create': '📁 폴더 만들기',
  'dir.empty': '(하위 폴더 없음)',
  'dir.escape': '허용된 범위를 벗어난 경로입니다.',
  // Folder-create modal (📁 Create): a single text input for the new folder name,
  // created as a direct subfolder of the current browsed directory.
  'dir.create.title': '새 폴더 만들기',
  'dir.create.label': '폴더 이름',
  'dir.create.placeholder': '예: my-project',
  'dir.create.invalid': '폴더 이름이 올바르지 않아요. `/`, `..`, 절대 경로는 쓸 수 없어요.',
  'dir.create.failed': '폴더를 만들지 못했어요: {error}',
  'dir.create.done': '폴더를 만들었어요: {name}',
  // Folder-picker guidance (step 1 of /agent start). Shows the current path + how to
  // navigate; the actual PROJECT folder is chosen HERE (not in /config).
  'dir.guide':
    '작업할 **프로젝트 폴더**를 고르세요. 목록에서 하위 폴더로 들어가거나 `⬆ 상위 폴더`로 올라간 뒤, `✅ 이 폴더로 시작`을 누르세요.',
  'dir.current': '현재 위치',
  // Permission buttons
  'perm.request.title': '권한 요청',
  'perm.request.body': '**도구:** {tool}\n\n{input}',
  'perm.button.allow': '허용',
  'perm.button.always': '항상 허용',
  'perm.button.deny': '거부',
  'perm.decided.allow': '허용됨',
  'perm.decided.always': '항상 허용됨',
  'perm.decided.deny': '거부됨',
  // Status embed
  'status.title': '세션 상태',
  'status.mode': '모드',
  'status.cwd': '작업 폴더',
  'status.session': '세션 ID',
  'status.permMode': '권한 모드',
  'status.usage.codex': '사용량/한도 정보 없음 (Codex CLI 제한)',
  // Result line
  'result.done': '완료',
  'result.cost': '비용',
  'result.tokens': '토큰',
  'result.duration': '소요',
  // Stream embed
  'stream.responding': '응답 중…',
  'stream.thinking': '생각 중…',
  'stream.thought': '{sec}초 동안 생각함',
  // Tool thread
  'tool.result': '결과',
  'tool.error': '오류',
  // Usage panel
  'usage.title': 'Claude 사용량',
  'usage.fiveHour': '5시간',
  'usage.weekly': '주간',
  'usage.weeklyOpus': '주간 (Opus)',
  'usage.weeklySonnet': '주간 (Sonnet)',
  'usage.context': '컨텍스트',
  'usage.resets': '초기화 {reset}',
  'usage.clearHint': '/clear 시 ~{tokens} 토큰 절약',
  'usage.session': '세션 구성',
  'usage.tools': '이번 턴 도구',
  'usage.agents': '서브에이전트',
  'usage.perm': '권한: {perm}',
  'usage.elapsed.min': '{m}분',
  'usage.elapsed.hourMin': '{h}시간 {m}분',
  'usage.elapsed.dayHour': '{d}일 {h}시간',
  'usage.duration.sec': '{s}초',
  'usage.duration.minSec': '{m}분 {s}초',
  // File download
  'file.escape': '워크스페이스를 벗어난 경로는 다운로드할 수 없습니다.',
  'file.notFound': '파일을 찾을 수 없습니다.',
  'file.notFile': '파일이 아닙니다.',
  // Transcript feed (Codex)
  'transcript.working': '작업 중…',
  // Router notices (7b)
  'auth.denied': '권한이 없습니다: {reason}',
  'router.noSession': '이 채널에는 활성 세션이 없어요. 먼저 `/agent start` 를 실행하세요.',
  'router.turn.queued': '대기열에 추가했어요 (#{depth}).',
  'cmd.start.launched': '세션 시작 마법사를 열었어요.',
  'cmd.start.channelCreated': '세션 채널 생성됨: {channel}',
  'cmd.start.intro': '이 채널에서 에이전트와 대화하세요. 메시지를 보내면 작업이 시작됩니다. `/agent close` 로 세션을 종료하고 채널을 정리할 수 있어요.',
  'cmd.init.done': '채널 구성을 완료했어요. {control} 에서 `/agent start` 로 세션을 시작하세요.',
  'cmd.init.unavailable': '채널을 만들 수 없어요. 봇에 "채널 관리(Manage Channels)" 권한이 있는지 확인하세요.',
  'cmd.config.opened': '역할·기본값 설정 패널을 열었어요. ① 역할을 고르고 저장, ② 아래 기본값은 고르면 바로 저장돼요.',
  'cmd.config.denied': '`/config` 는 서버 관리자(Administrator) 또는 admin 티어만 사용할 수 있어요.',
  'cmd.resume.none': '재개할 수 있는 세션이 없어요. 새로 시작하려면 `/agent start` 를 사용하세요.',
  'cmd.resume.rebound': '이 채널을 다시 연결했어요.',
  // /agent stats — 활성 세션·바인딩·사용량 요약 (요청자에게만 보이는 ephemeral 임베드).
  'stats.title': '📊 Agent Stats',
  'stats.active': '활성 세션 ({n})',
  'stats.none': '활성 세션이 없어요.',
  'stats.more': '외 {n}개 더…',
  'stats.bindings': '세션 바인딩',
  'stats.bindings.value': '활성 {active} · 보관 {archived}',
  'stats.usage': 'Claude 사용량 (전역)',
  'stats.usage.unavailable': 'Claude 구독 로그인(OAuth) 상태에서만 표시됩니다.',
  // Resume-from-folder flow (Resume Session button on the folder step).
  'resume.step.backend': '재개할 백엔드를 선택하고 "다음"을 누르세요.',
  'resume.step.pick': '재개할 세션을 선택하세요.',
  'resume.select.placeholder': '세션 선택…',
  'resume.none': '재개할 세션이 없습니다.',
  'resume.done': '세션 재개됨: {channel}',
  'resume.status.title': '세션 재개됨',
  'resume.time.now': '방금',
  'resume.time.min': '{n}분 전',
  'resume.time.hour': '{n}시간 전',
  'resume.time.day': '{n}일 전',
  'cmd.close.done': '세션을 종료하고 보관했어요.',
  'cmd.stop.done': '세션을 중지했어요.',
  'cmd.stopAll.done': '모든 세션을 중지했어요 ({count}개).',
  // Interrupt (⏹️ stop button): cancels the current turn only; the session/context stay.
  'cmd.interrupt.button': '⏹️ 중단',
  'cmd.interrupt.done': '현재 작업을 중단했어요. 이어서 대화할 수 있어요.',
  'cmd.interrupt.none': '중단할 실행 중인 작업이 없어요.',
  'cmd.mode.switched': '백엔드를 {backend} 로 바꿨어요.',
  'cmd.mode.freshContext': '⚠️ {backend} 로 바꾸면 이 채널은 새 대화로 시작돼요. 이전 맥락은 안 넘어갑니다.',
  'cmd.mode.unavailable': '`{backend}` 백엔드는 사용할 수 없어요. 현재 세션은 그대로 유지했어요.',
  'cmd.perm.switched': '권한 설정을 바꿨어요: {perm}',
  'cmd.error': '명령을 처리하지 못했어요: {error}',
  // Generic ack for an interaction that failed before/while routing (no detail leaked).
  'cmd.error.generic': '명령을 처리하지 못했어요. 잠시 후 다시 시도해 주세요.',
  // Startup guidance (boot path): config missing / token missing → point at --setup.
  'boot.noConfig': '설정이 없습니다. 먼저 셋업을 실행하세요:  node dist/cli.js --setup',
  'boot.noToken': '토큰이 설정되지 않았습니다 — --setup을 다시 실행하세요.',
  // Terminal setup guidance: roles move from the terminal to Discord `/config`.
  'setup.rolesInDiscord': '역할은 봇을 서버에 초대한 뒤 Discord에서 `/config` 명령으로 클릭 설정하세요.',
  // Terminal setup guidance: model/language/permission defaults move to `/config`.
  'setup.defaultsInDiscord': '모델·언어·권한 등 기본값은 봇 초대 후 Discord `/config`에서 설정하세요.',
};

const en: Catalog = {
  'wizard.title': 'Start session',
  'wizard.confirm': 'Start a {backend} session in `{cwd}`? (permission: {perm})',
  'perm.button.allow': 'Allow',
  'perm.button.always': 'Always allow',
  'perm.button.deny': 'Deny',
  'status.usage.codex': 'usage/limits unavailable (Codex CLI limitation)',
  'transcript.working': 'working…',
  'boot.noConfig': 'No configuration found. Run setup first:  node dist/cli.js --setup',
  'boot.noToken': 'Discord token is not set — run --setup again.',
  'config.default.locale.placeholder': 'Bot language',
  'config.default.effort.placeholder': 'Default reasoning effort',
  'config.default.permMode.placeholder': 'Permission mode (default)',
  'config.autosaved.locale': 'Saved language: {locale}',
  'config.autosaved.backend': 'Saved default backend: {backend}',
  'config.autosaved.model': 'Saved default model: {model}',
  'config.autosaved.effort': 'Saved default reasoning effort: {effort}',
  'config.autosaved.permMode': 'Saved permission mode: {perm}',
  'dir.up': '⬆ Parent folder',
  'dir.select': 'Go into a subfolder…',
  'dir.here': '✅ Start in this folder',
  'dir.current': 'Current location',
  'cmd.interrupt.button': '⏹️ Stop',
  'cmd.interrupt.done': 'Stopped the current task. You can keep the conversation going.',
  'cmd.interrupt.none': 'No running task to stop.',
};

const catalogs: Record<Locale, Catalog> = { ko, en };

// Interpolate {name} placeholders from vars. An unknown placeholder is left as-is
// (visible), never silently blanked.
function interpolate(template: string, vars?: Record<string, string | number>): string {
  if (!vars) return template;
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => {
    const v = vars[name];
    return v === undefined ? whole : String(v);
  });
}

// Resolve a key in the active locale, falling back to 'ko', then to the key
// itself, then interpolate. `locale` overrides the active locale for one call.
export function t(
  key: string,
  vars?: Record<string, string | number>,
  locale: Locale = activeLocale,
): string {
  const template = catalogs[locale]?.[key] ?? ko[key] ?? key;
  return interpolate(template, vars);
}
