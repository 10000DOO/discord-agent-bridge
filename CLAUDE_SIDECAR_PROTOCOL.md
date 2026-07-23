# Claude Sidecar Protocol (W6)

> 상태: **v1 구현됨** (TS Host + Node sidecar + Swift client. 깨는 변경은 `v` 필드 올림)  
> 관련: [`SWIFT_PORT_PLAN.md`](./SWIFT_PORT_PLAN.md) (§0 진행 스냅샷), `src/core/contracts.ts`, `src/modes/claude/*`, `src/sidecar/claude/*`, `swift/Sources/DiscordAgentBridge/Sidecar/`  
> transport: **NDJSON over stdio** (1 line = 1 JSON object). 로컬 Unix socket은 동등 스키마로 확장 가능.

### 구현 매핑 (2026-07-23)

| 구성 | 경로 |
|------|------|
| Node 사이드카 서버 | `src/sidecar/claude/` |
| TS Host 클라이언트 | `src/modes/claude/sidecarClient.ts` |
| opt-in 배선 | `DAB_CLAUDE_SIDECAR=1` (`src/app.ts`) |
| Swift 클라이언트 | `swift/Sources/DiscordAgentBridge/Sidecar/` |
| host.file.attach/share | TS 경로 구현 (역RPC). Swift Host는 아직 unsupported 응답 |

---

## 1. 역할

| 프로세스 | 책임 |
|----------|------|
| **Host** (지금: Node 봇 / 이후: Swift) | Discord, orchestrator, 권한 UI, 채널 바인딩 |
| **Sidecar** (Node, Claude Agent SDK만) | `query` 세션, 이벤트 매핑, listSessions, canUseTool 대기 |

Host의 `ClaudeMode`는 사이드카 클라이언트일 뿐이며, 다른 모드와 같은 `AgentMode`/`ModeSession` 계약을 유지한다.

---

## 2. 프레이밍

- stdin → sidecar (Host 요청)  
- stdout → host (응답·이벤트·알림)  
- stderr → 로그 전용 (프로토콜 아님)  
- 인코딩: UTF-8, **한 줄에 JSON 하나** (pretty-print 금지)  
- 순서: 같은 `session`에 대해 이벤트는 발생 순 유지  

### 공통 봉투

```json
{
  "v": 1,
  "id": "optional-request-id",
  "type": "req | res | event | notify",
  "method": "string when req/res",
  "session": "sidecar-session-handle when applicable",
  "params": {},
  "result": {},
  "error": { "code": "string", "message": "string", "retryable": false },
  "event": {}
}
```

| 필드 | 필수 | 설명 |
|------|------|------|
| `v` | yes | 프로토콜 버전. 현재 `1` |
| `type` | yes | `req` / `res` / `event` / `notify` |
| `id` | req/res | Host가 붙인 요청 id. res가 동일 id로 응답 |
| `method` | req/res | 아래 메서드 표 |
| `session` | 세션 스코프 | `session.start` 결과가 준 핸들 (백엔드 sessionId와 별개일 수 있음) |
| `params` | req | 인자 |
| `result` | res 성공 | 결과 |
| `error` | res 실패 | 구조화 오류 |
| `event` | type=event | `AgentEvent`와 동일 스키마 |

---

## 3. 메서드 표 (고정)

| method | 방향 | 설명 | 대응 코드 |
|--------|------|------|-----------|
| `session.start` | → | 새 Claude 세션 | `ClaudeMode.start` / `ClaudeSession` ctor |
| `session.resume` | → | 기존 백엔드 sessionId로 재개 | `ClaudeMode.resume` |
| `session.send` | → | 유저 턴 | `ModeSession.send` |
| `session.interrupt` | → | 현재 턴만 취소 (세션 유지) | `ModeSession.interrupt` |
| `session.stop` | → | 세션 종료 | `ModeSession.stop` |
| `session.permission` | → | 툴 허용/거부 응답 | `PermissionDecision` |
| `session.setModel` | → | 라이브 모델 변경 (optional) | `ModeSession.setModel` |
| `session.setEffort` | → | 라이브 effort 변경 (optional) | `ModeSession.setEffort` |
| `sessions.list` | → | cwd 기준 resumable 목록 | `ClaudeMode.listResumable` |
| `host.file.attach` | ← notify 또는 역RPC* | attach_file MCP → Discord | `mcpFileTool` sendFile |
| `host.file.share` | ← notify 또는 역RPC* | share_document MCP | shareDocument |

