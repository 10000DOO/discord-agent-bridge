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
| **검증** | `swift test --package-path swift --scratch-path /tmp/dab-ci` → **171** PASS (병렬/직렬 모두). ⚠️ 그냥 `swift test`는 인덱서 락으로 hang — **§14.2 필독** |

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
| **W11** | `doing` | **a·b1·c·e·f1·f2 완료**(f2=재시작 1:1 재연결, 데드락 수정 후 병합). 남은: 마법사(b2)·라이브 슬래시(d, incl. `/clear`). **→ §14 핸드오프 필독** |
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

1. ~~**W11-f** 세션 영속·재시작 1:1 재연결~~ ✅ 완료(f2 병합, §14.3)  
2. **W11-b2** 마법사 UI · **W11-d** 라이브 슬래시(`/model`·`/effort`·`/mode`·`/stop`·`/clear`)  
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
| **W11-b1** | G | `done` | 브리지 model·effort 실소비(config→client params) + `/agent start model·effort` 옵션 | model/effort 세션 반영, fake 검증 |
| **W11-h** | G | `todo` | **provider 카탈로그 Swift 포팅** (W11-b2 선행). 3백엔드 모델/추론/권한을 **전부 라이브** 조회(하드코딩 고정 금지 — 백엔드만 고정). Claude=사이드카 **`models.list` RPC 신설**(supportedModels 프로브), Codex/Grok=`models_cache.json` 읽기, 추론=모델별 `supportedEffortLevels` 좁힘, 권한=백엔드별(Codex 샌드박스는 `codex --help` 동적). 상세 §14.10 | 카탈로그 라이브 조회 |
| **W11-b2** | G | `todo` | `/agent start` 셀렉트 마법사(**W11-h 카탈로그를 셀렉트에 주입**, 옵션→인터랙티브 컴포넌트). 설계 `docs/w11b2-agent-start-wizard.md`(모델/추론/권한 섹션은 라이브 카탈로그 기준으로 갱신 필요) | 마법사 UI |
| **W11-c1** | G | `done` | 권한 lib 토대: `PermissionGate`(deny-by-default·approver 확인) + custom_id + `resolveThreadPolicy` 포팅 + `ClaudeSidecarClient.sessionPermission` | 게이트·정책·custom_id (단위테스트) |
| **W11-c2** | G | `done` | 배선: 브리지 seam→게이트, DabMain 버튼/인터랙션, `/agent start` permMode, ownerId 통과. 보안 RV 통과 | 인터랙티브 승인 실동작 |
| **W11-f1** | G | `done` | 영속 저장 계층 `SessionStore`(actor, 원자 tmp+rename·0600·load-merge-save·손상→빈로드) + `PersistedSession`. 신규·고립·단위테스트(T8) | 저장/복원 원시계층 |
| **W11-f2** | G | `done` | 재시작 1:1 재연결: backend-id 캡처 + lazy resume + 폴백 + 부팅 복원. 데드락(backend_id notify 레이스) 수정 후 `plan/swift-port` 병합(§14.3). T1–T9 병렬/직렬 171 PASS | 재연결 검증 완료 |
| **W11-d** | G | `todo` | 라이브 슬래시 `/mode`·`/model`·`/effort`·`/perm`·`/stop`·`/clear`·`/agent resume·stats` | 세션 조작 |
| **W11-e** | G | `done` | 배포: `install/uninstall.sh`(release 빌드+plist+run.sh 생성+launchctl) + `env.example`. PATH·cwd 함정 run.sh에서 해소, 토큰 0600 env | `bash scripts/install.sh` |
| **W11-g** | G | `todo` | **사용량/HUD 패널 Swift 포팅**(3백엔드). 브리지가 `context_usage`(+이번턴 도구/서브에이전트) 표면화 → 사용량 한도 조회(Claude 5h+주간+opus/sonnet·Grok 주간·Codex 없음) → 임베드 렌더러+게시. **신선도 불변식**: 모든 필드 렌더 시점 라이브, 캐시 재사용 금지. 상세 §14.9 | 패널 모든 정보 최신 표시 |
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
| 2026-07-24 | W11-b1 | 브리지 `SessionConfig` model·effort **실소비**: Claude `SessionStartParams(model/effort)`, Codex thread/start model + turn/start effort·model, Grok 팩토리 config-aware(`resolveGrokSpawn(model:effort:)`). `/agent start`에 model(free-text)·effort(choices) 옵션. permMode는 W11-c로 미룸(현 danger 유지). fake transport로 config→params 검증. swift test 79→**83**. |
| 2026-07-24 | W11-e | 배포/launchd(신규 파일만, Swift 소스 무변경 — c1과 병렬 구현). `swift/scripts/install·uninstall.sh` + `deploy/env.example` + swift/README Deploy 섹션. run.sh 래퍼가 PATH(homebrew/local/grok/cargo)·cwd(repo root, 사이드카 findRepoRoot) 함정 해소, plist는 설치 시점 절대경로, 토큰은 0600 env만(plist 미포함), env 부재 가드로 KeepAlive 루프 방지. release 빌드(118s)·`--dry-run` plutil-lint 검증. |
| 2026-07-24 | W11-c1 | 권한 lib 토대(신규 파일/고립, 브리지·DabMain 무변경). `PermissionGate` actor(continuation 기반, timeout→deny-by-default, approver=owner 확인, resolve no-op 가드) + 순수 `buildCustomId/parseCustomId`(`perm:<reqKey>:<action>`, reqKey=UUID) + `resolveThreadPolicy`(policy.ts 포팅) + `ClaudeSidecarClient.sessionPermission`(§3.4). 결정론 테스트(sleep 없음). swift test 83→**94**. |
| 2026-07-24 | W11-c2 | 권한 Allow/Deny 버튼 **실배선**. `PermissionGate` presenter + 세 백엔드 seam(Claude onEvent→`sessionPermission`, Codex `resolveThreadPolicy`+onApproval, Grok 조건부 `--always-approve`+onPermission), 승인자=세션 owner, `/agent start` perm 옵션. 보안 RV 통과(무승인 실행 경로 없음), nil-approver 하드닝. permMode 라이브 변경(재바인딩)은 W11-f. |
| 2026-07-24 | W11-f1 | 세션 영속 저장 계층. `SessionStore` actor(원자 tmp+rename·`0600`·**load-merge-save**로 타 키 보존 F3·손상/부재→빈로드 F4) + `PersistedSession`(backend/backendSessionId/cwd/…) + `Backend` Codable. 신규·고립, 브리지/레지스트리 무변경. 단위테스트 T8 +7. swift test 156→**163**. |
| 2026-07-24 | test-harden | 안정 모듈 P0/P1 테스트 **+56**(클라 timeout/failAll/error-res, NDJSON 프레이밍, parseEnvelope 에러분기, asParams/Result 파싱, AgentEvent 왕복, JSONValue, DiscordToken, clip). 리팩터: NDJSON `splitNDJSON`/`flushNDJSON` 추출, `DiscordText`→라이브러리. swift test 100→**156**. |
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

