# Discord Agent Bridge — Swift 포팅 & 슬림화 설계

> 브랜치: `plan/swift-port`  
> 문서 갱신: **2026-07-26**  
> 대상: `discord-agent-bridge` (TypeScript / Node 20+ + Swift 병행)  
> 목표: **봇 본체 = Swift**, Claude Code만 얇은 **Node(TS) 사이드카**, 포팅 전에 TS **과설계 제거**

이 문서가 단일 기준 문서다. 포팅 아키텍처 · 슬림화 원칙 · 순서 있는 작업 큐 · 완료 기록을 모두 여기 둔다.  
사이드카 wire 상세: [`CLAUDE_SIDECAR_PROTOCOL.md`](./CLAUDE_SIDECAR_PROTOCOL.md) · Swift 사용법: [`swift/README.md`](./swift/README.md)

---

## 0. 현재 진행 상황 (스냅샷)

| 항목 | 상태 |
|------|------|
| **전체 단계** | Phase A~F **MVP 완료**, Phase G **W11 완료**, Phase H **W12 문서 완료**, Phase I~L **W13–W16 ship**(b 보류·폴리시 잔여). **제품 경로 = Swift `dab`** (TS 메인 = 레거시/참고 + Claude 사이드카) |
| **브랜치** | `plan/swift-port` |
| **TS 기본 경로** | 레거시 in-process Claude (변경 없음). **권장 설치 아님** — README는 Swift-first |
| **TS 사이드카** | 메인 opt-in `DAB_CLAUDE_SIDECAR=1` · **Swift Claude는 항상 사이드카** |
| **Swift 봇** | `bash swift/scripts/install.sh` 또는 `swift run --package-path swift dab` · 슬래시+`!claude`/`!codex`/`!grok`/`!custom` |
| **설정/상태** | `DAB_HOME` 또는 `~/.discord-agent-bridge/` (`config.json`, `servers/`, `swift-state.json`) · 배포 바이너리/시크릿은 `~/.dab/` |
| **검증** | `swift test --package-path swift --scratch-path /tmp/dab-ci` (수백 테스트; 일부 병렬 플래키 이슈 잔존 §14.4). ⚠️ 그냥 `swift test`는 인덱서 락 hang — **§14.2 필독** |
| **패리티** | **100% 아님** — 잔여 목록 아래. 루트 README 호환 매트릭스 기준 |

### 완료 (W1–W12 · W13a/c/d · W14–W15 · W16 ship · W11 전부)

| ID | 요약 |
|----|------|
| W1–W5 | TS 슬림화: 스텁 삭제, CLI help 공용, Custom→Claude 훅, interactionRouter 분할, UsageProvider |
| W6 | 사이드카 프로토콜 문서 (`CLAUDE_SIDECAR_PROTOCOL.md`) |
| W7 | Node Claude 사이드카 + Host 클라이언트 + host.file 역RPC + opt-in 배선 |
| W8 | SwiftPM + DiscordBM + gateway ready |
| W9 | Swift 사이드카 클라이언트 + Discord `!claude` → Claude 답글 (MVP) |
| W10 | Codex/Grok 텍스트 경로 (`!codex`/`!grok`) 3백엔드 완성 |
| **W11** | **전체 `done`**: a·b1·**b2**(folder·resume·reconfigure·A4D·preset)·c·d·e·f1·f2·**g**(HUD·setModel·live stream)·h |
| W13·W14·W15 | 보안(a/c/d)·라이프사이클·3계층 config (**W13-b 보류**) |
| W16-a~h (ship) | chunk·`/config` model/effort/notif·`/setup`·`/doc`·Always-Allow·custom·toolThread/diff/status/notifier·Codex/Grok mid-turn tool·**capabilities 게이팅**·auto-update 체크 UI |
| **W12** | **레거시 정책·호환 매트릭스·루트 README/README.ko 마이그레이션 가이드** |

### 진행 중 / 부분 완료 (잔여)

| ID | 상태 | 남은 일 |
|----|------|---------|
| **W16-b** | ship + residual | model/effort·notif ✅ · **locale select ✅** (global `config.locale`, roleRows 5th; ko/en) · **이미지/chromium 서브패널 = S3 defer** |
| **W16-g** | ship + residual | toolThread/diff/status/notifier ✅ · Codex/Grok mid-turn tool ✅ · **capabilities 게이팅 ✅** · **pin status embed ✅** (best-effort) · **gap:** Codex parentByThread/collab child-thread · Grok plan/thought progress |
| **W16-h** | ship + residual | 체크·승인 UI ✅ · **바이너리 self-replace·서비스 재시작**(승인 시 수동 설치 안내만) |
| **W13-b** | `보류(Q5=B)` | 툴 allowlist + 기본 permMode `default` 전환 — 사용자가 기본 변경 원할 때 재개 |
| **기타** | overall | ~~host.file.attach Discord 업로드~~ ✅ · Chromium 렌더(S3 defer) · Linux/Windows 서비스 |

### 의도적으로 아직 없는 것 / 부분

- 풀 SessionOrchestrator / ChannelRegistry 동등 레이어 (얇은 SessionLifecycle·Registry로 대체 중)
- ~~Claude 라이브 `session.setModel`/`setEffort` RPC + displayName~~ ✅ (W11-g)
- ~~`/mode backend` reconfigure · folder · resume · A4D · preset~~ ✅ (W11-b2)
- ~~tools/subagent HUD · 라이브 스트림 임베드~~ ✅ (W11-g)
- ~~interrupt **버튼 UI**~~ ✅ (W14 lib + pure `InterruptButton` + DabMain)
- ~~capabilities 렌더 게이팅~~ ✅ (W16-g 흡수: toolThreads/fileDiff/streaming/usagePanel)
- ~~host.file.attach 실제 Discord 업로드~~ ✅ (`FileAttach`+`FileAttachHost`+`postFileAttach`+cwd 감금; share는 W16-d)
- ~~`/config` locale select~~ ✅ (global autosave) · ~~pin status embed~~ ✅ · **render(S3)** · auto-update **바이너리 self-replace**
- 기존 npm 봇 기능 **100% 패리티 미달** (목표 지향, 진행 중 — README 매트릭스에 명시)

### 빠른 실행

```bash
# 권장: Swift 제품
bash swift/scripts/install.sh          # 또는 일회:
export DISCORD_BOT_TOKEN=...
swift run --package-path swift dab     # repo root

# 레거시 TS 메인 — Claude 사이드카 opt-in (참고용)
DAB_CLAUDE_SIDECAR=1 npm run dev

# 전체 검증 (Swift 전용)
bash verify.sh
# hang 시:
swift test --package-path swift --scratch-path /tmp/dab-ci

# 스모크
swift run --package-path swift dab sidecar-smoke
swift run --package-path swift dab codex-smoke
swift run --package-path swift dab grok-smoke
```

### 다음에 할 일 (우선순위) — W11·W12 이후 잔여

**W11 전부·W12 문서 완료.** 기능 패리티 **폴리시 잔여**만 남음. 전수조사 결정(2026-07-25) 유지: **TS 파리티 100% 지향**.

0. ~~**W12**~~ ✅ · ~~**W11-b2**~~ ✅ (folder·resume·reconfigure·A4D·preset) · ~~**W11-g**~~ ✅ (HUD·setModel·live stream)
1. ~~**W16-b** model/effort·notif~~ ✅ · ~~**W16-g** Codex/Grok mid-turn tool + capabilities~~ ✅
2. **W16 폴리시 잔여** — pin status embed · `/config` locale · auto-update **바이너리 self-replace** · (S3) render 서브패널
3. **W16-g gap** (선택) — Codex parentByThread/collab · Grok plan/thought
4. **W13-b** (선택) — 기본 permMode/`allowlist` when product default moves off bypass
5. 부수: ~~host.file.attach Discord 업로드~~ ✅ · Linux/Windows 서비스 · `verify.sh` `--scratch-path` · §14.4 플래키 판정

---

## 1. 한 줄 요약

| 구분 | 언어 | 이유 |
|------|------|------|
| Discord, 세션 관리, 설정, Codex, Grok | **Swift** | 프로세스/프로토콜 기반 |
| Claude Agent SDK | **Node/TS 사이드카** | 공식 SDK가 Node 전용 |
| 연결 | **JSON-RPC over stdio** | Swift `ClaudeMode` = 사이드카 클라이언트 |

> Claude SDK 때문에 TS 레이어 하나를 깔고, 그거 빼고는 Swift로 가능하다.  
> 포팅 전에 **스텁·복붙·신파일**을 깎아 옮길 표면을 줄인다.

---

## 2. 현재 제품 (30초)

Discord 채널 하나 = 코딩 에이전트 세션 하나.

1. Discord 메시지 / 슬래시 수신  
2. 권한·설정·채널 바인딩  
3. 백엔드(Claude / Codex / Grok / Custom)에 턴 전달  
4. `AgentEvent` → Discord 렌더  

계약 원본: `src/core/contracts.ts` (`AgentMode` / `ModeSession` / `AgentEvent`).

