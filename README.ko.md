# discord-agent-bridge

🌐 **한국어** | [English](README.md)

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, and more — per channel. Role-based access, multi-server, extensible.

**Discord 채널 하나에 Claude Code(또는 Codex)를 붙여 쓰는 셀프호스팅 봇입니다.** 봇은 내 PC에서 돌고, npm에 배포되어 있어 `npm install -g` 한 번과 명령 세 줄이면 자동 실행까지 끝납니다.

---

## Why this?

- 🏠 **완전 셀프호스팅.** 봇이 내 PC에서 돕니다. 코드도, 세션도, CLI 토큰도 밖으로 안 나갑니다.
- 📱 **책상 앞에 없어도 됩니다.** 지하철에서 폰으로 Discord에 지시만 던져 두세요. 스트리밍 응답, 툴 실행 로그, 권한 승인 버튼이 채널에 그대로 뜹니다.
- 🗂️ **채널 하나 = 프로젝트 하나 = 세션 하나.** 채널마다 작업 폴더 · 백엔드 · 모델 · 권한 모드가 따로 붙습니다.
- 👥 **팀 관전 친화적.** 같은 채널을 보는 사람은 세션 진행을 그대로 지켜봅니다. 3단계 역할(admin / execute / read-only)로 실제 실행 권한만 통제합니다.
- 🔀 **Claude ⇄ Codex 즉시 전환.** `/mode` 한 방으로 백엔드를 바꿉니다.
- ⚙️ **터미널과 동등한 기능.** 프로젝트의 `.claude/`, `.codex/` 설정을 그대로 읽어서 서브에이전트 · 스킬 · 훅 · MCP · 플러그인 명령까지 CLI와 똑같이 동작합니다.

---

## 준비물

