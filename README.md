# discord-agent-bridge

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, and more — per channel. Role-based access, multi-server, extensible.

**채널마다 Claude Code / Codex 같은 AI 코딩 에이전트를 붙여 쓰는 셀프호스팅 Discord 봇입니다.** 내 PC에서 실행되고, 역할 기반 권한 · 다중 서버 · 확장 가능 구조를 가집니다.

- 현재 지원: **Claude Code**, **Codex**
- 확장: 모드 플러그인 추가로 다른 에이전트(예: opencode) 연결 가능

> ✅ **npm에 배포되어 있습니다.** `npx discord-agent-bridge` 로 바로 실행하거나(권장), 전역 설치·소스 빌드로도 쓸 수 있습니다. **Claude Code · Codex** 두 백엔드를 지원합니다.

---

## 이게 뭐예요?

Discord 채널에서 대화하듯 메시지를 보내면, 내 컴퓨터에서 Claude Code(또는 Codex)가 그 프로젝트 폴더를 대상으로 작업해 주는 봇입니다.

- **채널 = 세션 = 프로젝트 하나.** 채널을 만들 때 작업 폴더와 백엔드(Claude/Codex)를 정합니다.
- **여러 서버**에 같은 봇을 초대해 쓸 수 있고, **서버/프로젝트마다 설정이 따로** 적용됩니다.
- **역할(Role)로 누가 쓸 수 있는지** 통제합니다.

---

## 준비물

