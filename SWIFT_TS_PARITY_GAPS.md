# Swift ↔ TS 패리티 갭 백로그

> **목적:** TypeScript 원본과 Swift `dab`가 **같은 사용자 체감**을 내도록,  
> “고도화로 달라진 것”이 아니라 **미구현·누락**만 추적한다.  
> **기준:** TS 동작이 SoT. 언어/런타임 강제 차이만 예외로 허용.  
> **브랜치:** `plan/swift-port`  
> **작성:** 2026-07-26 · 전수 감사 기반  
> **진행:** 위→아래 우선순위. 항목 완료 시 상태만 갱신하고 커밋.

---

## 0. 분류 규칙

| 태그 | 의미 | 이 문서에 |
|------|------|-----------|
| **GAP** | 포팅 중 빠짐 / 미구현 / 배선 누락 | ✅ 포함 · 구현 대상 |
| **OK-DIFF** | 고도화·보안·언어 한계로 **의도적으로** 다른 동작 | 참고만 · 구현 강제 아님 |
| **DEFER** | 제품 결정으로 보류 (예: W13-b Q5=B) | 명시만 · 결정 변경 시 재개 |

### OK-DIFF (구현 대상 아님 — 참고)

| ID | 내용 | 이유 |
|----|------|------|
| OK-1 | Claude: TS 기본 in-process / Swift **항상** Node 사이드카 | SDK Node 전용 |
| OK-2 | 메시지 경로 `isAdministrator: false` 고정 | 게이트웨이 권한 부재 시 fail-secure (슬래시는 Admin 비트 사용) |
| OK-3 | Chromium: puppeteer warm browser vs headless Chrome CLI | Swift에 puppeteer 없음 · PNG 폴백 동일 |
| OK-4 | 상태 키 bare `channelId` (TS composite 가능) | Q3 결정 |
| OK-5 | 아키텍처: 풀 SessionOrchestrator → SessionLifecycle 얇은 레이어 | 동작 대체 완료 |
| OK-6 | 접두사 `!claude`/`!codex`/`!grok`/`!custom` | Swift **추가** 경로 (TS 바인딩 채널은 무접두사만) |
| OK-7 | W13-b 기본 `bypassPermissions` 유지 | 사용자 결정 Q5=B (**DEFER**) |

---

## 1. 진행 스냅샷

| 상태 | 개수 (대략) |
|------|-------------|
| `todo` | 아래 표 전부 (초기) |
| `doing` | 0 |
| `done` | 0 |

**권장 작업 순서:** P0 → P1 → P2. 한 항목(또는 밀접한 묶음) = 1 커밋.

---

## 2. P0 — 입력·피드백·관리 핵심 누락

| ID | 상태 | 기능 | TS 근거 | Swift 현실 | 완료 조건 |
|----|------|------|---------|------------|-----------|
| **G-P0-01** | `todo` | **메시지 첨부 → 에이전트 입력** | `messageRouter.ts` downloadAttachments · `fileDownload` 격리 · `TurnInput.files` · sidecar `session.send` files | 첨부 무시. host.file.attach(에이전트→채널)만 있음 | 메시지 attachments를 cwd 하위(예 `.dab-attachments`)에 저장 → `session.send` files 전달 · 탈출 경로 거부 · 단위 테스트 |
| **G-P0-02** | `todo` | **턴 리액션 ⏳/✅/❌** | `messageRouter.ts` REACT_WORKING/DONE/ERROR · EventBus 완료 시 swap | reaction 경로 없음 | 턴 수락 시 ⏳ · result ✅ · error ❌ · 권한 실패 best-effort |
| **G-P0-03** | `todo` | **Claude thinking 스트림 렌더** | `streamEmbed` thinking 경로 · `AgentEvent.thinking` | 이벤트 타입 있음 · DabSessionBridge stream에 미연결 | thinking 델타 → stream 임베드(또는 TS 동등 색/제목) · 답변 버퍼와 분리 |
| **G-P0-04** | `todo` | **`/agent close` 세션 채널 삭제** | `slashCommands.close` + `deleteSessionChannel` (A4D proj 채널, 컨트롤 제외) | stop+unbind만 | close 후 전용 세션 채널 best-effort 삭제 · 컨트롤/상태 채널 보호 |
| **G-P0-05** | `todo` | **`projectAuth` 인가 배선** | `auth.ts` projectAuth 교집합 · 바인딩 필드 | 타입/영속 가능 · DabMain 항상 nil | 바인딩/store projectAuth를 Authorizer에 전달 · 좁히기만 · 테스트 |