- **Node.js 20 이상**
- 쓰려는 백엔드에 맞춰 CLI가 **설치 + 로그인** 상태:
  - **Claude 모드** → [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` 로그인 또는 `ANTHROPIC_API_KEY`)
  - **Codex 모드** → `codex` CLI, 로그인까지
- **Discord 봇 토큰** (아래 1단계에서 발급)

---

## 1단계 — Discord 봇 만들기

봇을 하나 직접 만들어야 합니다. 5분이면 됩니다.

1. **[Discord Developer Portal](https://discord.com/developers/applications)** 접속 → 우측 상단 **New Application** → 이름 입력(예: `my-agent-bot`) → **Create**.
2. 왼쪽 메뉴 **Bot** 탭 → **Reset Token** → 나오는 **토큰을 복사**해서 안전한 곳에 보관하세요.
   - ⚠️ 이 토큰은 비밀번호나 다름없습니다. 노출되면 즉시 **Reset Token**으로 재발급하세요.
3. 같은 **Bot** 탭 아래 **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **필수** (봇이 메시지 내용을 읽어야 합니다)
   - ✅ **SERVER MEMBERS INTENT** — 권장 (역할 확인에 사용)
   - 켜고 **Save Changes**.
4. 왼쪽 **OAuth2** 탭 → **Client ID(Application ID)** 복사.
5. **초대 링크 만들기** — OAuth2 → **URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - 생성된 URL을 브라우저에 붙여넣어 **내 서버에 초대**하세요.

---

## 2단계 — 설치 & 실행

명령 세 줄이면 설치부터 재부팅 자동 실행까지 끝납니다. `service install` 이 현재 OS에 맞는 자동 실행을 알아서 등록합니다 — **macOS는 launchd, Linux는 systemd, Windows는 작업 스케줄러**.

```bash
npm install -g discord-agent-bridge      # 설치
discord-agent-bridge --setup             # 최초 1회 (토큰 등 입력)
discord-agent-bridge service install     # 자동 실행 등록 + 즉시 시작
```

관리 명령:

```bash
discord-agent-bridge service status      # 등록/실행 상태
discord-agent-bridge service restart     # 재시작
discord-agent-bridge service uninstall   # 등록 해제
```

업그레이드:

```bash
npm install -g discord-agent-bridge@latest
discord-agent-bridge service restart
```

> ⚠️ **Windows 참고**: 작업 스케줄러 로그온 트리거로 등록되므로 **로그인 시 자동 시작**됩니다(관리자 권한 불필요). 크래시 시 자동 재시작은 보장하지 않습니다(macOS · Linux는 보장).

---

## 3단계 — Discord에서 사용하기

봇이 서버에 들어오면 **컨트롤 채널(`#session-generator`), 세션 카테고리, 알림 채널(`#agent-status`)이 자동으로 생성**됩니다(봇에 채널 관리 권한이 있는 한). 이후 흐름: **`/config` → `/agent start`**.

1. **(자동)** 봇 시작 또는 서버 초대 시점에 위 채널 구조가 생깁니다. 관리자가 **`/setup`** 으로 수동 재생성해도 됩니다(기존 채널은 재사용).
2. **`/config`** (관리자) — 역할 티어와 기본값을 지정합니다. 서버 관리자(Administrator)는 역할 설정 없이도 항상 사용할 수 있습니다.
3. `#session-generator` 에서 **`/agent start`**. **마법사**가 순서대로 안내합니다: **작업 폴더 → 백엔드(Claude / Codex) → 모델 → 추론 수준 → 권한 모드**. 각 단계는 **"다음" 버튼**으로 넘어갑니다. 폴더 브라우저는 상위/다른 볼륨 이동, 새 폴더 생성, 이전 세션 재개까지 지원합니다. 확인하면 **전용 세션 채널(`proj-<폴더>`)** 이 새로 생기고 그 채널에 바인딩됩니다.
4. 만들어진 세션 채널에서 **일반 메시지로 그냥 대화**하면 됩니다. Claude 모드는 스트리밍 응답, 툴 실행 스레드, 권한 승인 버튼이 뜹니다.

### 주요 명령어

| 명령어 | 설명 |
|---|---|
| `/setup` | (관리자) 컨트롤 채널 + 세션 카테고리 생성 (기존이 있으면 재사용) |
| `/agent start` | 새 세션 시작 — 마법사 확인 시 전용 세션 채널 생성 |
| `/agent resume` | 이전 세션 이어하기 |
| `/agent close` | 세션 종료 + 세션 채널 삭제 |
| `/agent stats` | 활성 세션 · 세션 통계 · Claude 사용량 (본인에게만 표시) |
| `/mode <claude\|codex>` | 백엔드 전환 (⚠️ 새 대화로 시작 — 이전 맥락 미승계) |
| `/mode perm <모드\|프로필>` | 권한 모드/프로필 전환 (세션 유지) |
| `/stop` | 현재 세션 즉시 중단 (킬 스위치) |
| `/stop-all` | (관리자) 모든 세션 중단 |
| `/config` | (관리자) 역할 티어 + 기본값(백엔드 · 모델 · 권한 모드 · 언어 · Codex 경로) 설정 |

### 권한 모드

- `default` — 툴을 실행할 때마다 **Allow/Deny 버튼**으로 물어봅니다 (가장 안전)
- `acceptEdits` — 파일 수정은 자동 수락
- `plan` — 계획만 세우고 실행은 보류
- `bypassPermissions` — 전부 자동 (신뢰하는 프로젝트에서만)

Codex는 자신의 승인/샌드박스 모드로 매핑합니다.

### 이벤트 알림 (`#agent-status`)

여러 세션의 **작업 완료와 에러**를 `#agent-status` 채널 한 곳에 요약해 알려줍니다. `/config` → **🔔 알림 설정** 에서 켜기/끄기와 대상 채널을 바꿀 수 있습니다.

### 문서 공유

세션 채널에서 `/doc path:docs/foo.md` 를 실행하면 작업 디렉터리의 마크다운 파일이 `📄` 스레드에 게시됩니다 — 원본 `.md` 첨부는 항상, 본문은 설정에 따라(렌더링이 켜져 있으면 표/mermaid는 이미지). 에이전트에게 "공유해줘"라고 요청하는 방법도 있습니다(`share_document` 도구). 자세한 사용법과 설정: [docs/document-share-usage.md](docs/document-share-usage.md)

---

License: MIT
