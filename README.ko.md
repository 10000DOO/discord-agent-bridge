# discord-agent-bridge

🌐 **한국어** | [English](README.md)

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, Grok, and more — per channel. Role-based access, multi-server, extensible.

**Discord 채널 하나에 Claude Code · Codex · Grok(또는 custom 백엔드)을 붙여 쓰는 셀프호스팅 봇입니다.**

제품은 **Swift** 바이너리(`dab`)입니다. Claude Code 공식 Agent SDK가 Node 전용이라 **얇은 Node 사이드카**만 사용합니다. Codex / Grok은 각 CLI와 stdio로 직접 통신하며 Node가 필요 없습니다.

---

## 왜 쓰나요?

- 🏠 **완전 셀프호스팅.** 봇이 내 PC에서 돕니다. 코드·세션·CLI 토큰이 밖으로 나가지 않습니다.
- 📱 **책상 앞에 없어도 됩니다.** 폰 Discord로 작업을 던지면 스트리밍 응답, 툴 로그, 권한 승인 버튼이 채널에 뜹니다.
- 🗂️ **채널 하나 = 프로젝트 하나 = 세션 하나.** 채널마다 작업 폴더 · 백엔드 · 모델 · 추론 강도 · 권한 모드가 따로 붙습니다.
- 👥 **팀 관전 친화적.** 같은 채널을 보는 사람은 세션 진행을 그대로 봅니다. 3단계 역할(admin / execute / read-only)로 실행 권한만 통제합니다.
- 🔀 **Claude ⇄ Codex ⇄ Grok (및 custom) 즉시 전환.** 세션 바인딩 후 `/dab-mode` 등으로 백엔드를 바꿉니다.
- ⚙️ **터미널과 동등한 기능.** 프로젝트 `.claude/` · `.codex/` 설정을 그대로 써서 서브에이전트 · 스킬 · 훅 · MCP · 플러그인 명령이 CLI와 같이 동작합니다.
- 💾 **세션 프리셋.** 백엔드/모델/추론/권한 조합을 길드 단위로 저장해 두고, 다음엔 폴더만 고르면 시작할 수 있습니다.
- 🖼 **풍부한 응답.** GFM 표·Mermaid를 PNG로, 툴 실행은 작업 스레드+diff, 사용량 패널로 Claude / Codex / Grok 한도를 보여 줍니다.

---

## 준비물

| 항목 | 설명 |
|---|---|
| **macOS 13+** (1차), 또는 Linux / Windows + Swift | 제품 바이너리는 SwiftPM `dab` |
| **Swift 6.1+** | Xcode 또는 Command Line Tools (Windows: Swift 툴체인) |
| **Node.js 20+** | **Claude 전용** — 사이드카 기동용. Codex/Grok에는 불필요 |
| 백엔드 CLI 설치·로그인 | **Claude Code** (`claude` 로그인 또는 `ANTHROPIC_API_KEY`); **Codex** CLI; 필요 시 **Grok** CLI |
| **Discord 봇 토큰** | 아래 1단계 |

---

## 1단계 — Discord 봇 만들기

약 5분이면 됩니다.

