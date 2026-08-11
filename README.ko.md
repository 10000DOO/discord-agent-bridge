# discord-agent-bridge

🌐 **한국어** | [English](README.md)

> Self-hosted Discord bot that runs AI coding agents — Claude Code, Codex, Grok, and more — per channel. Open access for every member, multi-server, extensible.

**Discord 채널 하나에 Claude Code · Codex · Grok(또는 custom 백엔드)을 붙여 쓰는 셀프호스팅 봇입니다.**

제품은 **Swift** 바이너리(`dab`)입니다. Claude Code 공식 Agent SDK가 Node 전용이라 **얇은 Node 사이드카**만 사용합니다. Codex / Grok은 각 CLI와 stdio로 직접 통신하며 Node가 필요 없습니다.

---

## 왜 쓰나요?

- 🏠 **완전 셀프호스팅.** 봇이 내 PC에서 돕니다. 코드·세션·CLI 토큰이 밖으로 나가지 않습니다.
- 📱 **책상 앞에 없어도 됩니다.** 폰 Discord로 작업을 던지면 스트리밍 응답, 툴 로그, 권한 승인 버튼이 채널에 뜹니다.
- 🗂️ **채널 하나 = 프로젝트 하나 = 세션 하나.** 채널마다 작업 폴더 · 백엔드 · 모델 · 추론 강도 · 권한 모드가 따로 붙습니다.
- 👥 **팀 관전 친화적.** 같은 채널을 보는 사람은 세션 진행을 그대로 봅니다. 서버 멤버는 전원 관리자이고, 실행 권한 제한은 없습니다.
- 🔀 **Claude ⇄ Codex ⇄ Grok (및 custom) 즉시 전환.** 세션 바인딩 후 `/mode` 등으로 백엔드를 바꿉니다.
- ⚙️ **터미널과 동등한 기능.** 프로젝트 `.claude/` · `.codex/` 설정을 그대로 써서 서브에이전트 · 스킬 · 훅 · MCP · 플러그인 명령이 CLI와 같이 동작합니다.
- 💾 **세션 프리셋.** 백엔드/모델/추론/권한 조합을 길드 단위로 저장해 두고, 다음엔 폴더만 고르면 시작할 수 있습니다.
- 🖼 **풍부한 응답.** GFM 표·Mermaid를 PNG로, 툴 실행은 작업 스레드+diff, 사용량 패널로 Claude / Codex / Grok 한도를 보여 줍니다.

---

## 준비물

