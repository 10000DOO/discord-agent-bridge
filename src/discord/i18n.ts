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
  // Wizard (steps: 폴더 → 백엔드 → 모델 → 권한 → 시작)
  'wizard.title': '세션 시작',
  'wizard.step.folder': '1/4단계 · 폴더',
  'wizard.step.backend': '2/4단계 · 백엔드를 선택하세요.',
  'wizard.step.model': '3/4단계 · 모델을 선택하세요.',
  'wizard.step.perm': '4/4단계 · 권한 모드 또는 프로필을 선택하세요.',
  'wizard.confirm': '`{cwd}` 에서 {backend} 세션을 시작할까요? (권한: {perm})',
  'wizard.started': '세션을 시작했어요. 백엔드 {backend} · 폴더 `{cwd}`',
  'wizard.cancelled': '세션 시작을 취소했어요.',
  'wizard.cancel': '취소',
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
  'config.autosaved.permMode': '권한 모드를 저장했어요: {perm}',
  // Backend / permission mode labels
  'backend.claude': 'Claude Code',
  'backend.codex': 'Codex',
  'perm.default': '기본 (매번 확인)',
  'perm.acceptEdits': '편집 자동 승인',
  'perm.bypassPermissions': '전체 자동 승인 (⚠️ 위험)',
  'perm.plan': '플랜 (읽기 전용)',
  // Directory browser
  'dir.up': '⬆ 상위 폴더',
  'dir.select': '하위 폴더로 이동…',
  'dir.here': '✅ 이 폴더로 시작',
  'dir.empty': '(하위 폴더 없음)',
  'dir.escape': '허용된 범위를 벗어난 경로입니다.',
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
  'cmd.config.opened': '역할·기본값 설정 패널을 열었어요. ① 역할을 고르고 저장, ② 아래 기본값은 고르면 바로 저장돼요.',
  'cmd.config.denied': '`/config` 는 서버 관리자(Administrator) 또는 admin 티어만 사용할 수 있어요.',
  'cmd.resume.none': '재개할 수 있는 세션이 없어요. 새로 시작하려면 `/agent start` 를 사용하세요.',
  'cmd.resume.rebound': '이 채널을 다시 연결했어요.',
  'cmd.close.done': '세션을 종료하고 보관했어요.',
  'cmd.stop.done': '세션을 중지했어요.',
  'cmd.stopAll.done': '모든 세션을 중지했어요 ({count}개).',
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
  'config.default.permMode.placeholder': 'Permission mode (default)',
  'config.autosaved.locale': 'Saved language: {locale}',
  'config.autosaved.backend': 'Saved default backend: {backend}',
  'config.autosaved.model': 'Saved default model: {model}',
  'config.autosaved.permMode': 'Saved permission mode: {perm}',
  'dir.up': '⬆ Parent folder',
  'dir.select': 'Go into a subfolder…',
  'dir.here': '✅ Start in this folder',
  'dir.current': 'Current location',
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
