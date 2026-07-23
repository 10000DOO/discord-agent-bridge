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
  'wizard.back': '⬅ 이전',
  'wizard.start': '✅ 시작',
  'wizard.profile.advanced': '고급: 권한 모드 직접 선택',
  // Reconfigure wizard (백엔드 전환 시: 모델 → 추론수준 → 권한 → 전환)
  'wizard.recfg.title': '에이전트 전환 — {backend}',
  'wizard.recfg.step.model': '1/3단계 · 모델을 선택하고 "다음"을 누르세요.',
  'wizard.recfg.step.effort': '2/3단계 · 추론 수준을 선택하고 "다음"을 누르세요.',
  'wizard.recfg.step.perm': '3/3단계 · 권한을 선택하고 "✅ 전환"을 누르세요.',
  'wizard.recfg.start': '✅ 전환',
  'wizard.recfg.cancelled': '에이전트 전환을 취소했어요.',
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
    '세션의 주요 이벤트(완료·에러)를 상태 채널로 한 줄 요약해 보냅니다.\n현재 상태: **{state}**\n아래에서 상태 채널을 고르고, 버튼으로 켜고 끌 수 있어요. 채널을 비우면 `/setup` 이 만든 기본 상태 채널을 사용합니다.',
  'config.notif.on': '켜짐',
  'config.notif.off': '꺼짐',
  'config.notif.enable': '알림 켜기',
  'config.notif.disable': '알림 끄기',
  'config.notif.channel.placeholder': '상태 채널 선택 (비우면 기본 상태 채널)',
  // Image-render sub-panel (🖼): on/off toggle + Chromium install.
  'config.render.button': '🖼 이미지 렌더',
  'config.render.title': '표·다이어그램 이미지 렌더링',
  'config.render.intro':
    '답변의 표(table)와 mermaid 다이어그램을 이미지로 렌더링해 첨부합니다.\n현재 상태: **{state}**\n렌더링에는 Chromium이 필요합니다. 시스템 Chrome이 있으면 그대로 쓰고, 없으면 아래 **설치**로 내려받을 수 있어요(약 300MB, 백그라운드).',
  'config.render.on': '켜짐',
  'config.render.off': '꺼짐',
  'config.render.enable': '렌더 켜기',
  'config.render.disable': '렌더 끄기',
  'config.render.install': 'Chromium 설치/재설치',
  // Chromium install prompt (posted at /setup) + install flow notices.
  'render.setup.prompt':
    '🖼 표·다이어그램을 **이미지로** 보시겠어요? 렌더링에 필요한 Chromium(약 300MB)을 설치할 수 있어요. 설치하지 않아도 답변은 원문 텍스트로 정상 표시됩니다.',
  'render.setup.install': '설치',
  'render.setup.decline': '나중에',
  'render.setup.unavailable': '이 호스트에서는 설치를 사용할 수 없어요.',
  'render.setup.declined': '알겠어요. 나중에 `/config` 에서 설치할 수 있어요.',
  'render.setup.already': '이미 사용 가능한 브라우저가 있어요. 이미지 렌더링이 켜졌습니다.',
  'render.setup.installing': 'Chromium을 내려받는 중이에요… (백그라운드, 몇 분 걸릴 수 있어요)',
  'render.setup.progress': '⏬ **Chromium 설치 중**\n`{bar}` {pct}%',
  'render.setup.done': '✅ 설치 완료! 이제 표·다이어그램이 이미지로 렌더링됩니다.',
  'render.setup.failed': '설치에 실패했어요. 잠시 후 `/config` 에서 다시 시도해 주세요.',
  // Backend / permission mode labels
  'backend.claude': 'Claude Code',
  'backend.codex': 'Codex',
  'backend.custom': 'Custom',
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
  // Manual absolute-path entry (📝): type a path instead of clicking down to it.
  'dir.manual': '📝 경로 직접 입력',
  'dir.manual.title': '경로 직접 입력',
  'dir.manual.label': '절대 경로',
  'dir.manual.placeholder': '예: /Volumes/SourceCode/MyProject',
  'dir.manual.notabs': '절대 경로를 입력하세요 (예: `/Users/...` 또는 `/Volumes/...`).',
  'dir.manual.invalid': '이동할 수 없는 경로예요: `{path}` (존재하지 않거나, 폴더가 아니거나, 허용 범위 밖).',
  'dir.manual.done': '경로로 이동했어요: `{path}`\n`✅ 이 폴더로 시작`을 눌러 이 폴더에서 세션을 시작하세요.',
  // Native host-side folder panel (🖥️): pick the folder in a real open-panel ON the
  // host (macOS). Only useful when the operator is physically at the machine.
  'dir.panel': '🖥️ Mac에서 폴더 선택',
  'dir.panel.prompt': 'Discord 세션 프로젝트 폴더 선택',
  'dir.panel.wait': '🖥️ Mac 화면에 폴더 선택 창을 열었어요. Mac에서 폴더를 선택하세요… (2분 내)',
  'dir.panel.cancelled': '폴더 선택을 취소했어요.',
  'dir.panel.timeout': '폴더 선택 창을 2분이 지나 닫았어요. Mac 앞에 있을 때 사용하세요.',
  'dir.panel.busy': '이미 폴더 선택 창이 열려 있어요. Mac 화면을 확인하세요.',
  'dir.panel.error': '폴더 선택 창을 열지 못했어요: {err}',
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
  'stream.responded': '응답 완료',
  'stream.thinking': '생각 중…',
  'stream.thought': '{sec}초 동안 생각함',
  // Tool thread
  'thread.work': '작업 내역',
  'tool.result': '결과',
  'tool.error': '오류',
  // Usage panel
  'usage.title': 'Claude 사용량',
  'usage.title.grok': 'Grok 사용량',
  'usage.title.codex': 'Codex 사용량',
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
  // Document share (/doc + share_document tool): post a markdown file into a thread.
  // The core returns a ShareErrorCode; the edge localizes it via t('doc.error.'+code).
  'doc.shared': '문서를 스레드에 공유했어요: `{path}`',
  'doc.error.notFound': '파일을 찾을 수 없어요: `{path}`',
  'doc.error.escape': '경로를 공유할 수 없어요.',
  'doc.error.tooLarge': '파일이 너무 커요 (최대 {max}).',
  'doc.error.notMarkdown': '마크다운(.md)만 공유할 수 있어요.',
  'doc.error.notFile': '파일이 아니에요(디렉터리/바이너리): `{path}`',
  // Transcript feed (Codex)
  'transcript.working': '작업 중…',
  // Router notices (7b)
  'auth.denied': '권한이 없습니다: {reason}',
  'router.noSession': '이 채널에는 활성 세션이 없어요. 먼저 `/agent start` 를 실행하세요.',
  'router.turn.queued': '대기열에 추가했어요 (#{depth}).',
  'cmd.start.launched': '세션 시작 마법사를 열었어요.',
  'cmd.start.channelCreated': '세션 채널 생성됨: {channel}',
  'cmd.start.intro': '이 채널에서 에이전트와 대화하세요. 메시지를 보내면 작업이 시작됩니다. `/agent close` 로 세션을 종료하고 채널을 정리할 수 있어요.',
  'cmd.setup.done': '채널 구성을 완료했어요. {control} 에서 `/agent start` 로 세션을 시작하세요.',
  'cmd.setup.alreadyDone': '이미 채널 구성이 모두 되어 있어요. {control} 에서 `/agent start` 로 세션을 시작하세요.',
  'cmd.setup.unavailable': '채널을 만들 수 없어요. 봇에 "채널 관리(Manage Channels)" 권한이 있는지 확인하세요.',
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
  // Session presets (per-guild): preset step shown by /agent start + save-after-done flow.
  'preset.step.pick': '프리셋을 선택하세요.',
  'preset.pick.placeholder': '프리셋 선택…',
  'preset.summary': '{backend} · {model} · {effort} · {perm}',
  'preset.direct': '🆕 직접 설정',
  'preset.delete.button': '🗑 삭제',
  'preset.delete.active': '삭제할 프리셋을 선택하세요.',
  'preset.save.button': '💾 프리셋으로 저장',
  'preset.save.title': '프리셋 저장',
  'preset.save.label': '프리셋 이름',
  'preset.save.placeholder': '예: claude-opus-plan',
  'preset.saved': '프리셋을 저장했어요: {name}',
  'preset.save.none': '저장할 최근 세션 설정이 없어요.',
  'preset.backend.unavailable': '이 프리셋의 백엔드({backend})를 지금은 쓸 수 없어요.',
  'cmd.close.done': '세션을 종료하고 보관했어요.',
  'cmd.stop.done': '세션을 중지했어요.',
  'cmd.stopAll.done': '모든 세션을 중지했어요 ({count}개).',
  // /clear: restart session in place (same folder/settings); conversation context wiped.
  'cmd.clear.done': '대화 컨텍스트를 비웠어요. 같은 폴더·설정으로 새 세션을 시작했습니다.',
  'cmd.clear.public': '🧹 이 채널 대화 컨텍스트를 비웠어요. 이전 맥락은 이어지지 않습니다.',
  // Interrupt (⏹️ stop button): cancels the current turn only; the session/context stay.
  'cmd.interrupt.button': '⏹️ 중단',
  'cmd.interrupt.done': '현재 작업을 중단했어요. 이어서 대화할 수 있어요.',
  'cmd.interrupt.none': '중단할 실행 중인 작업이 없어요.',
  'cmd.mode.switched': '백엔드를 {backend} 로 바꿨어요.',
  'cmd.mode.freshContext': '⚠️ {backend} 로 바꾸면 이 채널은 새 대화로 시작돼요. 이전 맥락은 안 넘어갑니다.',
  'cmd.mode.unavailable': '`{backend}` 백엔드는 사용할 수 없어요. 현재 세션은 그대로 유지했어요.',
  'cmd.perm.switched': '권한 설정을 바꿨어요: {perm}',
  'cmd.model.switched': '이 세션의 모델을 바꿨어요: {model} (다음 응답부터 적용, 대화는 유지)',
  'cmd.model.unsupported': '이 백엔드는 세션 중 모델 변경을 지원하지 않아요 (Claude만 가능).',
  'cmd.model.failed': '모델 변경에 실패했어요. 터미널 로그를 확인해 주세요.',
  'cmd.effort.switched': '이 세션의 추론 강도를 바꿨어요: {effort} (다음 응답부터 적용, 대화는 유지)',
  'cmd.effort.unsupported': '이 백엔드는 세션 중 추론 강도 변경을 지원하지 않아요.',
  'cmd.effort.failed': '추론 강도 변경에 실패했어요. 터미널 로그를 확인해 주세요.',
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
  // Auto-update (§7): the status-channel prompt + admin decision notices.
  'update.title': '🔄 새 버전이 있어요',
  'update.body':
    '`discord-agent-bridge` {latest} 버전이 나왔어요 (현재 {current}).\n지금 업데이트할까요? 관리자만 결정할 수 있어요.\n**예**를 누르면 설치 후 새 버전으로 바로 재시작합니다 (진행 중 작업은 종료돼요).',
  'update.button.yes': '예, 업데이트',
  'update.button.no': '아니오',
  'update.decided.approved': '업데이트 진행 중…',
  'update.decided.dismissed': '이 버전 건너뜀',
  'update.busy': '이미 업데이트가 진행 중이에요.',
  'update.installed': '✅ 설치 완료. 새 버전으로 재시작합니다…',
  'update.installFailed':
    '❌ 자동 업데이트 설치에 실패했어요. 수동으로 `npm i -g discord-agent-bridge@latest` 를 실행한 뒤 `discord-agent-bridge service restart` 로 재시작하세요 (권한이 필요할 수 있어요).',
  'update.dismissed': '이 버전 알림을 껐어요. 더 새 버전이 나오면 다시 알려드릴게요.',
  'update.denied': '자동 업데이트는 서버 관리자(Administrator) 또는 admin 티어만 결정할 수 있어요.',
  // Idle watchdog: one channel notice after ~3 min with no AgentEvent activity on a turn.
  'watchdog.idle':
    '약 3분 동안 새 활동이 없습니다. 아직 긴 작업을 하는 중일 수도 있고, 멈췄을 수도 있습니다. 채널 위쪽·스레드를 확인해 보거나, 작업이 끝났는지 에이전트한테 물어보세요.',
};

