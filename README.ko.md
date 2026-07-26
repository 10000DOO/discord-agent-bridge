# discord-agent-bridge

🌐 **한국어** | [English](README.md)

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, Grok, and more — per channel. Role-based access, multi-server, extensible.

**Discord 채널 하나에 Claude Code(또는 Codex / Grok)를 붙여 쓰는 셀프호스팅 봇입니다.**

**제품 경로는 Swift(`dab`)** 입니다. Claude Code 공식 Agent SDK가 Node 전용이라 **얇은 Node(TypeScript) 사이드카**는 그대로 둡니다. 예전 npm TypeScript 메인 프로세스는 **레거시 / 참고용**이며 권장 설치 경로가 아닙니다.

---

## Why this?

- 🏠 **완전 셀프호스팅.** 봇이 내 PC에서 돕니다. 코드도, 세션도, CLI 토큰도 밖으로 안 나갑니다.
- 📱 **책상 앞에 없어도 됩니다.** 지하철에서 폰으로 Discord에 지시만 던져 두세요. 스트리밍 응답, 툴 실행 로그, 권한 승인 버튼이 채널에 그대로 뜹니다.
- 🗂️ **채널 하나 = 프로젝트 하나 = 세션 하나.** 채널마다 작업 폴더 · 백엔드 · 모델 · 권한 모드가 따로 붙습니다.
- 👥 **팀 관전 친화적.** 같은 채널을 보는 사람은 세션 진행을 그대로 지켜봅니다. 3단계 역할(admin / execute / read-only)로 실제 실행 권한만 통제합니다.
- 🔀 **Claude ⇄ Codex ⇄ Grok 즉시 전환.** 세션 바인딩 후 `/mode` 등으로 백엔드를 바꿉니다.
- ⚙️ **터미널과 동등한 기능.** 프로젝트의 `.claude/`, `.codex/` 설정을 그대로 읽어서 서브에이전트 · 스킬 · 훅 · MCP · 플러그인 명령까지 CLI와 같이 동작합니다(Claude는 사이드카 경유).

---

## 준비물

| 항목 | 설명 |
|---|---|
| **macOS 13+** | Swift 제품 1차 타깃 |
| **Swift 6.1+** | Xcode 또는 Command Line Tools |
| **Node.js 20+** | **Claude 전용** — 사이드카 기동에 필요. Codex/Grok에는 불필요 |
| 백엔드 CLI 설치·로그인 | **Claude Code** (`claude` 로그인 또는 `ANTHROPIC_API_KEY`); **Codex** CLI; 필요 시 **Grok** CLI |
| **Discord 봇 토큰** | 아래 1단계 |

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

## 2단계 — 설치 & 실행 (Swift)

이 저장소를 클론하세요(Claude 사이드카가 체크아웃 기준 상대 경로를 씁니다). 그다음 바이너리를 사용자 LaunchAgent로 설치합니다:

```bash
git clone https://github.com/<you>/discord-agent-bridge.git
cd discord-agent-bridge
# Claude 사이드카용
npm install

bash swift/scripts/install.sh
# 최초 설치 시 swift/deploy/env.example → ~/.dab/env (0600) 복사
# 토큰 입력 후, 이미 load 했다면 launchd 재로드
```

시크릿 편집(토큰은 여기만 — plist에 넣지 않음):

