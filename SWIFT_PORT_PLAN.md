# Discord Agent Bridge — Swift 포팅 & 슬림화 설계

> 브랜치: `plan/swift-port`  
> 문서 갱신: **2026-07-24**  
> 대상: `discord-agent-bridge` (TypeScript / Node 20+ + Swift 병행)  
> 목표: **봇 본체 = Swift**, Claude Code만 얇은 **Node(TS) 사이드카**, 포팅 전에 TS **과설계 제거**

이 문서가 단일 기준 문서다. 포팅 아키텍처 · 슬림화 원칙 · 순서 있는 작업 큐 · 완료 기록을 모두 여기 둔다.  
사이드카 wire 상세: [`CLAUDE_SIDECAR_PROTOCOL.md`](./CLAUDE_SIDECAR_PROTOCOL.md) · Swift 사용법: [`swift/README.md`](./swift/README.md)

---

## 0. 현재 진행 상황 (스냅샷)

| 항목 | 상태 |
|------|------|
| **전체 단계** | Phase A~F **MVP 완료**(3백엔드 `!claude`/`!codex`/`!grok` 텍스트 경로), Phase G~H 대기 |
| **브랜치** | `plan/swift-port` |
| **TS 기본 경로** | 기존 in-process Claude (변경 없음) |
| **TS 사이드카** | `DAB_CLAUDE_SIDECAR=1` opt-in |
| **Swift 봇** | `swift run --package-path swift dab` + `!claude` / `!codex` / `!grok <prompt>` |
| **검증** | `bash verify.sh` (**Swift 전용**: `swift test` **79** PASS · 스모크 3종). TS는 참고용 — 테스트 안 함 |

### 완료 (W1–W10)

| ID | 요약 |
|----|------|
| W1–W5 | TS 슬림화: 스텁 삭제, CLI help 공용, Custom→Claude 훅, interactionRouter 분할, UsageProvider |
| W6 | 사이드카 프로토콜 문서 (`CLAUDE_SIDECAR_PROTOCOL.md`) |
| W7 | Node Claude 사이드카 + Host 클라이언트 + host.file 역RPC + opt-in 배선 |
| W8 | SwiftPM + DiscordBM + gateway ready |
| W9 | Swift 사이드카 클라이언트 + Discord `!claude` → Claude 답글 (MVP) |
| W10b | Grok ACP stdio 클라이언트 골격 |
| W10-c1 | Codex `!codex` Discord 배선 (텍스트 답글, 형제 브리지) |
| W10-c2 | Grok prompt stream: `GrokAcpClient.sessionPrompt` + 순수 `grokUpdateStep` (텍스트) |
| W10-c3 | Grok `!grok` Discord 배선 (`GrokSessionBridge`, 형제). 3백엔드 텍스트 경로 완성 |

### 진행 중 / 부분 완료

| ID | 상태 | 남은 일 |
|----|------|---------|
| **W11** | `doing` | **a 완료**(슬래시 인프라·`SessionRegistry`·`/agent start·close`). 남은: 마법사(b)·권한 버튼(c)·라이브 슬래시(d)·배포(e) |
| **W12** | `todo` | 레거시 TS 정책, 버전 호환, 루트 README 마이그레이션 가이드 |

### 의도적으로 아직 없는 것

- 풀 SessionOrchestrator / ChannelRegistry Swift 포팅  
- Codex·Grok Discord 연동 및 멀티 백엔드 `/mode`  
- 권한 Allow/Deny 버튼 (Swift `!claude` 기본 `bypassPermissions`)  
- host.file.* 실제 Discord 업로드 (Swift 쪽; TS 사이드카 경로는 구현됨)  
- 기존 npm 봇 기능 100% 패리티  

### 빠른 실행

```bash
# TS 봇 — Claude 사이드카 opt-in
DAB_CLAUDE_SIDECAR=1 npm run dev

# Swift — Discord + !claude (repo root에서)
export DISCORD_BOT_TOKEN=...
swift run --package-path swift dab
# 채널: !claude hello

# 전체 검증 (Swift 전용)
bash verify.sh

# 스모크
swift run --package-path swift dab sidecar-smoke
swift run --package-path swift dab codex-smoke
swift run --package-path swift dab grok-smoke
```

### 다음에 할 일 (우선순위)

1. **W11-b · W11-c** — `/agent start` 마법사(모델·추론·권한) · 권한 Allow/Deny 버튼  
2. **W11-d · W11-e** — 라이브 슬래시(`/mode`·`/model`·`/effort`·`/stop`·`/clear`) · launchd·배포  
3. **W12** — 레거시/문서/호환 매트릭스  

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
| **G** | UX·운영 패리티 (W11) | 위저드·서비스·배포 |
| **H** | 정리 (W12) | TS 메인 deprecate, 호환 매트릭스 |

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
| **W11** | G | `doing` | UX·운영 패리티 (a~e 분할) | 세션 UX·권한·배포 |
| **W11-a** | G | `done` | 슬래시 인프라(DiscordBM) + `SessionRegistry` + 순수 `routeDecision` + `/agent start·close` + config seam | `/agent start`로 채널 바인딩 → 접두사 없이 대화 |
| **W11-b** | G | `todo` | `/agent start` 셀렉트 마법사(모델·추론·권한) + 브리지 config 실제 소비 | 세션 설정 UI |
| **W11-c** | G | `todo` | 권한 Allow/Deny 버튼 (danger 기본값 대체) | 인터랙티브 승인 |
| **W11-d** | G | `todo` | 라이브 슬래시 `/mode`·`/model`·`/effort`·`/perm`·`/stop`·`/clear`·`/agent resume·stats` | 세션 조작 |
| **W11-e** | G | `todo` | launchd·배포·설정 영속화 | 운영 |
| **W12** | H | `todo` | 레거시 TS 정책, 버전 호환 매트릭스, README | 마이그레이션 가이드 |

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
| 2026-07-24 | test-C | 최상위 `verify.sh` + `npm run verify`(TS typecheck+tests · Swift build+tests · 스모크 best-effort) + README Development 섹션. 한 명령 전체 검증. |

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

**큐 헤드:** W11-b (`/agent start` 마법사) · W11-c (권한 버튼) → W11-d/e → W12 (레거시·문서).

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