**큐 헤드:** W11-f (세션 재연결, 최우선) → W11-b2 (마법사)·W11-d (라이브 슬래시) → W12 (레거시·문서).

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
| `swift/Sources/DiscordAgentBridge/Session/` | SessionRegistry·PermissionGate·CodexPolicy·SlashCommandSpec·**SessionStore(f1)** |
| `swift/scripts/`, `swift/deploy/` | launchd 배포(W11-e) |

---

## 14. 핸드오프 (2026-07-24 세션 종료 — 다음 세션은 여기부터)

### 14.1 현재 상태 (한 줄)
`plan/swift-port` HEAD = **`a1829d9`**(W11-f2 병합 `385aff6` + 문서 갱신), **원격 푸시됨**·워킹트리 clean. W10 + W11-a/b1/c/e/f1/**f2** 완료. **다음(문서 순서) = W11-h(카탈로그, b2 선행) → W11-b2(마법사) → W11-d(라이브 슬래시) → W11-g(패널) → W12.**

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
1. **W11-h** — provider 카탈로그 Swift 포팅 (3백엔드 모델/추론/권한 라이브, 상세 §14.10). ← **다음 착수 (b2 선행)**
2. **W11-b2** — `/agent start` 셀렉트 마법사 UI (W11-h 카탈로그 주입).
3. **W11-d** — 라이브 슬래시 `/model`·`/effort`·`/mode`·`/perm`·`/stop`·**`/clear`**(14.6). (W11-h 카탈로그 재사용)
4. **W11-g** — 사용량/HUD 패널 Swift 포팅 + 정보 최신화 (상세 §14.9). W11-d 이후 권장.
5. **W12** — 레거시 TS 정리·호환·README.
- 부수 TODO: `verify.sh`에 `--scratch-path` 반영.

### 14.8 병렬 작업 교훈
신규파일/디스조인트 슬라이스(테스트 하드닝·배포·권한 lib)는 병렬로 잘 됐음. **단 여러 에이전트가 동시에 `swift build/test`를 돌리면 `.build` 락 경합**(+인덱서까지)으로 hang·지연 → 병렬 빌드는 **각자 `--scratch-path` 분리** 필수. 핫파일(브리지/DabMain) 배선은 직렬.

### 14.9 (기록) W11-g 사용량/HUD 패널 Swift 포팅 + 정보 최신화 — 까먹지 말 것
사용자 요구(2026-07-24): **Swift 포팅 패널에서 3백엔드(claude/codex/grok) 모두 모델 포함 모든 정보가 항상 최신**으로 표시. (TS는 참고용이라 TS 패널은 손대지 않음.)

- **현재 상태**: 패널은 TS 전용(`src/discord/renderers/usageEmbed.ts` + usage 서비스). Swift엔 `AgentEvent.contextUsage` **타입만** 있고(§4·capability `usagePanel=true`), 브리지가 이벤트를 버리며 임베드/한도조회 렌더 경로가 없음 → **순수 미포팅**.
- **포팅 범위**: (1) 브리지가 `context_usage` + 이번 턴 도구/서브에이전트 집계를 DabMain으로 **표면화**(현재 drop), (2) 사용량 **한도 조회**(Claude=5h+주간+opus/sonnet, Grok=주간만, Codex=없음), (3) **임베드 렌더러**(usageEmbed 포팅, 이모지 바) + DiscordBM 게시.
- **신선도 불변식(핵심)**: 모든 필드를 **렌더 시점 라이브 상태**에서 계산. 설정 변경 시 캐시된 값 재사용 금지(= TS의 래치 버그를 구조적으로 차단). 도구/서브에이전트 집계는 턴마다 리셋, git branch·경과시간도 매번 계산.
- **백엔드별 모델/컨텍스트 소스 차이(주의)**:
  - **Claude**: `context_usage.model`/`modelDisplayName`을 **영구 Node 사이드카의 `ClaudeSession`(`src/modes/claude/session.ts`)이 생성**(사이드카 서버 `src/sidecar/claude/sessionBridge.ts`가 재사용). ⚠️ **알려진 버그**: `setModel`이 `modelDisplayName`을 init 때 래치(`modelDisplayNameRequested`)로 **1회만** 해석 → `/model` 변경 후에도 옛 표시명 유지. **W11-d(Swift `/model`) + W11-g 착수 시 사이드카 쪽에서 함께 교정**: `setModel`에서 `this.modelDisplayName=null; this.modelDisplayNameRequested=false; this.captureModelDisplayName()`로 재해석. (이 파일은 영구 사이드카가 쓰는 KEEP 모듈이라 정당. Swift `/model`이 사이드카 `session.setModel`을 실제 호출해야 발현.)
  - **Codex/Grok**: Swift 브리지가 app-server/ACP 응답의 tokenUsage/totalTokens·모델에서 `context_usage`를 **직접 생성**해야 함(현재 Swift 브리지는 텍스트만 누적, 미생성).
- **착수 순서**: **W11-d 이후** 권장 — `/model` 라이브 변경과 "패널 모델 최신"이 한 흐름으로 맞물림.

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