```bash
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

env 수정 후 재로드:

```bash
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist
launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist
```

### 일회 실행 (launchd 없음)

**저장소 루트**에서 (사이드카가 `src/sidecar` / `node_modules`를 찾을 수 있도록):

```bash
export DISCORD_BOT_TOKEN=your_bot_token
# 선택: DAB_CWD, DAB_PERM_MODE, DAB_TURN_TIMEOUT_SEC, DAB_DEV_GUILD_ID
swift run --package-path swift dab
```

제거(`~/.dab/env`·로그는 유지):

```bash
bash swift/scripts/uninstall.sh
```

### 경로 (Swift)

| 경로 | 역할 |
|---|---|
| `~/.dab/bin/dab` | 릴리스 바이너리 (install.sh) |
| `~/.dab/env` | 시크릿·환경변수 (0600) — 토큰, 선택 `DAB_*` |
| `~/.dab/run.sh` | 런처: PATH + 저장소 루트 `cd` + `dab` 실행 |
| `~/Library/LaunchAgents/com.discord-agent-bridge.plist` | LaunchAgent (HOME만; 토큰 없음) |
| `~/.dab/logs/` | stdout / stderr |
| `~/.discord-agent-bridge/` | **설정·상태** (레거시 TS와 동일 레이아웃; `DAB_HOME`으로 변경 가능) |

설정 디렉터리:

| 파일 | 역할 |
|---|---|
| `config.json` | 전역 설정 (역할 인가, 기본값 등) |
| `servers/<guildId>.json` | 서버별 오버라이드 |
| `swift-state.json` | Swift 세션 바인딩 (버전 관리) |

상세: [`swift/README.md`](swift/README.md) · 설계: [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md).

### 하이브리드 Claude 사이드카 (중요)

```
Swift dab  ──stdio JSON-RPC──►  Node Claude 사이드카  ──►  Claude Agent SDK
Codex / Grok                 ──stdio (네이티브 클라)──►  각 CLI
```

- **Swift는 항상** Node 사이드카 프로세스를 통해 Claude와 통신합니다(자동 스폰).
- Claude 모드에는 체크아웃에 **Node + `npm install`** 이 필요합니다. Codex/Grok은 Node 불필요.
- 스폰 명령 오버라이드: `DAB_CLAUDE_SIDECAR_CMD`.
- 프로토콜: [`CLAUDE_SIDECAR_PROTOCOL.md`](CLAUDE_SIDECAR_PROTOCOL.md).

> **`DAB_CLAUDE_SIDECAR=1`** 은 **레거시 TypeScript 메인** 전용 스위치입니다(npm 봇 안에서 사이드카 opt-in). Swift 제품은 이 변수를 쓰지 않으며, Claude에는 항상 사이드카를 씁니다.

---

## 3단계 — Discord에서 사용하기

기본 흐름: **`/setup` → `/config` → `/agent start`**, 이후 세션 채널에서 일반 메시지.

1. **`/setup`** (관리자) — 컨트롤 채널 · 세션 카테고리 · 상태 채널 (기존 재사용).
2. **`/config`** (관리자) — 역할 티어 + 기본값(mode/model/effort/perm, dmPolicy) + 알림 + **이미지/chromium 렌더** 서브패널(켜기 + Chromium 설치).
3. **`/agent start`** — 마법사: **폴더 → 백엔드 → 모델 → 추론 → 권한**. 폴더 브라우저는 이동/생성/네이티브 선택 지원. 확인 시 채널 바인딩(전용 A4D 세션 채널 생성은 Swift 경로 잔여).
4. 바인딩된 채널에서 **일반 메시지**로 대화. 접두사 단축키: `!claude` / `!codex` / `!grok` / `!custom`.

### 주요 명령어 (Swift)

| 명령어 | 설명 |
|---|---|
| `/setup` | (관리자) 컨트롤 + 세션 카테고리 + 상태 채널 프로비저닝 |
| `/agent start` | 마법사: 백엔드·모델·추론·권한(+폴더) 바인딩 |
| `/agent resume` | 이전 세션 재개 (바인딩 레이어) |
| `/agent close` | 세션 종료 (백엔드 stop) |
| `/agent stats` | 세션 통계 + Claude/Grok 사용량(가능 시) |
| `/mode` · `/model` · `/effort` · `/mode perm` | 라이브 바인딩 갱신 |
| `/clear` | 동일 설정으로 새 대화 |
| `/stop` · `/stop-all` | 현재/전체 중단 (stop-all은 관리자) |
| `/config` | (관리자) 역할 티어 + 핵심 기본값 |
| `/doc` | 작업 공간 마크다운을 스레드로 공유 |
| `/update` | (관리자) npm 레지스트리 새 버전 확인 |

권한 모드: `default` · `acceptEdits` · `plan` · `bypassPermissions`(및 카탈로그된 백엔드별 프로필). 스모크 기본이 `bypassPermissions`일 수 있음 — Allow/Deny UI 사용 시 `default` 권장.

> **패리티 안내:** Swift가 제품 경로이며 **~99% 패리티**. 잔여: W13-b 보류 · optional polish. [호환 매트릭스](#swift-vs-typescript-호환)와 [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md) §0을 보세요.

---

## npm TypeScript → Swift `dab` 마이그레이션

이미 `npm install -g discord-agent-bridge` / `discord-agent-bridge service install` 로 돌리고 있다면:

1. **레거시 서비스 중지** (같은 토큰으로 봇 둘 띄우지 않기):
   ```bash
   discord-agent-bridge service uninstall   # 또는 먼저 stop/status
   ```
2. **설정 유지** — `~/.discord-agent-bridge/` (또는 `DAB_HOME`). Swift는 **같은 디렉터리와 `config.json` / `servers/*.json` 레이아웃**을 씁니다.
3. **세션 상태는 별도:** TS는 `state.json`, Swift는 `swift-state.json`(버전 관리). 바인딩은 1:1 자동 이관되지 않으므로 전환 후 `/agent start`(또는 Swift resume 경로)로 다시 잡습니다.
4. **Swift 설치** — Claude용 Node 의존성이 있는 **전체 체크아웃**에서 `bash swift/scripts/install.sh`.
5. **환경 변수 대응**

   | 항목 | 레거시 TS | Swift |
   |---|---|---|
   | 토큰 | 마법사 / 서비스 env | `~/.dab/env` → `DISCORD_BOT_TOKEN` |
   | 설정 루트 | `DAB_HOME` 또는 `~/.discord-agent-bridge` | **동일** |
   | 자동 시작 | `discord-agent-bridge service install` | `swift/scripts/install.sh` · `install-linux.sh` · `install-windows.ps1` |
   | Claude 프로세스 | in-process **또는** `DAB_CLAUDE_SIDECAR=1` | **항상 사이드카** |
   | 사이드카 스폰 오버라이드 | (사이드카 경로) | `DAB_CLAUDE_SIDECAR_CMD` |
   | 작업 디렉터리 기본 | config / 마법사 | `DAB_CWD` env + 마법사 폴더 스텝 |
   | 바이너리·로그(배포) | 서비스 홈 하위 | `~/.dab/` |

6. **메인 프로세스 둘을 한 봇 토큰에 동시에 돌리지 마세요.** Swift가 띄우는 사이드카만 있는 구성은 정상입니다.

---

## Swift vs TypeScript 호환

의도된 상태: **Swift-first 제품**, TS 트리는 참고 + Claude 사이드카용. **패리티 ~99%** (잔여: W13-b 보류 · optional polish).

| 영역 | Swift (`dab`) | 레거시 TS 메인 |
|---|---|---|
| Discord 게이트웨이 + 슬래시 | ✅ DiscordBM | ✅ discord.js |
| Claude 턴 | ✅ **Node 사이드카**(항상) | ✅ in-process 기본; 사이드카 opt-in `DAB_CLAUDE_SIDECAR=1` |
| Codex / Grok | ✅ 네이티브 stdio 클라 | ✅ |
| Custom 백엔드 + shell env | ✅ | ✅ |
| 세션 바인드 / 재시작 재연결 | ✅ `SessionStore` + lazy resume | ✅ 오케스트레이터 |
| 역할 인가 / 감사 / 경로 confinement | ✅ (allowlist·기본 perm 전환은 보류) | ✅ |
| 3계층 config | ✅ global → server → binding | ✅ |
| `/agent start` 폴더 마법사 | ✅ 폴더 클러스터; **잔여:** resume UI, A4D 채널 생성, preset, reconfigure | ✅ 풀 |
| 라이브 슬래시 model/effort/mode/clear/stop | ✅ 바인딩 + Claude 라이브 `setModel`/`setEffort` RPC + displayName 재해석 | ✅ |
| 사용량 / HUD | ✅ stats + Claude/Grok usage + tools/subagent HUD; **잔여:** 라이브 스트림 임베드 | ✅ 더 풍부한 패널 |
| 도구 스레드 / diff / 상태 임베드 / notifier | ✅ Claude/Codex/Grok mid-turn tool; **잔여:** pin 임베드 | ✅ |
| `/config` 패널 | ✅ 역할·mode/model/effort/perm·dm·알림·locale·render(S3) | ✅ 더 넓은 UI |
| `/setup` · `/doc` · Always-Allow | ✅ | ✅ |
| Auto-update | ✅ 레지스트리 체크 + Yes/No + **install.sh·launchctl 재시작** | ✅ npm 재설치 경로 |
| Chromium 표/mermaid 렌더 | ✅ headless Chrome CLI (시스템 Chrome 또는 프로비저닝) | ✅ puppeteer |
| Host file Discord 첨부 | partial / 잔여 | ✅ (사이드카 경로) |
| Linux/Windows 서비스 | ✅ launchd / systemd / schtasks 스크립트 | ✅ launchd / systemd / schtasks |
| npm global 설치 | ❌ (체크아웃 + 빌드) | ✅ |

**잔여 큐(미완):** W16 폴리시, W13-b allowlist — [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md) §0.

---

## 레거시 TypeScript 런타임 (참고용)

비교·Claude 사이드카 패키지용으로 여전히 동작합니다:

```bash
npm install -g discord-agent-bridge
discord-agent-bridge --setup
discord-agent-bridge service install
```

**TS 메인** 안에서 Claude 사이드카 opt-in:

```bash
DAB_CLAUDE_SIDECAR=1 npm run dev   # 체크아웃에서
```

신규 설치는 **Swift**([2단계](#2단계--설치--실행-swift))를 권장합니다. 패리티가 닫히면 TS 메인은 제거될 수 있습니다.

---

## 개발

```bash
bash verify.sh
```

게이트(필수): `swift/` 빌드 + 테스트. 백엔드 스모크(`sidecar` / `codex` / `grok`)는 best-effort이며 CLI 부재 시 깨끗이 스킵합니다.

⚠️ 패키지 `.build` 인덱서 락으로 `swift test`가 hang 하면 격리 scratch 경로를 쓰세요:

```bash
swift test --package-path swift --scratch-path /tmp/dab-ci
```

포팅 추적: [`SWIFT_PORT_PLAN.md`](SWIFT_PORT_PLAN.md). 패키지 노트: [`swift/README.md`](swift/README.md).

---

License: MIT
