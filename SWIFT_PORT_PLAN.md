# Discord Agent Bridge — Swift 포팅 & 슬림화 설계

> 브랜치: `plan/swift-port`  
> 문서 갱신: **2026-07-23**  
> 대상: `discord-agent-bridge` (TypeScript / Node 20+ + Swift 병행)  
> 목표: **봇 본체 = Swift**, Claude Code만 얇은 **Node(TS) 사이드카**, 포팅 전에 TS **과설계 제거**

이 문서가 단일 기준 문서다. 포팅 아키텍처 · 슬림화 원칙 · 순서 있는 작업 큐 · 완료 기록을 모두 여기 둔다.  
사이드카 wire 상세: [`CLAUDE_SIDECAR_PROTOCOL.md`](./CLAUDE_SIDECAR_PROTOCOL.md) · Swift 사용법: [`swift/README.md`](./swift/README.md)

---

## 0. 현재 진행 상황 (스냅샷)

| 항목 | 상태 |
|------|------|
| **전체 단계** | Phase A~E **MVP 완료**, Phase F **클라이언트 골격**, Phase G~H 대기 |
| **브랜치** | `plan/swift-port` |
| **TS 기본 경로** | 기존 in-process Claude (변경 없음) |
| **TS 사이드카** | `DAB_CLAUDE_SIDECAR=1` opt-in |
| **Swift 봇** | `swift run --package-path swift dab` + `!dab <prompt>` |
| **검증** | TS tests PASS · `swift test` **40** PASS |

### 완료 (W1–W9, W10b)

| ID | 요약 |
|----|------|
| W1–W5 | TS 슬림화: 스텁 삭제, CLI help 공용, Custom→Claude 훅, interactionRouter 분할, UsageProvider |
| W6 | 사이드카 프로토콜 문서 (`CLAUDE_SIDECAR_PROTOCOL.md`) |
| W7 | Node Claude 사이드카 + Host 클라이언트 + host.file 역RPC + opt-in 배선 |
| W8 | SwiftPM + DiscordBM + gateway ready |
| W9 | Swift 사이드카 클라이언트 + Discord `!dab` → Claude 답글 (MVP) |
| W10b | Grok ACP stdio 클라이언트 골격 |

### 진행 중 / 부분 완료

| ID | 상태 | 남은 일 |
|----|------|---------|
| **W10** | `doing` | Codex app-server 클라이언트 골격 완료. **Discord AgentMode·세션 배선·`/mode` 패리티 없음**. Grok prompt stream 없음 |
| **W11** | `todo` | 슬래시, 권한 버튼, i18n, 스트리밍 편집, launchd, 이미지 렌더 등 UX 패리티 |
| **W12** | `todo` | 레거시 TS 정책, 버전 호환, 루트 README 마이그레이션 가이드 |

### 의도적으로 아직 없는 것

- 풀 SessionOrchestrator / ChannelRegistry Swift 포팅  
- Codex·Grok Discord 연동 및 멀티 백엔드 `/mode`  
- 권한 Allow/Deny 버튼 (Swift `!dab` 기본 `bypassPermissions`)  
- host.file.* 실제 Discord 업로드 (Swift 쪽; TS 사이드카 경로는 구현됨)  
- 기존 npm 봇 기능 100% 패리티  

### 빠른 실행

```bash
# TS 봇 — Claude 사이드카 opt-in
DAB_CLAUDE_SIDECAR=1 npm run dev

# Swift — Discord + !dab (repo root에서)
export DISCORD_BOT_TOKEN=...
swift run --package-path swift dab
# 채널: !dab hello

# 스모크
swift run --package-path swift dab sidecar-smoke
swift run --package-path swift dab codex-smoke
swift run --package-path swift dab grok-smoke
```

### 다음에 할 일 (우선순위)

1. **W10 계속** — Codex/Grok을 Discord·세션 레이어에 연결 (TS `appSession` / `acpSession` 대응)  
2. **W11** — 슬래시·권한 UI·설정·배포  
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
- 테스트 1:1 복제 (계약 테스트 + 스모크만)  
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
yagni:  Do not re-port full test volume
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
| **W9** | E | `done` | Swift 사이드카 클라이언트 + `!dab` Discord E2E (MVP). 풀 오케스트레이터/슬래시/스트리밍 편집은 W11 | `!dab` 메시지 → Claude 답글 |
| **W10** | F | `doing` | Codex app-server Swift 클라이언트 골격 완료. Discord/AgentMode 미연동. Grok은 W10b | `/mode` 3백엔드 (full) |
| **W10b** | F | `done` | Grok ACP stdio 클라이언트 골격 (`Grok/AcpClient`). prompt stream·Discord 미연동 | ACP request/notify skeleton |
| **W11** | G | `todo` | 슬래시·패널·i18n·이미지 렌더(후순위)·launchd·배포 | 패리티 체크리스트 |
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
| 2026-07-23 | W9b | **minimal Discord path**: `!dab <prompt>` → shared sidecar → per-channel session → text events → createMessage reply. Env: `DAB_CWD`, `DAB_PERM_MODE` (default `bypassPermissions`), `DAB_TURN_TIMEOUT_SEC`. No slash/permission UI/multi-mode. |
| 2026-07-23 | W10 slice1 | **Codex app-server scaffold**: `Codex/AppServerClient.swift` + `CodexSpawn.swift` (JSON-RPC NDJSON, initialize/thread/turn, notify, approval auto-accept). InMemory transport tests. `dab codex-smoke` (missing CLI → exit 0). Grok → **W10b**. No AgentMode/Discord. |
| 2026-07-23 | W10b | **Grok ACP stdio scaffold**: `Grok/AcpClient.swift` + `GrokSpawn.swift` (JSON-RPC NDJSON, initialize/session/new|load, notify, permission default-deny). InMemory transport tests. `dab grok-smoke` (missing CLI → exit 0). No prompt stream / AgentMode / Discord. |
| 2026-07-23 | docs | §0 진행 스냅샷 추가. 브랜치 `plan/swift-port` 커밋·푸시 시점 문서 고정. |

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
| 테스트 과다 복제 | 계약+스모크만 |

---

## 12. 다음 실행

상단 [§0 현재 진행 상황](#0-현재-진행-상황-스냅샷) 이 권위 있는 “지금 어디인지”다.

**큐 헤드:** W10 (Codex/Grok Discord·세션 배선) → W11 (UX 패리티) → W12 (레거시·문서).

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