const en: Catalog = {
  'backend.custom': 'Custom',
  'wizard.title': 'Start session',
  'wizard.confirm': 'Start a {backend} session in `{cwd}`? (permission: {perm})',
  'wizard.back': '⬅ Back',
  'wizard.recfg.title': 'Switch agent — {backend}',
  'wizard.recfg.step.model': 'Step 1/3 · Pick a model and press "Next".',
  'wizard.recfg.step.effort': 'Step 2/3 · Pick a reasoning level and press "Next".',
  'wizard.recfg.step.perm': 'Step 3/3 · Pick permissions and press "✅ Switch".',
  'wizard.recfg.start': '✅ Switch',
  'wizard.recfg.cancelled': 'Agent switch cancelled.',
  'perm.button.allow': 'Allow',
  'perm.button.always': 'Always allow',
  'perm.button.deny': 'Deny',
  'status.usage.codex': 'usage/limits unavailable (Codex CLI limitation)',
  'usage.title': 'Claude usage',
  'usage.title.grok': 'Grok usage',
  'usage.title.codex': 'Codex usage',
  'thread.work': 'Work log',
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
  'dir.manual': '📝 Enter path manually',
  'dir.manual.title': 'Enter path manually',
  'dir.manual.label': 'Absolute path',
  'dir.manual.placeholder': 'e.g. /Volumes/SourceCode/MyProject',
  'dir.manual.notabs': 'Enter an absolute path (e.g. `/Users/...` or `/Volumes/...`).',
  'dir.manual.invalid': 'Cannot go to `{path}` (does not exist, is not a folder, or is out of bounds).',
  'dir.manual.done': 'Moved to `{path}`.\nPress `✅ Start in this folder` to start the session here.',
  'dir.panel': '🖥️ Pick folder on Mac',
  'dir.panel.prompt': 'Choose the project folder for the Discord session',
  'dir.panel.wait': '🖥️ Opened a folder picker on the Mac. Pick a folder there… (within 2 min)',
  'dir.panel.cancelled': 'Folder pick cancelled.',
  'dir.panel.timeout': 'Closed the folder picker after 2 minutes. Use this when you are at the Mac.',
  'dir.panel.busy': 'A folder picker is already open. Check the Mac screen.',
  'dir.panel.error': 'Could not open the folder picker: {err}',
  'cmd.interrupt.button': '⏹️ Stop',
  'cmd.interrupt.done': 'Stopped the current task. You can keep the conversation going.',
  'cmd.interrupt.none': 'No running task to stop.',
  'cmd.clear.done': 'Cleared conversation context. Started a fresh session with the same folder and settings.',
  'cmd.clear.public': "🧹 Cleared this channel's conversation context. Prior context will not carry over.",
  'doc.shared': 'Shared the document into a thread: `{path}`',
  'doc.error.notFound': 'File not found: `{path}`',
  'doc.error.escape': 'The path cannot be shared.',
  'doc.error.tooLarge': 'The file is too large (max {max}).',
  'doc.error.notMarkdown': 'Only markdown (.md) files can be shared.',
  'doc.error.notFile': 'Not a file (directory/binary): `{path}`',
  'cmd.model.switched': 'Switched this session’s model to {model} (applies from the next turn; conversation kept).',
  'cmd.model.unsupported': 'This backend does not support switching the model mid-session (Claude only).',
  'cmd.model.failed': 'Failed to switch the model. Check the terminal logs.',
  'cmd.effort.switched': 'Switched this session’s reasoning effort to {effort} (applies from the next turn; conversation kept).',
  'cmd.effort.unsupported': 'This backend does not support switching the reasoning effort mid-session.',
  'cmd.effort.failed': 'Failed to switch the reasoning effort. Check the terminal logs.',
  // Session presets (per-guild): preset step shown by /agent start + save-after-done flow.
  'preset.step.pick': 'Pick a preset.',
  'preset.pick.placeholder': 'Select a preset…',
  'preset.summary': '{backend} · {model} · {effort} · {perm}',
  'preset.direct': '🆕 Set up manually',
  'preset.delete.button': '🗑 Delete',
  'preset.delete.active': 'Select a preset to delete.',
  'preset.save.button': '💾 Save as preset',
  'preset.save.title': 'Save preset',
  'preset.save.label': 'Preset name',
  'preset.save.placeholder': 'e.g. claude-opus-plan',
  'preset.saved': 'Saved preset: {name}',
  'preset.save.none': 'No recent session config to save.',
  'preset.backend.unavailable': 'Preset backend ({backend}) is unavailable.',
  'update.title': '🔄 A new version is available',
  'update.body':
    '`discord-agent-bridge` {latest} is available (current {current}).\nUpdate now? Only an admin can decide.\nPressing **Yes** installs it and restarts into the new version immediately (in-flight work is dropped).',
  'update.button.yes': 'Yes, update',
  'update.button.no': 'No',
  'update.decided.approved': 'Updating…',
  'update.decided.dismissed': 'Version skipped',
  'update.busy': 'An update is already in progress.',
  'update.installed': '✅ Installed. Restarting into the new version…',
  'update.installFailed':
    '❌ Auto-update failed to install. Run `npm i -g discord-agent-bridge@latest` manually, then `discord-agent-bridge service restart` (elevated permissions may be required).',
  'update.dismissed': 'Muted this version. I’ll notify you again when a newer one ships.',
  'update.denied': 'Only a server Administrator or the admin tier can decide auto-updates.',
  'watchdog.idle':
    'No new activity for about 3 minutes. It may still be working on a long task, or it may have stalled. Check above in the channel and any threads, or ask the agent whether the work finished.',
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