```
Discord UI ──► SessionOrchestrator ──► AgentMode
                      │                    │
                      ▼                    ▼
                 EventBus            프로세스/SDK
                      │
                      ▼
                 Discord renderers
```

Swift로 가도 **이 그림은 유지**. 언어와 Claude 구현 위치만 바뀐다.

### 규모 스냅샷 (감사 시점)

| 구분 | 대략 |
|------|------|
| 프로덕션 TS | ~22k 줄 / 104 파일 |
| 테스트 | ~21k 줄 / 77 파일 (~1:1) |
| `discord/` | ~10k (절반) |
| `modes/` | ~6.3k |
| `core/` | ~3.8k |
| 최대 파일 | `interactionRouter.ts` ~2,065 줄 |

---

## 3. 목표 아키텍처 (하이브리드)

```
┌──────────────────────────────────────────────────┐
│  Swift 메인                                        │
│  CLI / launchd · Discord · Core · Codex · Grok     │
│  ClaudeMode ──stdio JSON-RPC──► Node 사이드카       │
└──────────────────────────────────────────────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ claude-sidecar (TS)  │
              │ modes/claude 최소만  │
              │ start/send/stop/     │
              │ permission/list      │
              │ AgentEvent 스트림    │
              └─────────────────────┘
```

### 사이드카 포함 / 제외

| 포함 | 제외 (Swift) |
|------|----------------|
| `query` / `listSessions` / canUseTool / MCP file tools | Discord, 위저드, embed |
| contracts 이벤트 매핑 | ChannelRegistry, auth, config |
| wire protocol 입출력 | Codex / Grok / launchd |

사이드카에 **새 비즈니스 로직을 넣지 않는다.**

### Wire protocol 초안

```text
→ session.start | session.resume | session.send | session.interrupt | session.stop
→ session.permission | sessions.list
← event { session, event: AgentEvent }
```

`AgentEvent.kind`는 현재 TS와 **1:1** (이름 유지).

---

## 4. 슬림화 원칙 (포팅 전·중 공통)

감사 태그:

| 태그 | 의미 |
|------|------|
| `delete` | 죽은 코드·미구현 스텁 |
| `yagni` | 한 곳만 쓰는 복제·과도한 분기 |
| `shrink` | 동작 동일, 줄/파일만 감소 |
| `defer` | 1차 포팅에서 후순위 |
| `keep` | 건드리지 말 자산 |

### 하지 말 것

- 새 DI 컨테이너 / 이벤트 버스 교체 / “더 예쁜” 레이어 추가  
- Swift에서 Claude Agent SDK 재구현  
- ~~테스트 1:1 복제 금지 (계약+스모크만)~~ → **2026-07-24 정책 변경: Swift는 브리지 포함 촘촘한 단위테스트 채택 (TS 수준 커버리지 목표)**  
- 1차에 Puppeteer 동등성 고집  
- contracts의 `kind` 이름을 멋대로 바꾸기  

### 유지할 자산 (`keep`)

- `AgentMode` / `AgentEvent` / turn queue / deny-by-default  
- ModeRegistry, EventBus (얇음)  
- Discord `ports` (테스트 격리 가치)  
- Codex app-server / Grok ACP 본체  

### 감사 한 줄 목록 (원본)

```
delete: HookBridge / CommandRouter / classifyCommand stubs
shrink: Split interactionRouter into handlers
yagni:  Shared CLI help catalog for codex+grok permissionSource
yagni:  CustomMode → ClaudeMode env hook
shrink: Comment diet (WHY only)
yagni:  UsageProvider + thin adapters
shrink: Stateless renderers into fewer modules
defer:  Chromium/Puppeteer optional on first Swift slice
test:   Comprehensive Swift tests incl. bridges (2026-07-24 정책; was: don't re-port full volume)
```

예상 1차 슬림: 프로덕션 **−400~800줄** 중복/스텁.  
공격적 분할·Custom 흡수·렌더 후순위 시 포팅 표면이 크게 줄음.

---

## 5. 단계 (Phase) 맵

| Phase | 이름 | 성공 기준 |
|-------|------|-----------|
| **A** | TS 슬림화 (W1–W5) | 스텁 제거, 복붙 감소, router 분할 |
| **B** | 계약 고정 (W6) | JSON Schema + 사이드카 메서드 표 |
| **C** | Claude 사이드카 분리 (W7) | 기존 봇 = 사이드카 경유 Claude 동일 동작 |
| **D** | Swift 골격 (W8) | Swift 바이너리 Discord 로그인 |
| **E** | Swift Core + Claude E2E (W9) | Swift + 사이드카로 Claude 세션 |
| **F** | Codex / Grok (W10) | 백엔드 3종 |
| **G** | UX·운영 패리티 (W11) | ✅ 위저드·서비스·배포·HUD·라이브 스트림 |
| **H** | 정리 (W12) | ✅ 문서: TS 메인 레거시 정책, 호환 매트릭스, README 마이그레이션 (코드 deprecate는 패리티 이후) |

기본 제품 가정 (변경 시 이 절 수정):

1. **macOS 1차**  
2. **CLI + launchd** (현 UX)  
3. 처음엔 **시스템 Node**, 이후 번들 검토  
4. TS 메인 앱은 E 검증까지 레거시 유지  
5. E까지 **Claude-only**, 이후 Codex → Grok  

---

## 6. 작업 큐 (Ordered Backlog)

규칙:

- **위에서 아래 순서**로 진행. 한 항목 완료 후 다음.  
- 각 항목: 범위 · 완료 조건 · 비고.  
- 상태: `todo` → `doing` → `done` / `skipped`.  
- 코드 변경은 최소 diff. 요청 없는 리팩터 금지.  
- 완료 시 아래 표 + [완료 로그](#7-완료-로그) 갱신.

| ID | Phase | 상태 | 작업 | 완료 조건 |
|----|-------|------|------|-----------|
| **W1** | A | `done` | 미구현 스텁 삭제: `hookBridge.ts`, `commandRouter.ts`, `commandPolicy.ts`. `PolicyTier` 등 실사용 타입은 `permissionResolver`/`contracts`로 이전 | 파일 삭제, 타입체·테스트 통과, 미참조 |
| **W2** | A | `done` | Codex/Grok `permissionSource` CLI help probe → `modes/shared/cliHelpCatalog` (또는 동등 공용 모듈) | 동작 동일, 중복 harvest/identity 제거, 테스트 통과 |
| **W3** | A | `done` | `CustomMode`를 Claude env 훅으로 흡수 (또는 사이드카 프로필로 예약하고 중복 제거) | `custom` UX 유지, 복제 listResumable/capabilities 감소 |
| **W4** | A | `done` | `interactionRouter.ts` 파일 분할 (agent/mode/config/wizard/resume/folder) — **동작 동일, 공개 API 유지** | 단일 god-file 해소, 테스트 통과 |
| **W5** | A | `done` | `UsageProvider` 인터페이스 + Claude/Codex/Grok 어댑터 정리 | wiring 분기 단순, 테스트 통과 |
| **W6** | B | `done` | `AgentEvent`/사이드카 RPC JSON Schema 또는 표 문서 (`claude-sidecar-protocol` 절 또는 별도 md) | 메서드·이벤트 kind 고정표 1장 |
| **W7** | C | `done` | TS 안 Claude 사이드카 프로세스 분리 + opt-in ClaudeMode 배선 + host.file reverse RPC; Discord E2E는 수동 | Discord Claude 스모크 동등 (E2E 수동) |
| **W8** | D | `done` | SwiftPM 골격 + Discord 라이브러리 spike + 로그인 hello | Swift 바이너리 접속 |
| **W9** | E | `done` | Swift 사이드카 클라이언트 + `!claude` Discord E2E (MVP). 풀 오케스트레이터/슬래시/스트리밍 편집은 W11 | `!claude` 메시지 → Claude 답글 |
| **W10** | F | `done` | Codex/Grok Discord·세션 배선 (c1/c2/c3). `/mode`·슬래시 파리티는 W11 | 3백엔드 `!claude`/`!codex`/`!grok` 텍스트 경로 |
| **W10b** | F | `done` | Grok ACP stdio 클라이언트 골격 (`Grok/AcpClient`). prompt stream·Discord 미연동 | ACP request/notify skeleton |
| **W10-c1** | F | `done` | Codex `!codex` Discord 배선: lib `codexTurnStep` + `CodexSessionBridge`(형제 브리지) + DabMain 분기 | `!codex` → Codex 답글, 단위테스트+build |
| **W10-c2** | F | `done` | `GrokAcpClient.sessionPrompt` + 순수 `grokUpdateStep`(텍스트) + fake transport 단위테스트 | Grok prompt stream (텍스트 델타 누적) |
| **W10-c3** | F | `done` | Grok `!grok` 배선 `GrokSessionBridge`(형제). sessionPrompt 반환=완료, onNotification 동기 fold→LockedBox | `!grok` → Grok 답글, build+grok-smoke |
| **W11** | G | `done` | UX·운영 패리티 (a·b1·b2·c·d·e·f1·f2·g·h 전부) | 세션 UX·권한·배포·HUD·라이브 스트림 |
| **W11-a** | G | `done` | 슬래시 인프라(DiscordBM) + `SessionRegistry` + 순수 `routeDecision` + `/agent start·close` + config seam | `/agent start`로 채널 바인딩 → 접두사 없이 대화 |
| **W11-b1** | G | `done` | 브리지 model·effort 실소비(config→client params) + `/agent start model·effort` 옵션 | model/effort 세션 반영, fake 검증 |
| **W11-h** | G | `done` | **provider 카탈로그 Swift 포팅** (W11-b2 선행). 3백엔드 모델/추론/권한을 **전부 라이브** 조회(하드코딩 고정 금지 — 백엔드만 고정). Claude=사이드카 **`claude.catalog` RPC**, Codex/Grok=`models_cache.json` 읽기, 추론=모델별 `supportedEffortLevels` 좁힘, 권한=백엔드별(Codex 샌드박스는 `codex --help` 동적). 상세 §14.10 | 카탈로그 라이브 조회 |
| **W11-b2** | G | `done` | `/agent start` 셀렉트 마법사(**W11-h 카탈로그 주입**). folder 클러스터 · dir:resume · reconfigure · A4D · **preset**: `ConfigStore.add/removeServerPreset` · folder→preset(R6 없음→backend) · pick 즉시 start · direct · delete mode · unavailable backend notice · 정상 완료 시 💾 프리셋 저장 모달(`PresetDraftRegistry`) · fromPreset/reconfigure는 저장 버튼 생략 | 마법사 UI + resume + reconfigure + A4D + preset |
| **W11-c1** | G | `done` | 권한 lib 토대: `PermissionGate`(deny-by-default·approver 확인) + custom_id + `resolveThreadPolicy` 포팅 + `ClaudeSidecarClient.sessionPermission` | 게이트·정책·custom_id (단위테스트) |
| **W11-c2** | G | `done` | 배선: 브리지 seam→게이트, DabMain 버튼/인터랙션, `/agent start` permMode, ownerId 통과. 보안 RV 통과 | 인터랙티브 승인 실동작 |
| **W11-f1** | G | `done` | 영속 저장 계층 `SessionStore`(actor, 원자 tmp+rename·0600·load-merge-save·손상→빈로드) + `PersistedSession`. 신규·고립·단위테스트(T8) | 저장/복원 원시계층 |
| **W11-f2** | G | `done` | 재시작 1:1 재연결: backend-id 캡처 + lazy resume + 폴백 + 부팅 복원. 데드락(backend_id notify 레이스) 수정 후 `plan/swift-port` 병합(§14.3). T1–T9 병렬/직렬 171 PASS | 재연결 검증 완료 |
| **W11-d** | G | `done` | 라이브 슬래시 `/mode`·`/model`·`/effort`·`/mode perm`·`/stop`·`/clear`·`/agent resume·stats`. 바인딩 레이어(registry+store)·`clearChannel`(§14.6). reconfigure 팝업은 **W11-b2**. Claude 라이브 setModel RPC 미포함 | 세션 조작 슬래시 |
| **W11-e** | G | `done` | 배포: `install/uninstall.sh`(release 빌드+plist+run.sh 생성+launchctl) + `env.example`. PATH·cwd 함정 run.sh에서 해소, 토큰 0600 env | `bash scripts/install.sh` |
| **W11-g** | G | `done` | **사용량/HUD 패널 + 라이브 스트림**. slice1–4 ✅ · setModel displayName ✅ · **live stream embed ✅**: pure `formatStreamEmbed` + `StreamStatusHost`(1s debounce / tool force) + DabMain yellow "응답 중…" embed(interrupt 유지) · Claude `text`/`tool_use`/`progress` mid-turn. 상세 §14.9 | 패널 모든 정보 최신 표시 |
| **W12** | H | `done` | 레거시 TS 정책, 버전 호환 매트릭스, 루트 README/README.ko 마이그레이션 가이드 | Swift-first 설치·env·경로·호환표·잔여 명시 (100% 미주장) |

### 신규 WO — 2026-07-25 전수조사 반영 (Phase I~L, 상세 §15)

> 사용자 결정: 보안(W13) 최우선 → 라이프사이클(W14) → config(W15) → 기능누락(W16). 착수 시 각 WO는 개별 작업 문서(`docs/`) 생성.

| ID | Phase | 상태 | 작업 | 완료 조건 |
|----|-------|------|------|-----------|
| **W13** | I | `done` | **보안 하드닝(P0)** — 인가·confinement·audit. **범위: a·c·d**(b는 Q5=B로 보류). 커밋 `a004311` | 프로덕션 안전 |
| **W13-a** | I | `done` | 역할-티어 인가(`core/auth.ts`→lib) + `DabMain` msg/interaction 진입점 배선. deny-by-default·Administrator 승격·dmPolicy·projectAuth ACL | 무인가 실행 경로 0 |
| **W13-b** | I | `보류(Q5=B)` | 툴 allowlist/프로필(`permissionResolver.ts`·`autoAllowClaudeTools`) + Claude 기본 permMode `bypassPermissions`→`default`. **보류**: bypass 기본 유지 시 allowlist 소비처 없음(dead-code) → 사용자가 기본 `default`를 원할 때 재개(`docs/w13-security-hardening.md` 4장 부록) | allowlist 없는 자동승인 제거 |
| **W13-c** | I | `done` | 파일 realpath confinement(`sessionOrchestrator.ts:838-875`) **순수 헬퍼+테스트만**(Q4). 배선은 첨부 다운로드 경로 부재로 잠재 — 첨부 파이프라인 착수 시 브리지 send 전단에 결합 | 심링크 탈출 차단(헬퍼 준비) |
| **W13-d** | I | `done` | 감사 로그(`auditLog.ts`→append-only JSONL + secret redaction) **turn/denied만**(Q7=A; start/stop은 W14) | who/what 기록 |
| **W14** | J | `done` | 라이프사이클 정합 — SessionLifecycle + 3-bridge stop/interrupt + slash + channelDelete | stop/interrupt/정리 |
| **W14-a** | J | `done` | stop/stopAll/interrupt 실경로 — Claude `session.stop`/`session.interrupt`·Codex `turn/interrupt`(activeTurnId)·Grok dropClient(TS 1:1, ACP에 session/cancel 없음). `/stop`·`/stop-all`(admin)·`/agent close` 실 stop. 감사 action stop/interrupt | 백엔드 실제 종료·턴 취소 |
| **W14-b** | J | `done` | `onChannelDelete` → SessionLifecycle.stopChannel (guild only, DM skip; no binding → no-op) | 삭제 채널 잔존 0 |
| **W15** | K | `done` | 설정/상태 성숙(TS동일) | 3-계층 config |
| **W15-a** | K | `done` | 3-계층 config 이식(`ConfigStore`/`ConfigResolver`/`ConfigSchema`) — global→server→binding, 검증·0600·원자쓰기·corrupt→null, Authorizer server auth, `normalizeModeId` | 레이어링 config |
| **W15-b** | K | `done` | SessionStore ordered migrations(STATE_VERSION=2) + `archived`/`markArchived` + load `normalizeModeId` aliases + optional profile/projectAuth/createdAt; stop hard-remove 유지; restore/stopAll skip archived | version 마이그레이션 |
| **W16** | L | `doing` | 기능 완전누락(전수조사 A/B/D) — a~h **ship** · 폴리시 잔여(pin·locale·self-replace·S3) | UI/명령 파리티 |
| **W16-a** | L | `done` | **답변 다중메시지 청킹**(`format.ts:chunkMessage`→`DiscordText.chunkMessage`, 코드펜스 인지) + `DabMain` 성공/에러 순차 `createMessage`. `clip` 유지(단일 메시지 호출처용) | 2000자 초과 무손실 |
| **W16-b** | L | `done` | `/config` 설정 패널: admin 슬래시·역할 티어 RoleSelect+Save · defaults mode/**model**/**effort**/permMode autosave(server)·dmPolicy autosave(global)·**알림 서브패널**(enable+status channelSelect→`server.notifications`)·effective embed. **잔여**: locale select(행 예산) · **이미지/chromium 서브패널 = S3 defer** | 패널 동작 |
| **W16-c** | L | `done` | `/setup` 길드 채널 프로비저닝(컨트롤 채널+세션 카테고리+상태 채널, alreadyDone 가드) | A4D 셋업 |
| **W16-d** | L | `done` | `/doc` 문서 공유(사이드카 `host.file.share` 역RPC 배선, 5종 ShareErrorCode) | md 스레드 게시 |
| **W16-e** | L | `done` | 권한 **Always-Allow** 버튼 + always-allow 영속(`addAutoAllowClaudeTool`) | 3버튼 완성 |
| **W16-f** | L | `done` | **custom 백엔드**(`Backend.custom`+`!custom` route+persist+`ShellEnv` dotfile env + Claude path env-overlay; wizard/slash 포함) | custom UX |
| **W16-g** | L | `done` | 도구 스레드(`toolThread`/`turnThread`) + diff 뷰(`diffView`) + 상태 임베드(`statusEmbed`) + 상태채널 알림(`notifier`). **shipped**: pure formatters + TurnThreadRegistry/ToolThreadHandler/DiffViewHandler(fakes) + ToolActivityHost→Dab/Codex/Grok mid-turn + DabMain createThread/statusEmbed/SessionNotifier · **capabilities 게이팅**(`resolveCapabilities` backend←global←server←`DAB_CAPS`, toolThreads/fileDiff/streaming/usagePanel). **잔여**: pin status embed. **gap**: Codex parentByThread/collab child-thread · Grok plan/thought progress | 도구/상태 가시성 |
| **W16-h** | L | `done` | auto-update **shippable slice**: pure semver(`Version`) + npm registry 체크(`Registry`) + Yes/No 버튼 UI(`UpdateButton`) + `AutoUpdater` 오케스트레이터 + `SessionStore` autoUpdate meta(lastCheckAt/dismissedVersion) + `/update` 슬래시(admin) + ready 스케줄 + 컨트롤채널 프롬프트. **ponytail 잔여**: 바이너리 self-replace·서비스 재시작(승인 시 수동 설치 안내만). 설치 포트 DI로 후속 연결 가능 | 자동 업데이트 |

### 후순위 / 병행 가능 (큐 본선 아님)

| ID | 상태 | 작업 |
|----|------|------|
| S1 | `todo` | 주석 다이어트 (WHY만) — 파일 터치 시 국소 적용 |
| S2 | `todo` | 상태 없는 renderer 파일 병합 |
| S3 | `defer` | Chromium 스택 optional / Swift 1차 제외 |
| S4 | `todo` | `ModeConfigView`를 모드별 설정 합타입으로 (Swift 쪽에서 정리 권장) |

### 브랜치 전략

| 브랜치 | 용도 |
|--------|------|
| `plan/swift-port` | 본 설계 + Phase A~B 슬림화 (현재) |
| `feat/claude-sidecar` | W7 |
| `feat/swift-skeleton` | W8 |
| `feat/swift-claude-e2e` | W9 |
| `feat/swift-codex` / `feat/swift-grok` | W10 |

---

## 7. 완료 로그

| 날짜 | ID | 요약 |
|------|-----|------|
| 2026-07-23 | W1 | 스텁 3파일 삭제. `PolicyTier` → `permissionResolver.ts`. typecheck + 1141 tests PASS. RV PASS. |
| 2026-07-23 | W2 | `modes/shared/cliHelpCatalog.ts` 추출. Codex/Grok `permissionSource` thin wrapper. typecheck + 1141 tests PASS. |
| 2026-07-23 | W3 | `ClaudeMode`에 `name`+`prepareSession` 훅. `CustomMode` thin subclass. `CustomEnvSession` 삭제. typecheck + 1140 tests PASS. |
| 2026-07-23 | W4 | `interactionRouter.ts` → barrel + `interaction/{types,helpers,sessionLifecycle,slashCommands,components,modals,router}.ts`. 공개 API 유지. typecheck + 1140 tests PASS. |
| 2026-07-23 | W5 | `UsageProvider` 인터페이스 export. wiring deps: `usageService` + `usageByMode` 맵. Claude/Codex/Grok poller 내부 유지, 라우팅만 통합. typecheck + 1140 tests PASS. |
| 2026-07-23 | W6 | `CLAUDE_SIDECAR_PROTOCOL.md` 고정: NDJSON stdio, 메서드 표, AgentEvent kind 1:1, 권한·attach 역RPC. |
| 2026-07-23 | W7 | **slice1**: protocol server+client+tests. **W7b**: `ClaudeMode`/`CustomMode` `useSidecar` + shared `ClaudeSidecarClient` when `DAB_CLAUDE_SIDECAR=1` (one multi-session process). Default still in-process. host.file.* / Discord E2E still open. |
| 2026-07-23 | W7c | **host.file.attach / host.file.share reverse RPC**: SidecarServer `requestHost` + reversePending; SessionBridge wires sendFile/shareDocument; ClaudeSidecarClient handleReverseRpc + openModeSession file cbs; ClaudeMode openViaSidecar passes Discord sinks. Opt-in + reverse file RPC; Discord E2E manual. |
| 2026-07-23 | W8 | `swift/` SwiftPM: DiscordBM + executable `dab`. Token from `DISCORD_BOT_TOKEN`/`DISCORD_TOKEN`/argv. Gateway Message Content Intent; ready log on connect. `swift build` OK. |
| 2026-07-23 | W9 | **slice**: Swift `AgentEvent`+Envelope Codable, `ClaudeSidecarClient` (inject transport / Process spawn, NDJSON, ready wait, session.start/send/stop, sessions.list, host.file.* → unsupported). Unit tests + fake pipes (16). `dab sidecar-smoke` real Node. DiscordBM only on `dab` target. Discord channel path deferred **W9b**. |
| 2026-07-23 | W9b | **minimal Discord path**: `!claude <prompt>` → shared sidecar → per-channel session → text events → createMessage reply. Env: `DAB_CWD`, `DAB_PERM_MODE` (default `bypassPermissions`), `DAB_TURN_TIMEOUT_SEC`. No slash/permission UI/multi-mode. |
| 2026-07-23 | W10 slice1 | **Codex app-server scaffold**: `Codex/AppServerClient.swift` + `CodexSpawn.swift` (JSON-RPC NDJSON, initialize/thread/turn, notify, approval auto-accept). InMemory transport tests. `dab codex-smoke` (missing CLI → exit 0). Grok → **W10b**. No AgentMode/Discord. |
| 2026-07-23 | W10b | **Grok ACP stdio scaffold**: `Grok/AcpClient.swift` + `GrokSpawn.swift` (JSON-RPC NDJSON, initialize/session/new|load, notify, permission default-deny). InMemory transport tests. `dab grok-smoke` (missing CLI → exit 0). No prompt stream / AgentMode / Discord. |
| 2026-07-23 | docs | §0 진행 스냅샷 추가. 브랜치 `plan/swift-port` 커밋·푸시 시점 문서 고정. |
| 2026-07-24 | W10-c1 | Codex `!codex` Discord 배선. lib `codexTurnStep`(eventMapper.ts 근거 매핑) + `CodexSessionBridge`(DabSessionBridge 형제, 채널당 codex 프로세스). RV 반영: isClosed 재스폰 가드 + 초기화 실패 시 `close()`(고아 방지), 다채널 상주는 ceiling 주석 후 W11 defer. swift build ok · swift test **45** PASS. |
| 2026-07-24 | W10-c2 | Grok prompt stream. `GrokAcpClient.sessionPrompt`(session/prompt 응답=턴 종결) + 순수 `grokUpdateStep`(session/update agent_message_chunk→텍스트, `x.ai/` 접두사 포함). 완료/실패는 응답 기반(wire). 턴 타임아웃은 c3 브리지가 requestTimeoutMs로 소유. TS 원본으로 params·content.text 형태 대조 확인(coordinator). swift test **50** PASS. |
| 2026-07-24 | W10-c3 | Grok `!grok` 배선 `GrokSessionBridge`(CodexSessionBridge 형제). 완료=sessionPrompt 반환(블로킹), 텍스트=onNotification **동기 fold**→`LockedBox`(read-루프 happens-before로 무손실, RV 코드검증). `LockedBox` public화 재사용. c1 RV 교훈(isClosed 재스폰·초기화 실패 close) 선반영. 실물 grok 0.2.111 grok-smoke PASS. swift test **50** PASS. |
| 2026-07-24 | policy | **테스트 정책 변경**: "TS 1:1 복제 금지 → 계약+스모크만"을 폐기하고, Swift도 **브리지 포함 촘촘한 단위테스트**(TS 수준 커버리지) 채택. 후속 WO: 브리지를 라이브러리로 이동(테스트 가능화) + client 팩토리 DI + 브리지 단위테스트 + 최상위 `verify` 스크립트. |
| 2026-07-24 | fix | `runTurn` 게이트 **액터 재진입** 수정(Dab/Codex/Grok 3브리지 공통). 게이트 읽기↔설치 사이 await 제거로 동시 sessionPrompt+버퍼 교차오염 차단, defer `== task` 가드. 같은 채널 다중 턴 몰림 시 발생하던 결함(RV 발견). swift build ok · swift test **50** PASS. |
| 2026-07-24 | test-A | 브리지 3종을 라이브러리 `Bridges/`로 이동(테스트 가능화) + **client 팩토리 DI**(가짜 클라 주입, 기본=실제 spawn). `DiscordText`는 dab 잔류. DabMain·명령 동작 불변. |
| 2026-07-24 | fix | `DabSessionBridge.ensureClient`에 **isClosed 재스폰 가드 + connect 실패 close + 재스폰 시 stale 세션 정리(`sessions.removeAll`)** — Codex/Grok과 통일. 죽은 사이드카 영구먹통·고아 프로세스 방지. |
| 2026-07-24 | test-B | **브리지 단위테스트 전량 +21** (3브리지 × happy/직렬화+재진입회귀/재스폰/init실패정리/에러/타임아웃/누적특성). 결정론 `TurnGate`(sleep 없음), fake 입력 echo로 버퍼 격리, `maxConcurrent==1`로 재진입 회귀 고정. 타임아웃 DI(Codex/Dab)·reqTimeout(Grok). swift test 50→**71**. |
| 2026-07-24 | pivot | **전략 확정: 제품은 Swift, TS/npm은 참고용(추후 제거).** 테스트·검증 **Swift 전용**(`verify.sh` = swift build+test+스모크; TS 테스트 미실행). 명령 접두사 `!dab`→`!claude`. 단 **Claude용 얇은 Node 사이드카 1겹은 유지**(Agent SDK가 Node 전용 — 의도된 예외, 제거 안 함). **UX 정정: 접두사는 MVP 임시 — 실제 방식은 `/agent start` 마법사로 백엔드·모델·추론·권한 설정해 채널=세션 생성 후 대화(W11 이식 대상).** |
| 2026-07-24 | W11-a | 세션 기반 UX 토대. lib `SessionRegistry`(actor, 채널→`SessionConfig`) + 순수 `routeDecision`(접두사 우선 / 바인딩 라우팅 / usage / ignore) + `agentCommandSpec`(`/agent start·close`). DiscordBM 슬래시·인터랙션 네이티브(`onInteractionCreate`, ephemeral, 길드/글로벌 등록). DabMain 라우팅 리팩터(중복 핸들러 제거) + `runTurn(config:)` seam(미소비, W11-b). swift test 71→**79**. |
| 2026-07-24 | W11-b1 | 브리지 `SessionConfig` model·effort **실소비**: Claude `SessionStartParams(model/effort)`, Codex thread/start model + turn/start effort·model, Grok 팩토리 config-aware(`resolveGrokSpawn(model:effort:)`). `/agent start`에 model(free-text)·effort(choices) 옵션. permMode는 W11-c로 미룸(현 danger 유지). fake transport로 config→params 검증. swift test 79→**83**. |
| 2026-07-24 | W11-e | 배포/launchd(신규 파일만, Swift 소스 무변경 — c1과 병렬 구현). `swift/scripts/install·uninstall.sh` + `deploy/env.example` + swift/README Deploy 섹션. run.sh 래퍼가 PATH(homebrew/local/grok/cargo)·cwd(repo root, 사이드카 findRepoRoot) 함정 해소, plist는 설치 시점 절대경로, 토큰은 0600 env만(plist 미포함), env 부재 가드로 KeepAlive 루프 방지. release 빌드(118s)·`--dry-run` plutil-lint 검증. |
| 2026-07-24 | W11-c1 | 권한 lib 토대(신규 파일/고립, 브리지·DabMain 무변경). `PermissionGate` actor(continuation 기반, timeout→deny-by-default, approver=owner 확인, resolve no-op 가드) + 순수 `buildCustomId/parseCustomId`(`perm:<reqKey>:<action>`, reqKey=UUID) + `resolveThreadPolicy`(policy.ts 포팅) + `ClaudeSidecarClient.sessionPermission`(§3.4). 결정론 테스트(sleep 없음). swift test 83→**94**. |
| 2026-07-24 | W11-c2 | 권한 Allow/Deny 버튼 **실배선**. `PermissionGate` presenter + 세 백엔드 seam(Claude onEvent→`sessionPermission`, Codex `resolveThreadPolicy`+onApproval, Grok 조건부 `--always-approve`+onPermission), 승인자=세션 owner, `/agent start` perm 옵션. 보안 RV 통과(무승인 실행 경로 없음), nil-approver 하드닝. permMode 라이브 변경(재바인딩)은 W11-f. |
| 2026-07-24 | W11-f1 | 세션 영속 저장 계층. `SessionStore` actor(원자 tmp+rename·`0600`·**load-merge-save**로 타 키 보존 F3·손상/부재→빈로드 F4) + `PersistedSession`(backend/backendSessionId/cwd/…) + `Backend` Codable. 신규·고립, 브리지/레지스트리 무변경. 단위테스트 T8 +7. swift test 156→**163**. |
| 2026-07-24 | test-harden | 안정 모듈 P0/P1 테스트 **+56**(클라 timeout/failAll/error-res, NDJSON 프레이밍, parseEnvelope 에러분기, asParams/Result 파싱, AgentEvent 왕복, JSONValue, DiscordToken, clip). 리팩터: NDJSON `splitNDJSON`/`flushNDJSON` 추출, `DiscordText`→라이브러리. swift test 100→**156**. |
| 2026-07-24 | test-C | 최상위 `verify.sh` + `npm run verify`(TS typecheck+tests · Swift build+tests · 스모크 best-effort) + README Development 섹션. 한 명령 전체 검증. |
| 2026-07-25 | W13 | 보안 하드닝 a·c·d (`a004311`): Authorizer+AuthConfigStore, AuditLog(turn/denied), Confinement 헬퍼. b=Q5=B 보류. swift test **294** PASS. |
| 2026-07-26 | W16-a | `DiscordText.chunkMessage` (TS `format.ts` 1:1 — newline 우선 분할·코드펜스 close/reopen·fence-free join 동일). `DabMain` 성공/에러 경로 순차 다중 `createMessage`. `clip` 유지. 단위테스트 +6. |
| 2026-07-26 | W14 | 라이프사이클: 3-bridge `stop`/`interrupt`(Claude session.stop/interrupt · Codex turn/interrupt+activeTurnId · Grok dropClient=TS), `SessionLifecycle` stop/interrupt/stopAll, `/stop`·`/stop-all`(admin)·`/agent close` 실 stop, `onChannelDelete` guild-only. Grok ACP session/cancel 미존재 → TS dropClient. swift test **316** PASS. |
| 2026-07-26 | W14 RV | stopChannel/interruptChannel **항상 3 브리지** (prefix/rebind 누수 수정). Codex turnGen으로 late turn/start 좀비 activeTurnId 차단. ensure mid-stop epoch(Claude/Codex/Grok). stopAll guildId←store. swift test **320** PASS. |
| 2026-07-26 | W11-b2 slice1 | `/agent start` **셀렉트 마법사**(folder 없음). lib pure `ChannelWizard` SM(select=pending, Next=commit; applyBackend 리셋; effort skip; Back/Cancel) + `loadWizardOptionSource`←라이브 `providerCatalog` + `WizardRegistry` + DabMain 에페메럴 embed/StringSelect/버튼·owner gate·done 시 registry+store bind. cwd=`DAB_CWD` else home. 슬래시 start 옵션 제거(wizard-only). 잔여: DirectoryBrowser·모달·A4D 채널·preset·reconfigure. |
| 2026-07-26 | W11-b2 slice2 | pure `DirectoryBrowser`(TS parity: into/up/here·goTo·dot-last sort·cap25·allowedRoots confine/unbounded) + `ChannelWizard` first step=`folder`(dir:here→backend). DabMain 브라우저 start=`DAB_CWD`/home unbounded. button `disabled` for dir:up. 모달/native/panel/create/resume/A4D/preset 미포함(ponytail). 단위테스트 DirectoryBrowser+wizard folder. |
| 2026-07-26 | W11-b2 slice3 | folder 클러스터 완성: `FolderPanel`(osascript choose folder·escapeAppleScript·injectable `PanelRunner`·timeout SIGKILL·FolderPanelBusy) + `DirectoryBrowser` dir:create/manual/[panel] 버튼·`createChild`+`isSafeFolderName` + DabMain showModal(dir:create/manual)·modalSubmit mkdir/goTo·dir:panel defer+native pick. **잔여**: resume·A4D channel·preset·reconfigure. 단위테스트 FolderPanel+create/goTo. |
| 2026-07-26 | W16-e | Always-Allow 3버튼(Allow/Always-Allow/Deny) + `perm:<reqKey>:always` + `PermissionDecision.always`(`backendBehavior`→allow). DabMain peek→`addAutoAllowClaudeTool` 영속·audit. 3 브리지 host-side auto-allow skip + Claude `session.start`에 `autoAllowClaudeTools` 전달. 단위테스트 AlwaysAllow+gate+bridge. swift test **435** PASS. |
| 2026-07-26 | W16-f | **custom 백엔드** TS 파리티: `Backend.custom` + `routeDecision` `!custom` + `ShellEnv`(`shellEnv.ts` 1:1 regex allow-list) + `DabSessionBridge` prepareSession env-overlay(`ANTHROPIC_MODEL` 우선·dangerous flag 경고) + SessionStore persist `.custom` + wizard/slash `Backend.allCases`·`customBackendLabel`. catalog=Claude. swift test **480** PASS. |
| 2026-07-26 | W16-d | `/doc path:` 문서 공유. lib `DocumentShare`(5종 ShareErrorCode·load/validate·bodyMode·sink) + `DocumentShareHost` + slash `doc` + dab `postDocumentShare`(createThread+attach+chunk body) + `ClaudeSidecarClient` `host.file.share`/`host.file.attach` 역RPC + DabSessionBridge onFileShare 배선. 워크스페이스 밖 경로 허용(TS 1:1; `escape` 잔존·미생산). 단위테스트 load/error/sink/host/spec + reverse RPC. |
| 2026-07-26 | W16-b | `/config` **minimal** 설정 패널. lib pure `ConfigPanel` SM(역할 pending→Save server auth · backend/permMode server autosave · dmPolicy global autosave · effective embed) + `ConfigPanelRegistry` + RoleSelect/StringSelect DiscordBM 매핑 + admin slash. **스킵(ponytail)**: model/effort/locale · notif/render 서브패널. 단위테스트 +12. |
| 2026-07-26 | W16-b residual | model/effort string-select autosave(server claudeModel|codexModel · claudeEffort|codexEffort) · 🔔 notif 서브패널(enable toggle + ChannelSelect→`server.notifications`) · DiscordBM channelSelect 매핑. **스킵**: locale(행 예산=dmPolicy) · **이미지/chromium=S3 defer**. |
| 2026-07-26 | **W12** | **문서 전용.** 루트 `README.md`/`README.ko.md`를 **Swift-first** 제품 경로로 개편: `swift/scripts/install.sh` · `dab` · 하이브리드 Claude 사이드카 · `~/.dab`(배포) vs `~/.discord-agent-bridge`(config/state) · npm TS→Swift 마이그레이션(env·state 분리·`DAB_CLAUDE_SIDECAR` 의미) · **호환 매트릭스**(100% 미주장·잔여 명시). §0 스냅샷·W12=`done`·다음 잔여 큐 갱신. 코드 변경 없음. |
| 2026-07-26 | interrupt UI | pure `InterruptButton`(`buildInterruptId`/`parseInterruptId`/`buildInterruptButton`) + 단위테스트. `DabMain` 턴 중 "응답 중…"+⏹️ 중단 컨트롤 메시지(종료 시 disabled) · components `interrupt:<g>:<c>` → drive auth → `SessionLifecycle.interruptChannel`(unbind 없음) · ephemeral followUp. 풀 스트림 임베드는 W11-g 잔여. |
| 2026-07-26 | W11-b2 reconfigure | `/mode backend` **다른 백엔드** → reconfigure 팝업(TS R1/R4). `ChannelWizard` `entry`/`kind`/`isReconfigure` · firstStep=model · back 첫 단계=cancel · 제목/1–3/3·"✅ 전환". 동일 백엔드=기존 `rebindBackend`. confirm=`SessionLifecycle.reconfigureBinding`(stop 3브리지+same channel model/effort/perm) + ephemeral switched + public freshContext. 단위테스트 SM reconfigure + lifecycle. 잔여: A4D·preset. |
| 2026-07-26 | W11-b2 A4D | `/agent start` 마법사 **done(start path)** → `resolveSessionChannelId`(`createSessionChannel` under server `sessionsCategoryId`) · registry+store bind **새 채널 id** · ephemeral `세션 채널 생성됨: <#id>` · 새 채널 intro+statusEmbed. reconfigure 경로 불변(same channel). provisioner 없음·카테고리 없음·create 실패 → 원 채널 fallback. pure `sessionChannelName`/`createSessionChannel` 기존 + resolve 단위테스트(fake provisioner). **잔여:** preset. |
| 2026-07-26 | W11-b2 preset | server preset pick/save (TS parity). `ConfigStore.addServerPreset`/`removeServerPreset`(read-after-write 3회) · `ChannelWizard` step=`preset` · pick seed+done · direct · delete · backendAvailable · `launchedFromPreset` · DabMain 로드/삭제 콜백 · done→`PresetDraftRegistry`+💾 버튼·`preset.name` 모달. 단위테스트 ConfigStore+wizard preset. **W11-b2=`done`**. |
| 2026-07-26 | W11-g slice4 | tools/subagent HUD: pure `TurnToolStat`/`SubagentRun`/`TurnToolStatsAggregator` + `buildToolsValue`/`buildAgentsValue`/`formatSubagentRunDuration` · `UsageEmbedExtras.tools/agents` · Claude `DabSessionBridge` tool_use/result/subagent_result → `TurnResult` · DabMain 턴 후 `buildUsageEmbed` 게시 + interrupt finalize `🛠️ N`. 단위테스트 aggregator/embed/bridge. |
| 2026-07-26 | W11-g live stream | pure `formatStreamEmbed` + `StreamStatusHost`(1s debounce / tool force) · DabMain yellow "응답 중…" embed + interrupt · Claude mid-turn text/tool/progress · finalize collapse. W11-g=`done`. |
| 2026-07-26 | W16-g residual | **Codex·Grok mid-turn tool 활동**: pure `codexToolEvents` (commandExecution/fileChange/mcp/webSearch/collab/subAgent) + `grokToolEvents` (tool_call/tool_call_update terminal) · Codex/Grok bridges → `TurnToolStatsAggregator` + `ToolActivityHost` (resetTurn/dispose) · spawnAgent pairing. **gap:** Codex parentByThread · Grok plan/thought. |
| 2026-07-26 | W16-g capabilities | pure `resolveCapabilities`(backend←global←server←`DAB_CAPS`) + ToolActivityHost 게이팅 + DabMain StreamStatus/usage post 가드 · Config optional capabilities. TS RendererDispatcher 정렬(toolThreads/fileDiff/streaming/usagePanel). |
| 2026-07-26 | docs snapshot | **W11=`done`** · **W11-g=`done`**(live stream 포함) · **W11-b2=`done`**. §0 잔여 = W16 폴리시(pin status·locale·self-replace) · W16-g gap · W13-b 보류 · host.file/S3/Linux·Windows. 코드 변경 없음. |
| 2026-07-26 | host.file.attach | **host.file.attach Discord 업로드**. lib `FileAttach`(`attachFileConfined`/`resolveConfinedAttachPath`·cwd 감금) + `FileAttachHost` + dab `postFileAttach`(createMessage files) + `DabSessionBridge` `onFileAttach` 배선. 단위테스트 path/host + reverse RPC. |

---

## 8. 모듈 맵 (TS → Swift 목표)

| 현재 TS | Swift / 잔존 | 비고 |
|---------|--------------|------|
| `core/contracts` | `DABCore` | P0, kind 고정 |
| `core/sessionOrchestrator` 등 | `DABCore` | P0 |
| `discord/*` | `DABDiscord` | W4 후 옮기기 쉬움 |
| `modes/codex` | Swift | W10 |
| `modes/grok` | Swift | W10 |
| `modes/claude` | 사이드카 + Swift 클라이언트 | W7, W9 |
| `modes/custom` | Claude env / 사이드카 프로필 | W3 |
| `service/*` | launchd 우선 | W11 |
| `discord/render/*` | optional | S3 |

---

## 9. 사이드카 프로토콜 (상세는 W6에서 확정)

초안만 유지. W6에서 필드 단위로 고정.

| method | 방향 | 역할 |
|--------|------|------|
| `session.start` | → | cwd, model, permMode, effort… |
| `session.resume` | → | + sessionId |
| `session.send` | → | text, files |
| `session.interrupt` | → | 턴만 취소 |
| `session.stop` | → | 세션 종료 |
| `session.permission` | → | allow/deny |
| `sessions.list` | → | cwd 기준 resumable |
| `event` | ← | AgentEvent |
| `error` | ← | 프로토콜/세션 오류 |

---

## 10. Discord Swift 라이브러리 (W8 spike)

필수: Message Content Intent, slash+components, embed/첨부/스레드, 채널 CRUD, roles.  
Spike: **버튼 + 스레드 3일 내** 되면 채택.

---

## 11. 리스크

| 리스크 | 대응 |
|--------|------|
| Claude SDK 변경 | 사이드카 버전 고정 + 스모크 |
| Discord Swift 미비 | W8 조기 spike |
| 이중 프로세스 디버깅 | 사이드카 로그를 메인 스트림에 합류 |
| god-file 포팅 | W4 선행 |
| 테스트 커버리지 | 브리지 포함 촘촘한 단위테스트 (2026-07-24 정책 변경) |

---

## 12. 다음 실행

상단 [§0 현재 진행 상황](#0-현재-진행-상황-스냅샷) 이 권위 있는 “지금 어디인지”다.

**큐 헤드:** W16 폴리시 잔여(pin status · locale · self-replace) · W16-g gap(선택) · W13-b(보류). **W11=`done`**(b2·g 포함).

---

## 13. 산출물 경로 인덱스

| 경로 | 설명 |
|------|------|
| `SWIFT_PORT_PLAN.md` | 본 설계·큐·진행 스냅샷 |
| `CLAUDE_SIDECAR_PROTOCOL.md` | Host↔Claude 사이드카 NDJSON v1 |
| `src/sidecar/claude/` | Node 사이드카 서버 |
| `src/modes/claude/sidecarClient.ts` | TS Host 사이드카 클라이언트 |
| `src/discord/interaction/` | 분할된 interaction 라우터 |
| `src/modes/shared/cliHelpCatalog.ts` | Codex/Grok CLI help 공용 |
| `swift/` | SwiftPM 패키지 (`dab` + library) |
| `swift/Sources/DiscordAgentBridge/Sidecar/` | Swift Claude 사이드카 클라이언트 |
| `swift/Sources/DiscordAgentBridge/Codex/` | Codex app-server 클라이언트 골격 |
| `swift/Sources/DiscordAgentBridge/Grok/` | Grok ACP 클라이언트 골격 |
| `swift/Sources/DiscordAgentBridge/Bridges/` | Dab/Codex/Grok 세션 브리지 |
| `swift/Sources/DiscordAgentBridge/Session/` | SessionRegistry·SessionLifecycle·BindingUpdate·SlashCommandSpec·**SessionStore**·**ChannelWizard**+**DirectoryBrowser**+**FolderPanel**(b2 slice3)·Auth/Audit/Confinement |
| `swift/scripts/`, `swift/deploy/` | launchd 배포(W11-e) |

---

## 14. 핸드오프 (2026-07-24 세션 종료 — 다음 세션은 여기부터)

### 14.1 현재 상태 (한 줄)
`plan/swift-port` **W11=`done`**(b2 folder·resume·reconfigure·A4D·preset · g HUD·setModel·live stream) + **W12 문서 완료** + W16-a~h ship(config model/effort/notif · Codex/Grok mid-turn tool · capabilities). **다음 기능 잔여** = W16 폴리시(pin status·locale·self-replace) · W16-g gap · W13-b(보류). **100% 패리티 아님.**
### 14.2 ⚠️ 반드시 먼저 읽을 것 — 테스트 실행법
**`swift test`를 그냥 돌리면 hang 한다.** 원인: SourceKit 백그라운드 인덱서가 `swift/.build`에 index-build를 돌리며 SwiftPM 락을 점유 → `swift test`가 락 대기로 무한 hang(코드 문제 아님). 증상: `swift build`는 되는데 `swift test`가 무출력으로 멈춤, `rm -rf .build`가 "Directory not empty"로 실패.
**해결: 격리 빌드 경로로 실행하라.**
```bash
swift test --package-path swift --scratch-path /tmp/dab-ci
swift build --package-path swift --scratch-path /tmp/dab-ci
```
(clean f1은 이 방법으로 0.2초에 완주 확인.) `verify.sh`도 이 옵션을 쓰도록 갱신하면 좋다(TODO).

### 14.3 W11-f2 (재시작 1:1 재연결) — ✅ 완료, `plan/swift-port` 병합됨
- 내용: 브리지 backend-id 시점 캡처→SessionStore 저장, lazy resume(start 대신 resume)+실패 폴백, 부팅 라우팅 복원(`Session/SessionPersist.swift` 글루), 세 브리지+DabMain 배선. wip 커밋 `664af25` + 데드락 수정 `ab67bf7`을 merge `385aff6`으로 병합.
- **데드락 근본 원인(해결)**: continuation 미재개가 아니라 **`ClaudeSidecarClient`의 레이스**였음. `session.start` 응답 직후 도착하는 `session.backend_id` notify가 `registerSessionHandlers`(응답 수신 후 실행)보다 read 루프에서 먼저 처리되면 핸들러 nil → `onBackendId` 유실 → `backendSessionId` 미영속 → 테스트 t1의 `while ...==nil { await Task.yield() }` 무한 spin. **병렬 실행 시** 이 spin이 협력 스레드풀을 고갈시켜 전 스위트가 정확히 163에서 hang(직렬/단독은 통과 → "플래키"로 보였음, 14.4의 f1 1건 실패도 동일 근본).
- **수정**: 핸들러 미등록 시 backend id를 `state.pendingBackendIds`에 버퍼링하고 `registerSessionHandlers`에서 replay(실제 사이드카에도 존재하는 레이스이므로 클라이언트 계층 교정). 
- **검증**: `swift test --scratch-path /tmp/dab-ci` **병렬 5회 연속 171 PASS**(hang 없음, 각 ~0.23s) + `--no-parallel` 171 PASS. T1~T9 전부 통과.

### 14.4 알려진 이슈
- ~~clean f1 격리 실행 시 1건 실패~~ → **해결**: 14.3의 backend_id 레이스와 동일 근본(병렬 스케줄 타이밍 의존). 수정 후 병렬/직렬 모두 171 PASS로 재현 안 됨.
- **`DabSessionBridgeTests.serializationReentrancyIsolation()` 플래키 (미확인, W11-h WO-4 중 관측)**: 부하 상태(동시 빌드)에서 12회 중 ~2회 실패 관측. **W11-h와 무관**(순수 신규 파일). 단 f2 데드락-수정 직후엔 병렬 5회 연속 171 PASS였음 → 부하 의존 타이밍 민감성 의심. **미확인**: 테스트 하네스 프래질(TurnGate release/waitReceived 시퀀싱)인지, 브리지 직렬화(hardening 2026-07-24 fix 이후)의 실제 재진입인지 특정 필요. 다음 여유 시 격리 반복 실행으로 재현·근본 판정.

### 14.5 W11-f2 설계 요지 (재연결 — 재구현/수정 기준)
- **영속(f1 완료)**: `SessionStore`(actor, 원자 tmp+rename·0600·load-merge-save·손상→빈로드). 채널→`PersistedSession{backend,backendSessionId,cwd,guildId,ownerId,model,effort,permMode}`.
- **backend-id 캡처(핵심 F7)**: Claude=`onBackendId` notify(비동기!), Codex=`threadStart` 반환, Grok=`sessionNew` 반환 — 확정 즉시 `store.upsert`.
- **lazy resume**: 브리지 ensure 경로에서 저장된 backendSessionId 있으면 start 대신 **resume**(Claude `sessionResume`/Codex `threadResume`/Grok `sessionLoad`), 채널당 직렬 큐 안에서(중복재개 방지).
- **폴백**: resume 실패→새 세션 start+사용자 고지+새 id 저장. (여기서 continuation 미재개 hang 나기 쉬움 — 점검.)
- **부팅**: DabMain onReady가 `store.load()`→SessionRegistry 라우팅 복원(스폰 X). `/agent start` bind 시 store에도 스텁 저장. **SessionRegistry는 순수 유지, persist/restore는 DabMain 소유(옵션 A 확정).**
- **검증 T1~T9**: T1=재시작 시뮬(같은 store 공유 새 브리지+새 fake)에서 fake가 **동일 backendSessionId로 `session.resume`** 받는지(=start 아님) 단언. T3 비동기 id, T4 폴백, T6 model/effort 캐리, T7 중복재개 1회, T9 라우팅 복원.
- TS 근거: `src/core/sessionOrchestrator.ts`(resumeAll/onSessionIdReady/send 재활성화), `channelRegistry.ts`(load-merge-save), 실패모드 F1–F10(§ 조사).

### 14.6 W11-d의 `/clear` 설계 요지 (사용자 강조: 설정 이어짐)
- TS `/clear` = 백엔드-중립 **stop→같은 config로 start**(backend/cwd/model/effort/permMode 보존, backendSessionId만 새로).
- Swift(lazy): `/clear` = **① 브리지 라이브 세션 드롭(백엔드 stop)** + **② store의 backendSessionId만 nil(config 유지)**. → 다음 메시지가 **동일 config로 fresh start**(resume 아님). **둘 다** 해야 함(하나만 하면 옛 컨텍스트로 resume되어 clear 안 됨).
- 각 브리지에 `reset(channelId:)` 추가(라이브 핸들 드롭+stop) + DabMain `/agent clear` 서브커맨드. SessionRegistry 무변경.
- 검증 T-clear-1(핵심): `/clear` 전후 턴의 client params 비교 → **model/effort/permMode 동일, backendSessionId만 변경**. T-clear-2 resume 아닌 start, T-clear-5 기본값 폴백 금지(회귀 가드).
- **f2 이후 직렬**(같은 파일 수렴). `/model`·`/effort`는 별개(라이브 in-place `setModel`/`setEffort`, 세션 유지 — `/clear`와 혼동 금지).

### 14.7 남은 큐 (순서)
1. ~~**W11 전부**~~ ✅ · ~~**W12**~~ ✅ · ~~**W16 ship**~~ ✅ (b model/effort/notif · g mid-turn+capabilities · h 체크 UI)
2. **W16 폴리시 잔여** — pin status embed · `/config` locale · auto-update 바이너리 self-replace · (S3) render.
3. **W16-g gap** (선택) — Codex parentByThread/collab · Grok plan/thought.
4. **W13-b** (보류) — 기본 permMode/`allowlist` when product default moves off bypass.
- 부수 TODO: host.file Discord 업로드 · Linux/Windows 서비스 · `verify.sh` `--scratch-path` · §14.4 플래키 근본 판정.

### 14.8 병렬 작업 교훈
신규파일/디스조인트 슬라이스(테스트 하드닝·배포·권한 lib)는 병렬로 잘 됐음. **단 여러 에이전트가 동시에 `swift build/test`를 돌리면 `.build` 락 경합**(+인덱서까지)으로 hang·지연 → 병렬 빌드는 **각자 `--scratch-path` 분리** 필수. 핫파일(브리지/DabMain) 배선은 직렬.

### 14.9 (기록) W11-g 사용량/HUD 패널 Swift 포팅 + 정보 최신화 — ✅ 완료
사용자 요구(2026-07-24): **Swift 포팅 패널에서 3백엔드(claude/codex/grok) 모두 모델 포함 모든 정보가 항상 최신**으로 표시. (TS는 참고용이라 TS 패널은 손대지 않음.)

- **완료**: slice1–4 + **live stream embed** ✅ · tools/subagent HUD · setModel displayName · DabMain 턴 후 패널 · **턴 중 yellow "응답 중…" embed** (`formatStreamEmbed` / `StreamStatusHost` · Claude text/tool/progress · interrupt 유지 · finalize `응답 완료 · 🛠️ N`). **W11-g=`done`**.
- **신선도 불변식(핵심)**: 모든 필드를 **렌더 시점 라이브 상태**에서 계산. 설정 변경 시 캐시된 값 재사용 금지(= TS의 래치 버그를 구조적으로 차단). 도구/서브에이전트 집계는 턴마다 리셋, git branch·경과시간도 매번 계산.
- **백엔드별 모델/컨텍스트 소스**:
  - **Claude**: 사이드카 `ClaudeSession`이 `context_usage.model`/`modelDisplayName` 생성 · `setModel` displayName latch 리셋 후 재해석 · Swift `/model`·`/effort` → `SessionLifecycle.updateBinding` → 라이브 RPC.
  - **Codex/Grok**: slice2 usage 패널(tokenUsage / `_meta.totalTokens`+contextWindow) + W16-g mid-turn tool 활동.

### 14.10 (기록) W11-h provider 카탈로그 Swift 포팅 — TS 파리티 (사용자 확정)
사용자 확정(2026-07-25): **`/agent start` 마법사(W11-b2)는 TS와 동일하게 백엔드·모델·추론·권한을 전부 라이브 셀렉트.** **하드코딩 고정값 금지 — 백엔드 목록(claude/codex/grok)만 고정.** 현 `SlashCommandSpec`의 static effort/perm 목록은 TS와 불일치라 폐기 대상. b2의 UI 이전에 이 카탈로그가 선행돼야 함.

- **TS 근거(포팅 원본)**: `src/core/providerCatalog.ts`(단일 진실원), `src/modes/codex/configSource.ts`·`permissionSource.ts`, `src/modes/grok/catalog.ts`·`configSource.ts`, 소비처 `src/discord/interaction/router.ts`(getModel/getEffortAutocomplete).
- **값별 소스 (백엔드별, 전부 라이브)**:
  - **모델**: Claude=SDK `supportedModels()` 프로브(15s 타임아웃·실패시 alias opus/sonnet/haiku 폴백·매 호출 재조회·in-flight 디둡). Codex=`~/.codex/models_cache.json`. Grok=`${GROK_HOME}/models_cache.json`. 각 모델에 `supportedEffortLevels` 동반.
  - **추론(effort)**: 백엔드 기본 레벨을 **선택 모델의 `supportedEffortLevels`로 좁힘**. Claude 시작-시엔 max 포함, 런타임(`/effort`)엔 max 제외. Codex/Grok은 모델별, 없으면 폴백.
  - **권한(perm)**: Claude=SDK PermissionMode 전체(default/acceptEdits/bypassPermissions/plan/dontAsk/auto), Codex=**`codex --help` 동적 샌드박스 모드**(현 Swift `CodexPolicy.resolveThreadPolicy`는 매핑만 있음 — 목록 조회는 미포팅), Grok=grok 권한모드.
- **⚠️ Claude 신규 사이드카 RPC 필요**: 마법사는 세션 생성 전에 모델 목록이 필요. TS는 별도 단명 `query()`로 supportedModels()를 프로브. Swift는 사이드카 너머라 **프로토콜에 `claude.catalog` 메서드 신설**(모델+권한모드+effort 한 왕복으로 실어 Swift에 Claude vocab 하드코딩 0 — Q1 결정) + 사이드카 핸들러(단명 프로브·15s·in-flight 디둡·alias 폴백은 사이드카에, 기존 `providerCatalog.ts` 재사용) + Swift 클라 메서드. **버전: v1 유지·additive**(새 메서드는 비파괴 — 프로토콜 규칙상 v 상향은 깨는 변경만; 구버전 사이드카는 `unsupported`→Swift alias 폴백으로 graceful. Q2 결정, 이전 "v 상향" 표기 정정). Swift·사이드카 이중 폴백.
- **Swift 기존 조각**: `Codex/CodexPolicy.swift`(permMode→approvalPolicy/sandbox 매핑 + `codexSandboxModes`)만 있음. 모델/추론/권한 목록 조회 계층은 전무.
- **테스트**: 카탈로그 파싱/폴백/좁힘은 순수 단위테스트(캐시파일 fake, 사이드카 fake), TS의 타임아웃·in-flight 디둡·폴백 동작 미러링.


---

## 15. 전수조사 (2026-07-25) — TS→Swift 누락 마스터 목록

TS 4영역(A 인터랙션/위저드 · B 렌더러/HUD · C 코어/권한/config · D 백엔드) 병렬 전수조사. 각 기능을 **TS 근거 → Swift 구현 → 문서 계획** 3축 대조. 사용자 결정(2026-07-25): TS 파리티 100% — ①보안 최우선 ②custom 포함 ③3-계층 config TS동일 ④folder 클러스터 전부.

### 15.1 완전누락 → 신규 WO 매핑 (문서에도 없던 것)

| 누락 (전수조사) | 영역 | 규모 | 신규 WO |
|---|---|---|---|
| 역할-티어 인가(deny-by-default·Administrator·dmPolicy·projectAuth) | A·C | L | **W13-a** |
| 기본 permMode `bypassPermissions`(전툴 자동승인) + 툴 allowlist/프로필 | C·D | M | **W13-b(보류 — Q5=B: bypass 기본 유지, `default` 원할 때 재개)** |
| 파일 realpath confinement | C | M | **W13-c** |
| 감사 로그(append+redaction) | C | M | **W13-d** |
| stop/stopAll 백엔드 미종료(프로세스 누수) + interrupt 실경로(Grok 취소 신설) | C·D | M | **W14-a** |
| channelDelete 고아 정리 | C | S | **W14-b** |
| 3-계층 config / 마이그레이션 / archived / normalizeModeId | C | L | **W15-a·b** |
| 답변 2000자 초과 truncate 유실(**버그성**) | B | S | **W16-a** |
| `/config` 패널 · `/setup` · `/doc` · `/stop-all` | A | L+M+M+S | **W16-b·c·d** (+`/stop-all`→W14-a) |
| 권한 Always-Allow 버튼 + 영속 | A·B | S~M | **W16-e** |
| custom 백엔드(shellEnv dotfile) | D | M | **W16-f** |
| 도구 스레드+diff·상태 임베드·상태채널 알림 | B | L | **W16-g** |
| auto-update 버튼+업데이터 | A·B | M | **W16-h** |
| Capabilities 렌더-게이팅 개념 | D | S | ✅ **W16-g 흡수** (`resolveCapabilities` + host 게이팅) |

### 15.2 이미 계획됨 (완전누락 아님) — 대부분 ship 완료
- ~~context_usage·usage 한도·도구/서브에이전트·thinking·progress·live stream~~ = **W11-g** ✅
- ~~`/model`·`/effort`·`/mode`·`/perm`·`/stop`·`/clear`·resume·stats~~ = **W11-d** ✅ · ~~reconfigure 팝업~~ = **W11-b2** ✅
- ~~마법사(카탈로그·folder·resume·A4D·preset)~~ = **W11-b2** ✅ · 카탈로그 = **W11-h** ✅

### 15.3 헛 포팅 방지 (TS 원본에도 없음 → 이식 제외)
- per-channel FIFO **큐 상한**(`queue.push`만·무한), 감사 로그 **회전**(append-only 영구), `maxSessionsPerUser`(config 필드만·집행 코드 0). ROADMAP.md의 개선 항목이지 현 TS 동작이 아니므로 파리티 대상 아님.

### 15.4 범위밖 defer (문서에 이미 명시 — 갭 아님)
- 테이블/mermaid→PNG 렌더(S3), Chromium 프로비저닝, fileAttach/fileDiff(§0). ~~streaming 실시간 편집~~ → **W11-g live stream embed**로 ship(풀 메시지 스트리밍 편집은 별도·미요구). ~~folder/preset/A4D/resume~~ → **W11-b2 범위로 완료**.

### 15.5 미확정 (착수 전 재확인) — 대부분 해소
- ~~preset·A4D·resume 위저드~~ ✅ (W11-b2). **잔여 미확정**: profile(권한 프로파일) UX · pin status embed 동작 세부 · auto-update 설치 포트 플랫폼 범위.