1. **[Discord Developer Portal](https://discord.com/developers/applications)** → **New Application** → 이름 입력(예: `my-agent-bot`) → **Create**.
2. **Bot** 탭 → **Reset Token** → 토큰을 복사해 안전한 곳에 보관.
   - ⚠️ 토큰은 비밀번호입니다. 노출되면 즉시 **Reset Token**.
3. 같은 **Bot** 탭 **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **필수**
   - ✅ **SERVER MEMBERS INTENT** — 권장 (역할 확인)
   - **Save Changes**.
4. **OAuth2** → **Client ID (Application ID)** 복사.
5. **OAuth2 → URL Generator**:
   - **Scopes**: `bot`, `applications.commands`
   - **Bot Permissions**: `Manage Channels`, `Send Messages`, `Embed Links`, `Attach Files`, `Read Message History`, `Create Public Threads`, `Send Messages in Threads`, `Manage Threads`, `Add Reactions`
   - 생성된 URL로 서버에 초대.

---

## 2단계 — 설치 & 실행

### macOS (권장 — Homebrew)

```bash
brew tap 10000DOO/discord-agent-bridge
brew install 10000DOO/discord-agent-bridge/dab
```

소스에서 `dab`을 빌드하고 Claude 사이드카까지 같이 npm install 해줍니다 — 따로 `npm install`을 돌릴 필요 없습니다. Node.js 20+ / Swift 6.1+ 가 이미 `PATH`에 있어야 합니다(위 준비물 참고) — Formula는 확인만 하고 설치·업그레이드는 해주지 않습니다.

시크릿(`DISCORD_BOT_TOKEN` 등)은 아래 수동 설치와 동일하게 `~/.dab/env`(0600 권한) 파일에 넣습니다:

```bash
mkdir -p ~/.dab && touch ~/.dab/env && chmod 600 ~/.dab/env
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

한 번 실행(포그라운드):

```bash
dab
```

또는 꺼져도(크래시·재부팅) 자동으로 다시 살아나는 백그라운드 서비스로 실행(`brew services`, launchd 기반):

```bash
brew services start dab      # 시작
brew services list           # 상태 확인
brew services restart dab    # ~/.dab/env 수정 후 재시작
brew services stop dab       # 중지
```

로그: `$(brew --prefix)/var/log/dab.log` / `dab.error.log`

업데이트:

```bash
brew update
brew upgrade 10000DOO/discord-agent-bridge/dab
brew services restart dab   # 서비스로 켜둔 경우에만 필요 — brew upgrade만으로는 재시작 안 됨
```

디스코드 안의 `/dab-update` 명령(아래 Features → Auto-update 참고)은 Homebrew 설치에서는 **동작하지 않습니다** — `swift/scripts/install.sh`가 있는 저장소 체크아웃을 찾는 방식이라, Homebrew 설치엔 그게 없기 때문입니다. 이 설치 방식에서는 항상 `brew upgrade`를 쓰세요.

> ⚠️ **같은 봇 토큰으로 두 개를 동시에 켜지 마세요.** 포그라운드 실행, `brew services`, 아래 수동(소스 빌드) 설치 전부 같은 `DISCORD_BOT_TOKEN`을 읽습니다. 같은 토큰으로 두 번째 인스턴스를 켜면 같은 봇 계정에 게이트웨이 연결이 하나 더 생깁니다 — 에러 없이 그냥 둘 다 떠 있으면서 응답이 중복되거나 꼬입니다. 봇 토큰 하나당 설치 방식은 하나만 쓰세요.

### macOS (수동 — 소스 빌드)

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge

# Claude 사이드카용 (Codex/Grok만 쓰면 생략 가능)
npm install

bash swift/scripts/install.sh
# 최초 설치 시 swift/deploy/env.example → ~/.dab/env (0600) 복사
```

시크릿 편집(토큰은 **여기만** — plist에 넣지 않음):

```bash
$EDITOR ~/.dab/env
# DISCORD_BOT_TOKEN=...
```

env 수정 후 재로드:

```bash
launchctl unload ~/Library/LaunchAgents/com.discord-agent-bridge.plist
launchctl load -w ~/Library/LaunchAgents/com.discord-agent-bridge.plist
```

설치 후 서비스 헬퍼:

```bash
dab service status    # 또는: ~/.dab/bin/dab service status
dab service restart
```

업데이트: 디스코드에서 `/dab-update`를 치면 릴리스 레지스트리를 확인해서 자동으로 다시 빌드하고 재시작합니다(아래 Features → Auto-update 참고). 수동으로 하려면:

```bash
cd discord-agent-bridge   # 저장소 루트
git pull
bash swift/scripts/install.sh   # 다시 빌드 + LaunchAgent 재로드
```

제거(`~/.dab/env`·로그는 유지):

```bash
bash swift/scripts/uninstall.sh
```

### Linux (systemd --user)

```bash
bash swift/scripts/install-linux.sh
# ~/.dab/env 편집 후:
systemctl --user restart discord-agent-bridge
systemctl --user status discord-agent-bridge
```

업데이트: `git pull && bash swift/scripts/install-linux.sh` (또는 디스코드에서 `/dab-update`).

제거: `bash swift/scripts/uninstall-linux.sh`

### Windows (작업 스케줄러 / 로그온 시)

```powershell
powershell -ExecutionPolicy Bypass -File swift/scripts/install-windows.ps1
# %USERPROFILE%\.dab\env 편집
schtasks /Run /TN discord-agent-bridge
```

업데이트: `git pull` 후 `install-windows.ps1` 다시 실행 (또는 디스코드에서 `/dab-update`).

제거: `install-windows.ps1 -Uninstall`

### 일회 실행 (서비스 없음)

**저장소 루트**에서 (Claude 사이드카가 체크아웃 기준 경로를 씁니다):

```bash
export DISCORD_BOT_TOKEN=your_bot_token
# 선택: DAB_CWD, DAB_PERM_MODE, DAB_TURN_TIMEOUT_SEC, DAB_DEV_GUILD_ID
swift run --package-path swift dab
```

성공 시:

```text
ready: username=<bot> id=<snowflake> app=<application id>
```

---

## 3단계 — Discord에서 사용하기

기본 흐름: **`/dab-setup` → `/dab-config` → `/dab-agent start`**, 이후 세션 채널에서 일반 메시지.

1. **`/dab-setup`** (관리자) — 컨트롤 채널 · 세션 카테고리 · 상태 채널 (기존 재사용).
2. **`/dab-config`** (관리자) — 역할 티어, 기본값(백엔드/모델/추론/권한), 로케일, 알림, 이미지/Chromium 렌더, 유저별 접근 예외.
3. **`/dab-agent start`** — 마법사: **폴더 → [프리셋 있으면] → 백엔드 → 모델 → 추론 → 권한**. `/dab-setup` 후 세션 카테고리 아래 A4D `<임의ID>-<folder>-proj` 채널을 만들고 바인딩할 수 있습니다.
4. 바인딩된 채널에서 **일반 메시지**로 대화 — 접두사 없는 평문은 그 채널에 붙은 백엔드로 갑니다. 접두사를 붙이면 그 한 턴만 지정한 백엔드로 보냅니다:

```text
!claude 현재 디렉터리에 어떤 파일이 있어?
!codex 마지막 커밋 요약해 줘
!grok 이 에러 설명해 줘
!custom <프롬프트>          # Claude 경로 + 설정된 셸 환경변수 오버레이
```

접두사는 **이미 바인딩된 채널에서만** 동작합니다 — 바인딩 안 된 채널에서 접두사를 쳐서 백엔드를 띄우는 건 불가능하고, DM은 아예 무시합니다. 프롬프트를 비운 접두사는 사용법만 출력합니다.

### 슬래시 명령

| 명령 | 권한 | 설명 |
|---|---|---|
| `/dab-setup` | 관리자 | 컨트롤 + 세션 카테고리 + 상태 채널 프로비저닝 |
| `/dab-config` | 관리자 | 역할·기본값·로케일·알림·렌더·접근 패널 |
| `/dab-agent start` | execute+ | 마법사: 폴더/백엔드/모델/추론/권한 바인딩 (+ 프리셋) |
| `/dab-agent resume` | execute+ | 저장된 세션 재바인딩, 상태 표시, soft reconnect |
| `/dab-agent close` | execute+ | 백엔드 중지 + 이 채널 언바인드 |
| `/dab-agent stats` | execute+ | 활성 바인딩 + Claude / Codex / Grok 사용량(가능 시) |
| `/dab-mode backend` | execute+ | 백엔드 전환 (새 컨텍스트) |
| `/dab-mode perm` | execute+ | 권한 모드 전환 (세션 유지) |
| `/dab-model` | execute+ | 모델 전환 (프로바이더 카탈로그 자동완성) |
| `/dab-effort` | execute+ | 추론 강도 전환 (자동완성) |
| `/dab-clear` | execute+ | 동일 폴더/설정으로 새 대화 |
| `/dab-stop` | execute+ | 이 채널 세션 hard-stop |
| `/dab-stop-all` | 관리자 | 모든 바인딩 세션 hard-stop |
| `/dab-doc path:` | execute+ | 작업 공간 마크다운을 문서 스레드로 공유 |
| `/dab-orchestration` | execute+ | 이 세션 채널을 오케스트레이션 리드로 전환 (Claude 전용) — 아래 참고 |
| `/dab-redmine` | execute+ | 레드마인 알림 연동 모달 (URL / API 키 / 프로젝트) |
| `/dab-redmine-issue-select` | execute+ | 신규·진행 상태 레드마인 이슈를 드롭다운에서 골라 세션 시작 |
| `/dab-update` | 관리자 | 새 릴리스 확인 후 설치·재시작 제안 |

모든 명령은 `dab-` 접두사로 등록되므로 다른 봇의 `/agent` · `/stop` · `/config`와 충돌하지 않습니다. `/dab-setup` · `/dab-config` · `/dab-stop-all` · `/dab-update`는 관리자 티어(또는 디스코드 Administrator 권한)가 필요하고, 나머지는 execute 이상이면 됩니다. `/dab-setup`에는 최초 1회 예외가 있습니다 — 관리자가 아직 하나도 설정되지 않은 서버에서는 먼저 실행한 사람이 관리자를 가져갑니다.

**이 채널의 세션**을 대상으로 하는 명령(`/dab-model` · `/dab-effort` · `/dab-mode` · `/dab-clear` · `/dab-stop` · `/dab-orchestration`)은 채널이 바인딩되지 않았으면 "세션 없음"으로 응답합니다.

### 권한 모드

`default` · `acceptEdits` · `plan` · `bypassPermissions` (카탈로그된 백엔드별 프로필 포함).

툴 승인이 필요하면 **Allow / Always-Allow / Deny** 버튼이 채널에 올라갑니다. 실사용은 `default` 권장. `bypassPermissions`는 UI를 건너뜁니다(신뢰된 머신 전용). 턴 중 **Interrupt(stop)** 버튼은 바인딩을 풀지 않고 현재 턴만 중단합니다.

---

## 기능

### 세션 마법사 & 프리셋

- 폴더 브라우저: 이동 · 폴더 생성 · favorites 루트(`config.favorites`) · 가능한 경우 네이티브 선택.
- **프리셋**(길드 단위): 일반 시작 후 백엔드/모델/추론/권한을 이름으로 저장. 다음 `/dab-agent start`에서는 프리셋 선택 → 폴더만 고르면 됩니다.
- **재개(resume)** · **재구성(reconfigure)** 경로 지원.
- 봇 재시작 시 `swift-state.json`에서 바인딩 복구 (예전 `state.json`이 있으면 1회 임포트 가능).

### 라이브 세션 UX

- 스트리밍 상태 임베드 (텍스트 / 툴 진행).
- 툴 활동 → Discord 작업 스레드 + 포맷된 출력·**diff**.
- 상태 채널 알림(주요 이벤트, `/dab-config`에서 설정).
- `/dab-agent stats`의 사용량 임베드 (Claude OAuth, Codex rate limit, Grok weekly).
- 턴이 수 분간 조용하면 idle watchdog 안내.
- 에이전트 → 채널 파일 첨부/문서 공유(`host.file.attach` / share), 경로 confinement.

### 이미지 렌더 (표 · Mermaid)

GFM 표와 fenced `mermaid` 블록을 PNG 첨부로 올릴 수 있습니다. 조건:

1. 렌더 켜짐 (`/dab-config` → 🖼 렌더, 기본 on), 그리고  
2. 브라우저 사용 가능: 시스템 Chrome/Edge/Chromium, 또는 `~/.dab/chromium`에 프로비저닝 ( `/dab-config` 또는 `/dab-setup` 직후 Install Chromium; 다운로드 헬퍼에 Node 필요).

구현: 로컬 HTML을 **headless Chrome CLI**로 스크린샷 (프로세스 내 브라우저 런타임 없음). 실패 시 raw 마크다운으로 폴백. 타임아웃·크기·동시성 상한 있음.

환경 변수: `DAB_RENDER=0|1`, `DAB_MERMAID_JS`, `DAB_CHROMIUM_CACHE`, `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH`.

### 오케스트레이션 모드 (Claude 전용)

`/dab-orchestration`은 현재 세션 채널을 **리드** 채널로 승격시켜서, 자기 밑에 모듈 채널을 만들어 일을 나눠줄 수 있게 합니다.

실행하면 드롭다운 4개(리드의 모델·추론 강도, 리드가 만들 모듈의 모델·추론 강도)와 **[시작] / [취소]** 카드가 뜹니다. [시작]을 누르기 전까지는 아무것도 건드리지 않습니다. [시작] 시:

1. 프로젝트의 기존 `.claude/`를 zip으로 백업한 뒤, 오케스트레이션 역할 규약과 스킬을 그 안에 설치합니다 (전역이나 프로젝트에 같은 이름의 스킬이 이미 있으면 건드리지 않고 보고만 합니다).
2. 이 리드용 디스코드 카테고리를 만들거나 재사용하고, 채널 이름을 바꿔 그 안으로 옮깁니다.
3. 선택한 리드 모델·추론 강도로 채널 세션을 오케스트레이션 모드로 재시작합니다. 이후 리드가 여는 모듈 채널은 모듈 모델·추론 강도를 물려받습니다.

리드와 모듈은 설치된 MCP 도구(`send_order` / `report`)로 대화하며, 지시↔보고 왕복 기본 상한은 50회입니다. 이미 리드인 채널에서 다시 실행하면 새 컨텍스트로 초기화하고 이전 실행이 만든 모듈 채널을 정리합니다. 채널이 **Claude** 백엔드에 바인딩되어 있어야 하며, 그렇지 않으면 카드가 열리지 않고 컨트롤 플레인 채널에서도 거부됩니다.

### 레드마인 연동

`/dab-redmine`은 **URL** · **API 키** · **프로젝트(선택)** 모달을 띄웁니다. 저장하면 서버(길드)별 폴러가 5분마다 신규·진행 상태 이슈를 확인해서 이슈 카드(이슈번호 포함 제목 · 링크 · 설명 · 소속 프로젝트 · 목표 버전)를 지정된 보고 채널에 게시합니다. 상태 ID를 하드코딩하지 않고 인스턴스마다 조회해서 맞추며, `신규(New)` · `진행(Doing)` 같은 이중 표기도 매칭합니다.

이슈 카드에는 **[시작] / [취소]** 가 붙습니다. [시작]은 해당 이슈를 채워 넣은 세션 마법사를 열거나, 확인 단계를 거쳐 기존 세션에 이슈를 투입합니다. `/dab-redmine-issue-select`는 같은 드롭다운을 원할 때 직접 띄웁니다(상태 필터는 동일, "마지막 확인 시점" 기준은 없음). 디스코드 드롭다운은 25개가 한계라, 그보다 많으면 잘라내지 않고 메시지를 여러 개로 나눠 보냅니다.

API 키는 `DAB_REDMINE_KEY_SECRET`으로 암호화해서 저장하며, 이 값이 없으면 최초 부팅 때 `~/.dab/env`에 생성합니다. 없는 상태에서는 암·복호화 둘 다 평문으로 넘어가지 않고 실패합니다.

### 인가 & 멀티 서버

- 전역 config + 길드별 `servers/<guildId>.json` 오버라이드 (global → server → 채널 바인딩 3계층).
- 역할 티어 + 선택적 **유저 ID** 티어; 멤버 기본 티어와 예외는 `/dab-config` Access.
- DM 정책, 감사 로그 채널, 파일 작업 경로 confinement.

### 자동 업데이트

`/dab-update`가 릴리스 레지스트리를 확인하고, 승인 시 플랫폼 설치 경로 실행 후 서비스를 재시작합니다(macOS: `install.sh` + launchctl). config의 `autoUpdate.enabled`로 끌 수 있습니다. **저장소 체크아웃이 있어야 동작합니다**(위 수동/소스 빌드 설치) — Homebrew 설치에서는 동작하지 않으니 `brew upgrade`를 쓰세요(위 Homebrew 설치 절 참고).

---

## 경로 & 설정

### 배포 레이아웃 (`~/.dab` / `%USERPROFILE%\.dab`)

| 경로 | 역할 |
|---|---|
| `bin/dab` (Windows는 `.exe`) | 릴리스 바이너리 |
| `env` (Unix 0600) | 시크릿 + `DAB_*` (최초 설치 시 `swift/deploy/env.example`) |
| `run.sh` / `run.cmd` | 런처: PATH + 저장소 루트 `cd` + 바이너리 실행 |
| `logs/agent.{out,err}.log` | stdout / stderr |
| `chromium/` | 선택적 프로비저닝 Chrome |

### 설정·상태 (`~/.discord-agent-bridge/`, `DAB_HOME`으로 변경 가능)

| 경로 | 역할 |
|---|---|
| `config.json` | 전역 설정 (토큰 선택, 역할 기본값, favorites, locale, render, autoUpdate 등) |
| `servers/<guildId>.json` | 서버별 인가·기본값·프리셋·알림 |
| `swift-state.json` | 세션 바인딩 (버전 관리) |

서비스 설치 시 Discord 토큰은 **`~/.dab/env`** 에 두는 것을 권장합니다. 최초 실행은 config 없이 env / argv만으로도 가능합니다.

### 환경 변수

| 변수 | 기본 | 설명 |
|---|---|---|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | 게이트웨이 필수 |
| `DAB_CWD` | home | 기본 세션 작업 디렉터리 |
| `DAB_PERM_MODE` | `bypassPermissions` | 권한 UI 쓸 때는 `default` 권장 |
| `DAB_TURN_TIMEOUT_SEC` | `120` | 턴 결과 대기 |
| `DAB_DEV_GUILD_ID` | — | 길드 단위 슬래시 즉시 등록 (없으면 global, 최대 ~1시간) |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | Claude 사이드카 스폰 명령 오버라이드 |
| `DAB_RENDER` | (config) | `0` PNG 강제 끔 · `1` Chrome 있으면 켬 |
| `DAB_MERMAID_JS` | auto | `mermaid.min.js` 경로 |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | 프로비저닝 브라우저 캐시 |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | 시스템 스캔 | Chrome 바이너리 지정 |
| `CODEX_CMD` | `codex` | Codex CLI 오버라이드 (스모크/디스커버리) |

### CLI (`dab`)

```bash
dab                     # 봇 실행 (토큰: env / config)
dab --version
dab --setup             # 최초 설정 안내 출력
dab service status      # macOS launchd 상태
dab service restart     # macOS launchd 재시작
dab sidecar-smoke       # Claude 사이드카 프로토콜 핸드셰이크
dab codex-smoke         # Codex app-server initialize (CLI 없으면 exit 0)
dab grok-smoke          # Grok ACP 스모크 (CLI 없으면 exit 0)
dab attach-mcp          # stdio MCP 서버 (파일 첨부 / 문서 공유 / 지시 / 보고 도구)
```

서브커맨드 없이 `dab`만 실행할 때만 게이트웨이에 접속합니다. 위 서브커맨드는 모두 실행 후 종료합니다.

install / uninstall 은 `swift/scripts/` 의 셸·PowerShell 스크립트입니다.

---

## 아키텍처

```text
Discord  ◄──►  dab (Swift / DiscordBM)
                 │
                 ├─ Claude  ──stdio JSON-RPC──►  Node 사이드카  ──►  Claude Agent SDK
                 ├─ Codex   ──stdio JSON-RPC──►  codex app-server
                 ├─ Grok    ──stdio ACP───────►  grok CLI
                 └─ custom  ──shell env / spawn──►  설정한 명령
```

- **Claude**는 항상 Node 사이드카를 거칩니다(자동 스폰). Claude를 쓰면 체크아웃에 `npm install`이 필요합니다.
- **Codex / Grok**은 Swift 네이티브 클라이언트이며, 해당 CLI만 `PATH`에 있으면 됩니다.
- Claude 사이드카 프로토콜: [`docs/CLAUDE_SIDECAR_PROTOCOL.md`](docs/CLAUDE_SIDECAR_PROTOCOL.md) (로컬 `docs/`, gitignore).

패키지 구조: [`swift/README.md`](swift/README.md).

---

## 개발

```bash
# 저장소 루트에서
bash verify.sh
# 또는:
swift build --package-path swift
swift test --package-path swift
```

`.build` / SourceKit 락으로 hang 하면 격리 scratch 경로를 쓰세요:

```bash
swift test --package-path swift --scratch-path /tmp/dab-ci
swift build --package-path swift --scratch-path /tmp/dab-ci
```

백엔드 스모크(`sidecar` / `codex` / `grok`)는 best-effort이며 CLI가 없으면 깨끗이 스킵합니다.

빌드·테스트에 라이브 Discord 토큰은 **필요 없습니다**. 게이트웨이 연결과 실제 에이전트 실행은 자격 증명이 필요하며 수동으로 합니다.

---

## License

MIT — [LICENSE](LICENSE).