---

## 3. P1 — 운영·UX 패리티

| ID | 상태 | 기능 | TS 근거 | Swift 현실 | 완료 조건 |
|----|------|------|---------|------------|-----------|
| **G-P1-01** | `todo` | **IdleWatchdog** | `idleWatchdog.ts` 3분 무활동 공지 | 없음 | 턴 arm · 이벤트 note · result/error stop · 1회 공지 |
| **G-P1-02** | `todo` | **TranscriptFeed (progress 한 줄)** | `transcriptFeed.ts` progress 메시지 편집 | StreamStatusHost 임베드 위주 | caps.progress 경로에서 TS와 같이 상태 라인 또는 동등 가시성 (Codex progress) |
| **G-P1-03** | `todo` | **/model · /effort autocomplete** | client autocomplete + catalog | free-text only | Discord autocomplete → provider catalog 목록 |
| **G-P1-04** | `todo` | **/mode perm 프로필 해석** | `switchPerm` config.profiles 이름 → profile | raw string 위주 | 프로필 이름이면 profile, 아니면 permMode · 테스트 |
| **G-P1-05** | `todo` | **`/agent resume` 깊이** | re-attach + intro | store→registry 최소 re-bind | TS에 가깝게: intro/status · 라이브 세션 재연결 시도 |
| **G-P1-06** | `todo` | **favorites → browseRoots** | `app.ts` browseRoots: config.favorites | schema 보존만 · 위자드 unbounded | DirectoryBrowser/ChannelWizard에 favorites allowedRoots 주입 |
| **G-P1-07** | `todo` | **autoProvisionGuild** | Ready/GuildCreate 자동 채널 구조 | 수동 `/setup`만 | ready 또는 guild create 시 ensure (권한 있을 때) |
| **G-P1-08** | `todo` | **i18n en** | `i18n.ts` ko/en + locale | 한국어 하드코딩 위주 | locale=en 시 주요 슬래시/에러 문자열 en |
| **G-P1-09** | `todo` | **Codex usage 패널** | `CodexUsageService` rate limits | unsupported 취급 | 가능하면 app-server rate limit 조회 · 아니면 명시적 unavailable 라인 통일 |
| **G-P1-10** | `todo` | **usage HUD extras** | context_usage: clearableTokens, memoryFileCount, mcpServerCount, modelDisplayName | 부분 반영 | Claude 이벤트 필드 → usage embed 필드 |
| **G-P1-11** | `todo` | **Grok ACP 세부** | stream/`_meta`/mcpServers | AcpClient TODO | 실용 패리티 범위에서 stream/`_meta` 반영 |

---

## 4. P2 — 보조·희소

| ID | 상태 | 기능 | 비고 |
|----|------|------|------|
| **G-P2-01** | `todo` | FileDownload **UI** | TS도 UI 미배선 · 라이브러리 패리티만 필요 시 |
| **G-P2-02** | `todo` | CLI `--setup` / npm `service *` 동등 | install 스크립트로 대체됨 · 문서 동등성만 가능 |
| **G-P2-03** | `todo` | swift/README stale 문구 정리 | Codex “Not wired” 등 |
| **G-P2-04** | `todo` | stats queue depth / running | TS listActive 상세 |

---

## 5. 작업 로그

| 날짜 | ID | 커밋 | 요약 |
|------|-----|------|------|
| _(시작)_ | — | — | 문서 생성. 구현 대기. |

---

## 6. 다음 착수

1. **G-P0-01** 첨부 파일 입력  
2. **G-P0-02** 리액션  
3. **G-P0-03** thinking 렌더  
4. **G-P0-04** close 채널 삭제  
5. **G-P0-05** projectAuth  

완료 후 PLAN §0 / README 호환 매트릭스에 “패리티 갭 문서” 링크를 건다.