아래 설명은 **macOS 기준**입니다. Linux · Windows는 맨 아래 [그 밖의 운영체제](#그-밖의-운영체제--linux--windows)를 보세요.

| 항목 | 설명 |
|---|---|
| **macOS 13+** | 제품 바이너리는 SwiftPM `dab` |
| **Swift 6.1+** | Xcode 또는 Command Line Tools (`xcode-select --install`) |
| **Node.js 20+** | **Claude 전용** — 사이드카 기동용. Codex/Grok만 쓰면 불필요 |
| 백엔드 CLI 설치·로그인 | **Claude Code** (`claude` 로그인 또는 `ANTHROPIC_API_KEY`); **Codex** CLI; 필요 시 **Grok** CLI. `PATH` → 사용자 bin 디렉터리(`~/.local/bin`, `~/.dab/bin`, `~/.cargo/bin`, `~/.grok/bin`, Homebrew) 순으로 찾으므로 `PATH`가 빈약한 서비스에서도 잡힙니다 |
| **Discord 봇 토큰** | 아래 1단계 |

---

## 1단계 — Discord 봇 만들고 토큰 받기

3분이면 됩니다. 여기서 할 일은 **토큰을 손에 넣는 것 하나**뿐입니다 — 서버 초대 링크는 3단계에서 dab이 만들어 줍니다.

1. **[Discord Developer Portal](https://discord.com/developers/applications)** → **New Application** → 이름 입력(예: `my-agent-bot`) → **Create**.
2. 왼쪽 **Bot** 탭 → **Reset Token** → 화면에 뜬 토큰을 복사.
   - 디스코드는 토큰을 **이때 한 번만** 보여 줍니다. 다시 보려면 또 Reset 해야 하고, 그러면 기존 토큰은 즉시 무효가 됩니다.
   - ⚠️ **OAuth2 탭의 Client Secret이 아닙니다.** 봇 토큰은 점(`.`)으로 나뉜 세 조각짜리 70자 내외 문자열이고, Client Secret은 점 없는 32자입니다. dab은 Client Secret을 쓰지 않습니다.
   - 토큰은 비밀번호입니다. 노출되면 즉시 **Reset Token**.
3. 같은 **Bot** 탭 **Privileged Gateway Intents**:
   - ✅ **MESSAGE CONTENT INTENT** — **필수** (없으면 봇이 메시지를 못 읽습니다)
   - ✅ **SERVER MEMBERS INTENT** — 권장 (역할 확인)
   - **Save Changes**.

서버 초대는 아직 하지 않아도 됩니다. 3단계에서 필요한 권한이 모두 박힌 초대 링크를 만들어 주고, 이미 초대해 두었다면 그 서버를 목록에서 골라 줍니다.

---

## 2단계 — 설치 (macOS)

```bash
brew tap 10000DOO/discord-agent-bridge
brew install 10000DOO/discord-agent-bridge/dab
```

소스에서 `dab`을 빌드하고 Claude 사이드카까지 같이 설치합니다 — 따로 `npm install`을 돌릴 필요 없습니다. Node.js 20+ / Swift 6.1+ 는 미리 깔려 있어야 합니다(위 준비물). Formula는 확인만 하고 대신 설치해 주지는 않습니다.

<details>
<summary>Homebrew 대신 소스에서 직접 빌드하기</summary>

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install                      # Claude 사이드카용 (Codex/Grok만 쓰면 생략 가능)
bash swift/scripts/install.sh    # 빌드 + 로그인 시 자동 실행 등록(launchd)
```

디스코드 안의 `/update` 명령은 이 방식에서만 동작합니다. Homebrew 설치는 `brew upgrade`를 쓰세요.

</details>

---

## 3단계 — `dab --setup` 한 줄로 연결하기

```bash
dab --setup
```

물어보는 대로 답하면 끝입니다. 파일을 찾아 열거나 서버 ID를 뒤질 필요가 없습니다.

```text
$ dab --setup

dab 설정을 시작합니다. 물어보는 대로 답하면 나머지는 알아서 처리합니다.

1) 봇 토큰을 붙여넣고 엔터를 누르세요. (입력은 화면에 보이지 않습니다)
   Discord Developer Portal → 내 애플리케이션 → 왼쪽 [Bot] 탭 → [Reset Token]
   ⚠️ OAuth2 탭의 Client Secret 이 아닙니다 — 점(.)이 2개 들어간 70자 내외 문자열입니다.

   확인 중…
   ✓ 확인 완료 — 봇 이름: my-agent-bot

2) 이 봇을 쓸 서버를 고릅니다.

   이 봇이 들어가 있는 서버가 없습니다. 아래 주소를 열어 서버에 초대해 주세요:

   https://discord.com/api/oauth2/authorize?client_id=…&scope=bot%20applications.commands&permissions=…

   초대를 마쳤으면 엔터를 누르세요. (건너뛰려면 s 입력)

   ✓ 우리팀 서버

저장했습니다 → /Users/me/.dab/env

백그라운드 서비스를 재시작해서 지금 적용할까요? [Y/n]