- **Node.js 20 이상**
- 사용할 백엔드에 맞는 CLI가 **설치 + 로그인**되어 있어야 합니다:
  - **Claude 모드** → [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 인증 (`claude` 로그인 또는 `ANTHROPIC_API_KEY`). 사용량/한도 패널을 보려면 **Claude Pro/Max 구독 로그인**이 필요합니다.
  - **Codex 모드** → `codex` CLI 설치 + 로그인.
- **Discord 봇 토큰** (아래 1단계에서 발급)

---

## 1단계 — Discord 봇 만들기 (Developer Portal)

봇을 직접 하나 만들어야 합니다. 5분이면 됩니다.

1. **[Discord Developer Portal](https://discord.com/developers/applications)** 접속 → 오른쪽 위 **New Application** → 이름 입력(예: `my-agent-bot`) → **Create**.
2. 왼쪽 메뉴 **Bot** 탭 → **Reset Token** → 나오는 **토큰을 복사**해 안전한 곳에 보관.
   - ⚠️ 이 토큰은 비밀번호입니다. 노출되면 즉시 **Reset Token**으로 재발급하세요.
3. 같은 **Bot** 탭 아래 **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **필수** (봇이 메시지 내용을 읽어야 함)
   - ✅ **SERVER MEMBERS INTENT** — 권장 (역할 기반 권한 확인에 사용)
   - 켜고 **Save Changes**.
4. 왼쪽 **OAuth2** 탭 → **Client ID(Application ID)** 복사 (셋업에 필요).
5. **초대 링크 만들기** — OAuth2 → **URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - 생성된 URL을 브라우저에 붙여넣어 **내 서버에 초대**.
   - (셋업 마법사가 이 초대 링크를 자동 생성해 주기도 합니다 — 2단계 참고.)

---

## 2단계 — 설치 & 실행

### npx로 실행 (권장)

설치 없이 바로 실행합니다. `npx` 가 최신 버전을 받아 실행하며, 최초 실행이면 셋업 마법사가 먼저 뜬 뒤 이어서 봇이 시작됩니다.

```bash
# 최초 실행 — 셋업 마법사가 자동으로 뜬 뒤 이어서 봇이 시작됩니다.
# (토큰/Client ID 입력, 인텐트 확인, 초대 링크 생성 — 기본값은 안 물어봄)
npx discord-agent-bridge

# 이후 실행 — 이미 설정돼 있으면 바로 봇이 시작됩니다.
npx discord-agent-bridge

# 다시 설정만 하고 싶을 때 (봇은 시작하지 않음)
npx discord-agent-bridge --setup
```

전역 설치도 가능합니다: `npm install -g discord-agent-bridge` 후 `discord-agent-bridge` / `discord-agent-bridge --setup`.

### 업그레이드

새 버전이 나오면:

```bash
# npx 사용자 — @latest 를 붙이면 항상 최신을 받습니다(npx는 캐시를 쓸 수 있어요).
npx discord-agent-bridge@latest

# 전역 설치 사용자
npm install -g discord-agent-bridge@latest
```

설치된 버전 확인: `discord-agent-bridge --version`.

### 소스에서 실행

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install
npm run build

node dist/cli.js           # 최초 1회: 셋업 마법사 자동 실행 → 이어서 봇 시작 / 이후: 바로 봇 시작
node dist/cli.js --setup   # 설정만 다시 (봇은 시작 안 함)
```

**셋업 마법사(`--setup`)** 가 물어보는 것 — **토큰(비밀)만 터미널에서 입력**합니다. 그 외 값은 하나도 안 물어봅니다:
1. Discord 봇 **토큰** (비밀 → 터미널에서만 붙여넣기)
2. **Client ID**
3. Message Content Intent 켰는지 확인
4. 초대 URL 생성 → 서버에 초대

> **역할도, 기본값도 터미널에서 안 정합니다.** 봇을 서버에 초대한 뒤 Discord에서 **`/config`** 명령으로 설정하세요:
> - **역할 티어** — 역할 이름을 **클릭**해 지정(역할 ID 복사·개발자 모드 불필요). 지정 전에는 **모두 거부(deny-by-default)**.
> - **기본값** — **기본 백엔드·모델·권한 모드·언어(locale)** 는 드롭다운에서 고르면 **바로 저장**되고, **Codex 기본 경로(codexHome)** 는 "Codex 경로 설정" 버튼 → 입력창(모달)에서 지정합니다. 언어는 `한국어 (ko)` / `English (en)` 중에서 선택합니다.

설정은 `~/.discord-agent-bridge/` 에 저장됩니다(토큰 파일 권한 600). 역할·기본값은 서버별로 `servers/<guildId>.json` 에 저장됩니다.

---

## 3단계 — Discord에서 사용하기

봇이 서버에 들어오면 **컨트롤 채널(`#session-generator`) · 세션 카테고리 · 알림 채널(`#agent-status`)이 자동으로 생성**됩니다(봇에 채널 관리 권한이 있으면). 이후 순서: **`/config` → `/agent start`**.

1. **(자동)** 봇 시작·서버 초대 시 위 채널 구조가 생성됩니다. 관리자가 **`/init`** 으로 수동 재생성할 수도 있습니다(기존 채널은 재사용 — 중복 생성 없음).
2. **`/config`** (관리자) → 역할 티어·기본값을 지정합니다. (서버 관리자(Administrator)는 역할 설정 없이도 항상 사용할 수 있습니다.)
3. `#session-generator` 에서 **`/agent start`** → **마법사**가 순서대로 안내합니다:
   **작업 폴더 선택 → 백엔드(Claude / Codex) → 모델 → 추론 수준 → 권한 모드**. 각 단계는 **"다음" 버튼**으로 넘어갑니다. 폴더 브라우저는 **상위/다른 볼륨까지 이동 · 새 폴더 생성 · 이전 세션 재개**를 지원합니다. 확인하면 프로젝트 폴더 이름으로 **전용 세션 채널(`proj-<폴더>`)이 새로 생성**되고 그 채널에 바인딩됩니다.
4. 만들어진 세션 채널에서 **그냥 메시지로 대화**하면 됩니다. Claude 모드는 스트리밍 출력·툴 실행 스레드·권한 승인 버튼이 뜹니다.
5. 필요할 때 명령어 사용.

### 주요 명령어
| 명령어 | 설명 |
|---|---|
| `/init` | (관리자) 컨트롤 채널 + 세션 카테고리 생성 (재실행 시 재사용) |
| `/agent start` | 새 세션 시작 — 마법사 확인 시 전용 세션 채널을 새로 생성 |
| `/agent resume` | 이전 세션 이어하기 |
| `/agent close` | 세션 종료 + 세션 채널 삭제 |
| `/agent stats` | 활성 세션 · 세션 통계 · Claude 사용량 보기 (본인에게만 표시) |
| `/mode <claude\|codex>` | 백엔드 전환 (⚠️ 새 대화로 시작 — 이전 맥락 미승계) |
| `/mode perm <모드\|프로필>` | 권한 모드/프로필 전환 (세션 유지) |
| `/stop` | 현재 세션 즉시 중단 (킬 스위치) |
| `/stop-all` | (관리자) 모든 세션 중단 |
| `/config` | (관리자) 역할 티어 + 기본값(백엔드·모델·권한 모드·언어·Codex 경로) 설정 — 역할은 **클릭**, 기본값은 드롭다운/모달에서 지정 |

### 권한 모드 (세션이 얼마나 자율적인지)
- `default` — 도구 실행 전마다 **Allow/Deny 버튼**으로 확인 (가장 안전)
- `acceptEdits` — 파일 수정은 자동 수락
- `plan` — 먼저 계획만 세우고 실행은 보류
- `bypassPermissions` — 전부 자동 (신뢰하는 프로젝트에서만)

(Codex는 CLI의 승인·샌드박스 모드로 매핑됩니다.)

### 이벤트 알림 (`#agent-status`)

여러 세션의 **작업 완료·에러**를 `#agent-status` 채널 한 곳에 모아 요약해 알려줍니다. `/config` → **🔔 알림 설정** 에서 켜기/끄기와 대상 채널을 바꿀 수 있습니다.

---

## 권한 & 역할 설정 (중요)

이 봇은 **당신 PC에서, 당신 계정 권한으로** 코드를 실행합니다. 즉 봇에게 명령할 수 있는 사람은 **당신 컴퓨터에서 명령을 실행할 수 있는 사람**입니다. 그래서 역할 통제가 필수입니다.

- **역할 티어 3단계** — Discord에서 **`/config`** 로 역할 이름을 **클릭**해 지정합니다(역할 ID·개발자 모드 불필요). admin ⊇ execute ⊇ read-only:
  - **admin** — 설정/`stop-all`/`config` 등 관리
  - **execute** — 세션 시작·명령 실행
  - **read-only** — 읽기만
  - > `/config` 는 처음엔 **서버 관리자(Administrator)** 권한이 있는 사람만 열 수 있고(허용 목록이 비어 있어도 부트스트랩 가능), 이후엔 admin 티어도 사용할 수 있습니다.
- **기본은 거부(deny-by-default)** — 허용 목록에 없는 사람은 아무것도 못 합니다. `/config` 로 지정하기 전에는 아무도 실행할 수 없습니다.
- **프로젝트별 접근 제어(ACL)** — 특정 프로젝트를 지정한 역할/사람만 쓰게 할 수 있습니다.
- **감사 로그** — 누가 언제 무엇을 했는지 `~/.discord-agent-bridge/audit/` 에 기록됩니다.

> ⚠️ **보안 주의:** 신뢰하지 않는 서버에 봇을 초대하거나 execute 역할을 너무 넓게 주지 마세요. 작업 폴더 밖(예: `~/.ssh`)은 봇이 접근하지 못하도록 기본 차단되어 있습니다.

---

## Claude 모드 vs Codex 모드

| | Claude 모드 | Codex 모드 |
|---|---|---|
| 실시간 스트리밍 | ✅ | ❌ (최종 결과 위주) |
| 툴 실행 스레드 | ✅ | ❌ |
| 권한 승인 버튼 | ✅ | ❌ (승인/샌드박스 모드로 대체) |
| 세션 이어하기 | ✅ | ✅ |
| **사용량/한도 표시** | ✅ (5시간·주간·컨텍스트) | ❌ (Codex CLI 제약) |

### 터미널에서 쓰던 거랑 똑같나요?

- **Claude 모드** — 터미널의 `claude`와 **같은 엔진**(공식 Claude Agent SDK)을 사용합니다. 프로젝트의 `.claude/` 설정을 그대로 읽어 **서브에이전트·스킬·훅·MCP가 동일하게** 동작하도록 만듭니다. 달라지는 건 입력이 Discord 메시지, 출력이 임베드/스레드라는 **표현 방식**뿐입니다. (터미널에서 타이핑하는 TUI 전용 슬래시 명령은 그대로 치는 방식이 아니라 SDK 방식으로 처리됩니다.)
- **Codex 모드** — `codex exec`(비대화형)로 구동합니다. 같은 Codex 엔진에 설정/MCP를 로드하지만, 비대화형 모드는 인터랙티브 모드와 **일부(승인 방식 등) 다를 수 있고**, 서브에이전트·스킬·MCP가 완전히 동일하게 동작하는지는 환경에 따라 차이가 있을 수 있습니다.

---

## 설정 파일 위치

```
~/.discord-agent-bridge/
├─ config.json            # 봇 토큰·Client ID·기본값·한도 (권한 600)
├─ servers/<guildId>.json # 서버별 역할 티어·기본값 · 채널 구조(control/sessions/status) ID · 알림 설정 (권한 600)
├─ state.json             # 채널↔세션 바인딩 (재시작 후 자동 복구)
└─ audit/audit.jsonl      # 감사 로그
```
설정은 **전역 → 서버 → 프로젝트** 순으로 덮어써집니다.

---

## 문제 해결

- **봇이 메시지에 반응하지 않아요** → Developer Portal에서 **Message Content Intent**가 켜져 있는지 확인.
- **슬래시 명령이 안 보여요** → 초대 시 `applications.commands` 스코프를 포함했는지 확인(등록에 몇 분 걸릴 수 있음).
- **권한 오류로 채널 생성 실패** → 봇에게 `Manage Channels` 권한이 있는지 확인.
- **사용량 패널이 안 떠요** → Claude Pro/Max **구독 로그인**(`~/.claude`) 상태여야 합니다. API 키만 쓰면 이 패널은 숨겨집니다(정상).

---

## 개발

```bash
npm install
npm run dev         # tsx watch (개발 모드)
npm run typecheck   # 타입 검사
npm run test        # 테스트 (vitest)
```

## 라이선스

MIT