\* 1차 구현: sidecar가 **req**를 Host로 보내고 Host가 **res** (역방향 RPC).  
   단순화 대안: sidecar stdout `type=notify` + Host 비동기 처리 (실패 시 툴 에러는 다음 턴에 반영 어려움) → **역RPC 권장**.

### 3.1 `session.start` params

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `cwd` | string | yes | 작업 디렉터리 |
| `guildId` | string | yes | Discord 컨텍스트 (로깅/attach 라우팅) |
| `channelId` | string | yes | 동일 |
| `ownerId` | string | no | 감사/멘션용 |
| `model` | string | no | SDK model |
| `effort` | string | no | reasoning effort |
| `permMode` | string | yes | SDK PermissionMode (`default` \| `acceptEdits` \| `bypassPermissions` \| `plan` \| `dontAsk` \| `auto` 등) |
| `config` | object | no | `ModeConfigView` 부분집합: `allowedTools`, `autoAllowClaudeTools`, `permissionTimeoutSec` |
| `env` | object | no | 서브프로세스 env 오버레이 (`custom` 모드) |

**result:**

| 필드 | 타입 | 설명 |
|------|------|------|
| `session` | string | 사이드카 로컬 핸들 (이후 호출에 사용) |
| `backendSessionId` | string \| null | SDK session id (init 전 null 가능; 이후 `notify.session_id`로 갱신) |

### 3.2 `session.resume` params

`session.start`와 동일 + `backendSessionId: string` (필수).

### 3.3 `session.send` params

| 필드 | 타입 | 필수 |
|------|------|------|
| `session` | string | yes (또는 봉투 `session`) |
| `text` | string | yes |
| `files` | `{ path: string, mime?: string }[]` | no — Host가 cwd 가둔 절대경로 |

**result:** `{ ok: true }` (수락/큐잉). 본문 스트림은 **event**로만.

### 3.4 `session.permission` params

| 필드 | 타입 | 필수 |
|------|------|------|
| `session` | string | yes |
| `requestId` | string | yes — `permission_request.id` |
| `behavior` | `"allow" \| "deny"` | yes |
| `message` | string | no |

### 3.5 `session.interrupt` / `session.stop`

params: `{ session }`. stop 후 해당 핸들로 추가 send 금지.

### 3.6 `session.setModel` / `session.setEffort`

params: `{ session, model?: string }` / `{ session, effort?: string }`.  
미지원이면 `error.code = "unsupported"`.

### 3.7 `sessions.list` params

| 필드 | 타입 | 필수 |
|------|------|------|
| `cwd` | string | yes |
| `limit` | number | no (default 25) |

**result:**

```json
{
  "sessions": [
    {
      "sessionId": "…",
      "cwd": "…",
      "label": "…",
      "updatedAt": "ISO-8601"
    }
  ]
}
```

`ResumableSession`과 동일.

### 3.8 역RPC: `host.file.attach` / `host.file.share`

Sidecar → Host **req**:

```json
{
  "v": 1,
  "type": "req",
  "id": "s-1",
  "method": "host.file.attach",
  "session": "…",
  "params": { "path": "/abs/path", "name": "optional" }
}
```

Host **res**: `{ "ok": true }` 또는 error.  
경로는 사이드카가 cwd 가둔 뒤 전달; Host는 채널로 업로드.

---

## 4. AgentEvent 스키마 (kind 고정 — contracts 1:1)

Host 렌더러는 기존 `RendererDispatcher`와 동일하게 kind만 본다. **이름 변경 금지.**

| kind | 필드 | 비고 |
|------|------|------|
| `text` | `text: string`, `delta: boolean` | 스트리밍 청크 |
| `thinking` | `text`, `delta` | |
| `tool_use` | `id`, `name`, `input`, `parentToolUseId?` | |
| `tool_result` | `id`, `ok`, `content`, `parentToolUseId?` | |
| `permission_request` | `id`, `toolName`, `input` | Host가 버튼 후 `session.permission` |
| `progress` | `label`, `detail?` | Claude는 거의 미사용 |
| `result` | `text?`, `costUsd?`, `tokensIn?`, `tokensOut?`, `durationMs?` | 턴 완료 |
| `context_usage` | `totalTokens`, `maxTokens`, `percentage`, `model?`, `modelDisplayName?`, `clearableTokens?`, `memoryFileCount?`, `mcpServerCount?` | |
| `subagent_result` | `taskId`, `status`, `summary`, `toolUseId?`, `durationMs?`, `toolUses?` | status: completed\|failed\|stopped |
| `error` | `message`, `retryable` | |
| `rate_limit` | `resetAt?`, `rateLimitType?`, `utilization?` | 에러 아님 |