끝났습니다. 디스코드의 우리팀 서버에서 /setup 을 쳐보세요.
```

마법사가 대신 해 주는 것:

- **토큰을 그 자리에서 검증합니다.** 잘못 복사했거나 Client Secret을 넣으면 저장 전에 잡아냅니다. 통과하면 봇 이름을 보여 주므로 어느 봇에 붙었는지 바로 확인됩니다.
- **서버 초대 링크를 만들어 줍니다.** 봇이 쓸 수 있는 권한이 전부 박혀 있어서, OAuth2 URL Generator에서 체크박스를 고를 일도 없고 기능 하나 늘 때마다 재승인을 다시 누를 일도 없습니다. 멤버 제재(추방·차단·타임아웃)와 음성, `Administrator`는 **일부러 빼** 두었고, 승인 전에 디스코드가 전체 목록을 보여 줍니다.
- **서버를 목록에서 고르게 합니다.** 개발자 모드를 켜고 서버를 우클릭해 ID를 복사하는 과정이 없습니다. 이 값이 있어야 슬래시 명령이 **즉시** 등록됩니다 — 없으면 디스코드가 전역에 퍼뜨리느라 최대 1시간이 걸립니다.
- **`~/.dab/env`(권한 0600)에 저장합니다.** 기존 줄과 주석은 그대로 두고 필요한 항목만 갱신합니다.

토큰 없이 그냥 `dab`을 실행해도 같은 마법사가 자동으로 뜹니다. 나중에 봇을 바꾸고 싶으면 `dab --setup`을 다시 실행하면 됩니다.

### 잘 안 될 때

| 증상 | 원인 / 해결 |
|---|---|
| `✗ 이건 봇 토큰이 아닙니다` | OAuth2 탭의 **Client Secret**을 넣은 경우입니다. **Bot** 탭 → **Reset Token** 값을 넣으세요 |
| `✗ 디스코드가 거절했습니다` | 토큰이 만료됐거나(Reset Token을 다시 누른 경우) 복사가 잘렸습니다. 다시 발급받아 붙여넣으세요 |
| 봇은 온라인인데 `/setup`이 목록에 없음 | 2번에서 서버를 건너뛴 경우입니다(최대 1시간 대기). `dab --setup`을 다시 돌려 서버를 고르면 즉시 등록됩니다 |
| 봇이 계속 오프라인 | 1단계의 **MESSAGE CONTENT INTENT**가 꺼져 있는지 확인하세요 |
| `~/.discord-agent-bridge/config.json`이 있다 | 예전 TypeScript 버전의 잔재입니다. 지금은 `~/.dab/env`가 우선하므로 그대로 둬도 됩니다 |
| 토큰이 노출된 것 같음 | Developer Portal → Bot → **Reset Token** 후 `dab --setup`을 다시 실행하세요 |

### 서비스로 항상 켜두기

```bash
brew services start dab      # 시작 (크래시·재부팅 시 자동 복구)
brew services list           # 상태 확인
brew services restart dab    # 설정 변경 후
brew services stop dab       # 중지
```

로그: `$(brew --prefix)/var/log/dab.log` · `dab.error.log`
(소스 설치는 `dab service status` / `dab service restart`, 로그는 `~/.dab/logs/agent.out.log`)

성공하면 로그에 이렇게 찍힙니다:

```text
ready: username=<봇이름> id=<숫자> app=<숫자>
registered setup, config, agent, ... to guild <서버ID>
```

업데이트:

```bash
brew upgrade 10000DOO/discord-agent-bridge/dab
brew services restart dab   # 서비스로 켜둔 경우에만 필요
```

> ⚠️ **같은 봇 토큰으로 두 개를 동시에 켜지 마세요.** 포그라운드 `dab`, `brew services`, 소스 설치가 전부 같은 토큰을 읽습니다. 두 번째 인스턴스는 에러 없이 그냥 같이 떠서 응답이 중복되거나 꼬입니다.

---

## 4단계 — Discord에서 사용하기

기본 흐름: **`/setup` → `/config` → `/agent start`**, 이후 세션 채널에서 일반 메시지.

1. **`/setup`** — 컨트롤 채널 · 세션 카테고리 · 상태 채널 (기존 재사용).
2. **`/config`** — 역할 티어, 기본값(백엔드/모델/추론/권한), 로케일, 알림, 이미지/Chromium 렌더, 유저별 접근 예외. 이 중 **접근 관련 값(역할 티어 · 유저별 예외)은 저장·표시만 되고 아무도 막지 못합니다** — 아래 "인가 & 멀티 서버" 참고.
3. **`/agent start`** — 마법사: **폴더 → [프리셋 있으면] → 백엔드 → 모델 → 추론 → 권한**. `/setup` 후 세션 카테고리 아래 A4D `<임의ID>-<folder>-proj` 채널을 만들고 바인딩할 수 있습니다.
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
| `/setup` | 관리자 | 컨트롤 + 세션 카테고리 + 상태 채널 프로비저닝 |
| `/config` | 관리자 | 역할·기본값·로케일·알림·렌더·접근 패널 |
| `/agent start` | execute+ | 마법사: 폴더/백엔드/모델/추론/권한 바인딩 (+ 프리셋) |
| `/agent resume` | execute+ | 저장된 세션 재바인딩, 상태 표시, soft reconnect |
| `/agent close` | execute+ | 백엔드 중지 + 이 채널 언바인드 |
| `/agent stats` | execute+ | 활성 바인딩 + Claude / Codex / Grok 사용량(가능 시) |
| `/mode backend` | execute+ | 백엔드 전환 (새 컨텍스트) |
| `/mode perm` | execute+ | 권한 모드 전환 (세션 유지) |
| `/model` | execute+ | 모델 전환 (프로바이더 카탈로그 자동완성) |
| `/effort` | execute+ | 추론 강도 전환 (자동완성) |
| `/clear` | execute+ | 동일 폴더/설정으로 새 대화 |
| `/stop` | execute+ | 이 채널 세션 hard-stop |
| `/stop-all` | 관리자 | 모든 바인딩 세션 hard-stop |
| `/doc path:` | execute+ | 작업 공간 마크다운을 문서 스레드로 공유 |
| `/diff` | execute+ | 이 폴더의 커밋 안 된 변경을 스레드로 열기 (파일 선택 + 전부 펼치기) |
| `/redmine` | execute+ | 레드마인 알림 연동 모달 (URL / API 키 / 프로젝트) |
| `/redmine-issue-select` | execute+ | 신규·진행 상태 레드마인 이슈를 드롭다운에서 골라 세션 시작 |
| `/command` | execute+ | 이 채널의 백엔드가 지원하는 슬래시 명령 실행 (자동완성 + 프롬프트 모달) |
| `/command-list` | execute+ | 이 채널의 백엔드가 지원하는 명령 전체 목록 |
| `/update` | 관리자 | 새 릴리스 확인 후 설치·재시작 제안 |

모든 명령은 접두사 없이 그대로 등록됩니다. 위 표의 **권한 열은 현재 빌드에서는 아무 것도 걸러내지 않습니다** — 봇이 들어간 서버의 모든 멤버(지금 있는 사람 + 앞으로 초대될 사람)가 무조건 관리자이고, 등급은 관리자 하나뿐입니다. 설정으로도 이걸 좁힐 수 없습니다(아래 "인가 & 멀티 서버" 참고). 열은 각 명령이 서버 전체를 건드리는 작업인지(관리자) 이 채널만 건드리는 작업인지(execute+) 알려주려고 남겨 둔 것일 뿐, 실행 자격과는 무관합니다. `/setup`의 "관리자가 없는 서버에서는 먼저 실행한 사람이 관리자를 가져간다"는 최초 1회 예외도 이제 의미가 없습니다 — 처음부터 전원이 관리자입니다.

`/setup` · `/config` · `/update`는 예전 빌드에서 디스코드 쪽 명령 권한(`default_member_permissions`)으로 잠겨 있어 관리자가 아닌 사람에게는 **명령 목록에 뜨지도 않았습니다**. 지금은 그 잠금 없이 등록하므로 누구에게나 보입니다. 다만 두 가지는 봇이 어쩌지 못합니다 — ① 명령 등록이 전역이라 디스코드가 각 서버에 퍼뜨리는 데 최대 1시간쯤 걸릴 수 있고(업그레이드 직후 안 보이는 건 고장이 아닙니다), ② 이미 **서버 설정 → 연동 → 이 봇**에서 명령별 권한을 손봐 둔 서버는 그 설정이 서버 쪽에 남습니다. 안 보이면 그 화면에서 해당 명령의 권한 오버라이드를 지워 주세요.

**이 채널의 세션**을 대상으로 하는 명령(`/model` · `/effort` · `/mode` · `/clear` · `/stop`)은 채널이 바인딩되지 않았으면 "세션 없음"으로 응답합니다.

백엔드 명령 중 일부는 CLI가 자기 대화형 화면에만 그리는 것이어서, 프로토콜로 물으면 한 줄 요약이나 "이 환경에서는 안 됨" 문구만 돌아옵니다. 그런 명령(Claude의 `/status` · `/mcp` · `/memory` · `/skills` · `/plugin`, Grok의 `/context`)은 브리지가 살아 있는 세션이 이미 들고 있는 사실(버전 · cwd · 모델 · 권한 모드 · MCP 서버 · 스킬/플러그인 · 메모리 파일)로 화면을 재구성해 대신 올립니다. 받아둔 사실이 없으면 백엔드 원문을 그대로 통과시킵니다 — 없는 값을 만들지는 않습니다.

### 권한 모드

`default` · `acceptEdits` · `plan` · `bypassPermissions` (카탈로그된 백엔드별 프로필 포함).

툴 승인이 필요하면 **Allow / Always-Allow / Deny** 버튼이 채널에 올라갑니다. 실사용은 `default` 권장. `bypassPermissions`는 UI를 건너뜁니다(신뢰된 머신 전용). 턴 중 **Interrupt(stop)** 버튼은 바인딩을 풀지 않고 현재 턴만 중단합니다.

---

## 기능

### 세션 마법사 & 프리셋

- 폴더 브라우저: 이동 · 폴더 생성 · favorites 루트(`config.favorites`) · 가능한 경우 네이티브 선택.
- **프리셋**(길드 단위): 일반 시작 후 백엔드/모델/추론/권한을 이름으로 저장. 다음 `/agent start`에서는 프리셋 선택 → 폴더만 고르면 됩니다.
- **재개(resume)** · **재구성(reconfigure)** 경로 지원.
- 봇 재시작 시 `swift-state.json`에서 바인딩 복구 (예전 `state.json`이 있으면 1회 임포트 가능).

### 라이브 세션 UX

- 스트리밍 상태 임베드 (텍스트 / 툴 진행). 제목에 붙는 경과 시간(`응답 중… · 3분 34초`)은 타이머로 다시 그려지므로, 턴 중간에 이벤트가 하나도 안 나오는 구간에서도 숫자가 계속 움직입니다 — 일하는 세션과 멈춘 세션이 같아 보이는 일이 없습니다.
- **툴 입력 진행 표시 (Claude).** 툴 입력은 호출이 알려지기 *전에* 만들어지기 때문에, 큰 `Write`/`Edit` 하나가 채널을 수 분간 침묵시켰습니다. 이제 입력이 만들어지기 시작하는 순간 툴 이름이 올라가고, 8KB마다 누적 크기가 따라옵니다(`Write` → `Write: 8.0KB` → …). Codex는 자기 `item/started` 알림으로 같은 걸 보여주고, Grok CLI는 툴 입력을 마지막에 한 번에 넘겨주므로 그쪽은 경과 시간만 움직입니다.
- 툴 활동 → Discord 작업 스레드 + 포맷된 출력·**diff**. 활동 로그 줄은 CLI 형식 한 줄 요약이고, 스레드에는 결과 본문이 **전부** 들어갑니다 — 한 메시지를 넘기면 잘라내지 않고 여러 메시지로 나눠 보냅니다.
- 상태 채널 알림(주요 이벤트, `/config`에서 설정).
- `/agent stats`의 사용량 임베드 (Claude OAuth, Codex rate limit, Grok weekly).
- 턴이 수 분간 조용하면 idle watchdog 안내.
- 에이전트 → 채널 파일 첨부/문서 공유(`host.file.attach` / share), 경로 confinement.
- **채널에 올린 첨부파일**은 `<작업공간>/.dab-attachments/<uuid>/` 로 내려받습니다(realpath confinement, 메시지마다 별 디렉터리라 동시 턴끼리 덮어쓰지 않음). 이미지는 이를 받는 백엔드에 비전 입력으로 들어가고, 나머지는 절대 경로 힌트로 프롬프트에 덧붙습니다.

### 작업 목록 패널 (고정)

세 백엔드 모두 작업하면서 할 일 목록을 내보냅니다(Claude `TaskCreate`/`TaskUpdate` — 구버전 CLI는 `TodoWrite`, Codex `update_plan`, Grok ACP plan). 그 목록을 **채널당 고정 메시지 한 개**로 보여줍니다 — `✓` 완료 / `▶` 진행 / `•` 대기 체크리스트에 `완료/전체` 카운트가 붙고, 전부 끝나면 초록색으로 바뀝니다. 스크롤을 되감지 않고 채널 📌에서 바로 열면 됩니다.

고정은 **최초 1회**만 하고 이후에는 그 메시지를 수정합니다. 디스코드는 고정할 때마다 채널에 시스템 알림을 남기고 채널당 50개 상한이 있어서, 갱신마다 재고정하면 채널이 도배됩니다. 목록을 안 내보내는 턴에서는 이전 목록이 그대로 남고, `/clear`·`/stop`·언바인드에서 패널이 사라집니다. 재시작 후에는 채널에 이미 고정돼 있는 패널을 다시 붙잡아 이어 갱신합니다(두 번째 패널을 만들지 않습니다).

고정에는 `Manage Messages` 권한이 필요합니다. 디스코드가 고정 기능을 별도 권한 `Pin Messages`로 떼어낸 서버에서는 그쪽이 필요하고, 초대 링크는 둘 다 요청합니다. 둘 다 없으면 패널을 일반 메시지로 올리고, 해결 방법을 한 번만 안내합니다 — 바로 쓸 수 있는 재승인 링크를 같이 줍니다. 디스코드는 봇이 자기가 갖지 않은 권한을 스스로 부여하는 것을 막기 때문에 클릭 한 번이 최소치이고, 완전 자동은 불가능합니다.

### 커밋 안 된 변경 보기 (`/diff`)

`/diff`는 채널 폴더의 변경을 스레드로 엽니다 — 요약(파일 목록 + `+`/`-` 집계, 저장소·브랜치)과 **파일 선택**, **전부 펼치기** 버튼. diff 본문은 ```diff``` 블록으로 올라가고 잘리지 않습니다(길면 메시지 수가 늘어날 뿐입니다). 변경 파일이 25개를 넘으면 선택 메뉴가 여러 개로 나뉩니다(목록을 잘라내지 않습니다). 커밋 안 된 변경이 없거나 git 저장소가 아니면 한 줄로만 답하고 스레드를 만들지 않습니다.

### 이미지 렌더 (표 · Mermaid)

GFM 표와 fenced `mermaid` 블록을 PNG 첨부로 올릴 수 있습니다. 조건:

1. 렌더 켜짐 (`/config` → 🖼 렌더, 기본 on), 그리고  
2. 브라우저 사용 가능: 시스템 Chrome/Edge/Chromium, 또는 `~/.dab/chromium`에 프로비저닝 ( `/config` 또는 `/setup` 직후 Install Chromium; 다운로드 헬퍼에 Node 필요).

구현: 로컬 HTML을 **headless Chrome CLI**로 스크린샷 (프로세스 내 브라우저 런타임 없음). 실패 시 raw 마크다운으로 폴백. 타임아웃·크기·동시성 상한 있음.

환경 변수: `DAB_RENDER=0|1`, `DAB_MERMAID_JS`, `DAB_CHROMIUM_CACHE`, `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH`.

### 레드마인 연동

`/redmine`은 **URL** · **API 키** · **프로젝트(선택)** 모달을 띄웁니다. 저장하면 서버(길드)별 폴러가 5분마다 신규·진행 상태 이슈를 확인해서 이슈 카드(이슈번호 포함 제목 · 링크 · 설명 · 소속 프로젝트 · 목표 버전)를 지정된 보고 채널에 게시합니다. 상태 ID를 하드코딩하지 않고 인스턴스마다 조회해서 맞추며, `신규(New)` · `진행(Doing)` 같은 이중 표기도 매칭합니다.

이슈 카드에는 **[시작] / [취소]** 가 붙습니다. [시작]은 해당 이슈를 채워 넣은 세션 마법사를 열거나, 확인 단계를 거쳐 기존 세션에 이슈를 투입합니다. `/redmine-issue-select`는 같은 드롭다운을 원할 때 직접 띄웁니다(상태 필터는 동일, "마지막 확인 시점" 기준은 없음). 디스코드 드롭다운은 25개가 한계라, 그보다 많으면 잘라내지 않고 메시지를 여러 개로 나눠 보냅니다.

API 키는 `DAB_REDMINE_KEY_SECRET`으로 암호화해서 저장하며, 이 값이 없으면 최초 부팅 때 `~/.dab/env`에 생성합니다. 없는 상태에서는 암·복호화 둘 다 평문으로 넘어가지 않고 실패합니다.

### 인가 & 멀티 서버

- **모두가 관리자입니다.** 봇이 들어간 모든 서버의 모든 멤버 — 지금 있는 사람과 앞으로 초대될 사람 전부 — 가 무조건 관리자 등급이고, 모든 명령을 쓸 수 있습니다. (DM 메시지는 인가와 무관하게 예전처럼 무시됩니다 — 세션은 서버 채널에서만 돕니다.)
- 등급은 관리자 하나뿐입니다. 역할 티어, 유저 ID 티어, 멤버 기본 티어, 개인 예외(`/config` Access), 프로젝트별 접근 목록, DM 정책 — 이 값들은 여전히 저장·표시되지만 **접근을 좁히지 못합니다**. 개인을 `none`(완전 차단)으로 저장해도 차단되지 않습니다.
- 전역 config + 길드별 `servers/<guildId>.json` 오버라이드 (global → server → 채널 바인딩 3계층)는 접근 외 설정(기본값·로케일·프리셋 등)에 그대로 적용됩니다.
- 감사 로그 채널, 파일 작업 경로 confinement는 그대로 동작합니다.

### 자동 업데이트

`/update`가 릴리스 레지스트리를 확인하고, 승인 시 플랫폼 설치 경로 실행 후 서비스를 재시작합니다(macOS: `install.sh` + launchctl). config의 `autoUpdate.enabled`로 끌 수 있습니다. **저장소 체크아웃이 있어야 동작합니다**(위 수동/소스 빌드 설치) — Homebrew 설치에서는 동작하지 않으니 `brew upgrade`를 쓰세요(위 Homebrew 설치 절 참고).

같은 `autoUpdate.enabled` 스위치가 **백엔드 실행 환경**도 함께 최신으로 유지합니다. 한 시간마다 Claude Agent SDK · Codex CLI · Grok CLI 버전을 확인해 뒤처진 것만 올립니다 — npm 전역 설치와 Homebrew cask는 지원하고, 그 밖의 설치 형태는 `unsupported`로 보고하고 건드리지 않습니다. 교체는 어느 채널에서도 턴이 돌지 않을 때만 시작하고, 새 턴은 교체가 끝날 때까지만 기다립니다. 교체 후 런타임을 재시작해 모델 카탈로그를 확인하며, 깨진 업그레이드는 롤백합니다. 프로세스 간 락 파일로 한 번에 한 `dab`만 수행하고, 강제 종료로 중단된 업데이트는 다음 부팅에서 롤포워드/롤백합니다. 결과는 Discord가 아니라 로그의 `provider-runtime: …` 줄로 남습니다.

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

Discord 토큰은 **`~/.dab/env`** 에 둡니다 — `dab --setup`이 여기에 쓰고, `dab`은 서비스든 포그라운드든 매번 이 파일을 읽습니다. 토큰 탐색 순서: 프로세스 환경변수 `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN`(`~/.dab/env`가 채워 줍니다) → 첫 번째 CLI 인자 → 예전 TypeScript 설치를 위한 최후 수단으로 `config.json`의 `discord.token`.

### 환경 변수

| 변수 | 기본 | 설명 |
|---|---|---|
| `DISCORD_BOT_TOKEN` / `DISCORD_TOKEN` | — | 게이트웨이 필수 |
| `DAB_CWD` | home | 기본 세션 작업 디렉터리 |
| `DAB_PERM_MODE` | `bypassPermissions` | 권한 UI 쓸 때는 `default` 권장 |
| `DAB_TURN_TIMEOUT_SEC` | `120` | 턴 결과 대기 |
| `DAB_DEV_GUILD_ID` | — | 길드 단위 슬래시 즉시 등록 (없으면 global, 최대 ~1시간) |
| `DAB_HOME` | `~/.discord-agent-bridge` | 설정·상태 루트 |
| `DAB_CAPS` | (config) | 렌더 기능 오버라이드(`toolThreads` / `fileDiff` / `usagePanel` / `streaming`), 전역·서버 설정보다 우선 |
| `DAB_CLAUDE_SIDECAR_CMD` | auto | Claude 사이드카 스폰 명령 오버라이드 |
| `DAB_RENDER` | (config) | `0` PNG 강제 끔 · `1` Chrome 있으면 켬 |
| `DAB_MERMAID_JS` | auto | `mermaid.min.js` 경로 |
| `DAB_CHROMIUM_CACHE` | `~/.dab/chromium` | 프로비저닝 브라우저 캐시 |
| `PUPPETEER_EXECUTABLE_PATH` / `CHROME_PATH` | 시스템 스캔 | Chrome 바이너리 지정 |
| `CODEX_CMD` | `codex` | Codex CLI 오버라이드 (스폰·스모크) |
| `GROK_CMD` | `grok` | Grok CLI 오버라이드 (스폰·스모크) |

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
dab attach-mcp          # stdio MCP 서버 (파일 첨부 / 문서 공유 도구)
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

## 그 밖의 운영체제 — Linux / Windows

위 본문은 macOS 기준입니다. 1단계(봇 만들기)와 3단계(`dab --setup`)는 어느 운영체제든 똑같고, 설치와 서비스 등록 방법만 다릅니다.

### Linux (systemd --user)

```bash
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install                              # Claude 사이드카용 (Codex/Grok만 쓰면 생략 가능)
bash swift/scripts/install-linux.sh
dab --setup                              # 토큰 입력 → 서버 선택 → 저장
systemctl --user restart discord-agent-bridge
```

상태·로그: `systemctl --user status discord-agent-bridge` · `journalctl --user -u discord-agent-bridge -f`
업데이트: `git pull && bash swift/scripts/install-linux.sh` (또는 디스코드에서 `/update`)
제거: `bash swift/scripts/uninstall-linux.sh`

### Windows (작업 스케줄러 / 로그온 시)

```powershell
git clone https://github.com/10000DOO/discord-agent-bridge.git
cd discord-agent-bridge
npm install
powershell -ExecutionPolicy Bypass -File swift\scripts\install-windows.ps1
dab --setup
schtasks /Run /TN discord-agent-bridge
```

설정 파일 위치는 `%USERPROFILE%\.dab\env` 입니다.
업데이트: `git pull` 후 `install-windows.ps1` 다시 실행 (또는 디스코드에서 `/update`)
제거: `install-windows.ps1 -Uninstall`

### 서비스 없이 한 번만 실행

```bash
dab
```

`~/.dab/env`를 직접 읽으므로 별도 환경변수 설정이 필요 없습니다. 저장된 토큰이 없으면 설정 마법사가 자동으로 뜹니다.

---

## License

MIT — [LICENSE](LICENSE).