### event 봉투 예

```json
{
  "v": 1,
  "type": "event",
  "session": "local-1",
  "event": { "kind": "text", "text": "Hello", "delta": true }
}
```

### notify (비요청 메타)

| method (notify) | payload | 설명 |
|-----------------|---------|------|
| `session.backend_id` | `{ backendSessionId }` | SDK init 후 실제 id 확정 시 |
| `sidecar.ready` | `{ v: 1 }` | 프로세스 기동 직후 1회 |
| `sidecar.shutdown` | `{ reason? }` | 종료 임박 |

---

## 5. 권한 흐름

```
Sidecar SDK canUseTool
    → event permission_request { id, toolName, input }
    → Host Discord Allow/Deny/Always
    → req session.permission { requestId: id, behavior }
    → Sidecar resolves canUseTool promise
```

타임아웃은 **Host** orchestrator/wiring이 담당 (deny-by-default).  
사이드카는 permission res가 올 때까지 해당 툴을 대기.

auto-allow 목록(`config.autoAllowClaudeTools`)은 사이드카 `makeCanUseTool`과 동일 규칙을 쓰거나, Host가 선허용 시 permission 없이 진행 — **1차는 사이드카가 기존 `permissions.ts` 로직 유지**, Host는 버튼만.

---

## 6. 세션 수명

```
start/resume → (events…) → send* → interrupt? → stop
list 은 세션 핸들 없이 호출 가능
```

- 한 사이드카 프로세스에 **다중 session 핸들** 허용 (채널 수만큼).  
- Host 크래시 시: 사이드카 고아 세션은 idle 타임아웃 또는 stdin EOF 시 전체 종료.  
- stdin EOF = 모든 세션 stop 후 process exit.

---

## 7. 오류 코드

| code | 의미 |
|------|------|
| `invalid_request` | 스키마/필수 필드 |
| `unknown_session` | 핸들 없음 |
| `unsupported` | setModel 등 미지원 |
| `sdk_error` | Claude SDK/CLI 실패 |
| `permission_timeout` | (Host 측; 사이드카는 대기) |
| `internal` | 기타 |

`retryable`은 기존 `AgentEvent.error.retryable`과 같은 의미.

---

## 8. Capabilities (Claude 고정)

Host는 사이드카 Claude 모드에 대해 현재와 동일한 capabilities를 선언한다:

```
streaming, thinking, toolThreads, permissionPrompts,
sessionResume, fileAttach, fileDiff, usagePanel = true
progress, transcript = false
permissionModes = SDK PermissionMode 전체
```

---

## 9. 구현 체크리스트 (W7)

- [ ] `packages/claude-sidecar` (또는 `sidecar/claude`) 엔트리: stdio 루프  
- [ ] 내부적으로 기존 `ClaudeSession` / `listResumable` / MCP tools 재사용  
- [ ] Host `ClaudeMode` → spawn + NDJSON 클라이언트  
- [ ] `custom` = 동일 사이드카 + `env` params  
- [ ] 단위: 가짜 stdio로 start→text event→stop  
- [ ] 통합: 기존 Discord 봇이 사이드카 경유로 Claude 세션  

---

## 10. JSON Schema (요약 — 이벤트 kind)

이벤트 본문(`event` 필드)은 TypeScript `AgentEvent` 유니온과 동등.  
기계 검증이 필요하면 W7에서 `zod` 스키마를 사이드카와 Host가 공유 패키지로 둔다.  
**이 문서의 표가 이름 권위(source of truth)이며, 코드 contracts와 불일치 시 contracts를 이 표에 맞춘 뒤 버전을 올린다.**

---

## 11. 버전

| v | 날짜 | 메모 |
|---|------|------|
| 1 | 2026-07-23 | 초안 고정 (W6) |
