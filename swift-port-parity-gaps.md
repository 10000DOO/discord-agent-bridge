# TS→Swift 포팅 패리티 감사 — 발견된 누락/차이 전수 목록

> 상태: `구현중` · 갱신: 2026-07-27 · 브랜치: `plan/swift-port` · 다음 액션: Critical 16건 전부 완료(전체 테스트 1027개 통과) — High(2장) 26건을 순서대로 WO 단위 실행 시작.
> ⚠️ 본문의 file:line은 드리프트할 수 있음 — 실행 전 반드시 심볼명으로 재확인할 것
> ⚠️ 기존 docs/*-parity.md 문서들은 이번 조사에서 **참고하지 않았음** — 전부 `src/`(TypeScript 원본)와 `swift/Sources/`(Swift 포팅본)를 직접 열어 대조한 결과만 기록함.

---

## 진행 상황 요약 (한눈에 보기 — 이 표만 최신 상태로 계속 갱신함)

### Critical (16건)

| # | 내용 | 상태 |
|---|---|---|
| C1 | Codex 생각중(thinking) 스트림 | ✅ 완료 (빌드+테스트 확인) |
| C2 | Codex 사용량 패널 | ✅ 완료 (빌드+전체테스트 확인) |
| C3 | Codex 동적 도구(파일첨부/문서공유) | ✅ 완료 (빌드+테스트 확인) |
| C4 | Codex 재개목록 SQLite 읽기 | ✅ 완료 (빌드+테스트 확인) |
| C5 | Grok MCP 파일첨부/문서공유 루프백 | ✅ 완료 (빌드+테스트 확인) |
| C6 | 첨부 이미지 실제 이미지로 전달 | ✅ 완료 (빌드+테스트 확인) |
| C7 | Grok 사용량 패널 | ✅ 완료 (빌드+전체테스트 확인) |
| C8 | Grok 재개목록 SQLite 읽기 | ✅ 완료 (빌드+전체테스트 확인) |
| C9 | Claude 권한 프로필(allowedTools) 배선 | ✅ 완료 (빌드+테스트 확인) |
| C10 | 부팅 시 세션 즉시 재연결 + 채널삭제 감지 | ✅ 완료 (빌드+전체테스트 확인) |
| C11 | 로거 포팅 | ✅ 완료 (빌드+전체테스트 확인) |
| C12 | CLI 진입점(`--version`/`--setup`) | ✅ 완료 (빌드+전체테스트 확인) |
| C13 | `dab service status/restart` | ✅ 완료 (빌드+전체테스트 확인) |
| C14 | 메시지 전송 재시도 엔진 | ✅ 완료 (빌드+전체테스트 확인) |
| C15 | "도구 사용 알림" 배선 | ✅ 완료 (빌드+테스트 확인) |
| C16 | 프리셋 초안 디스크 저장 | ✅ 완료 (빌드+테스트 확인) |

### 사용자 결정 사항 (5건, 전부 결정 완료)

| # | 내용 | 상태 |
|---|---|---|
| Q1 | Linux/Windows 지원 범위 | ✅ 결정 완료 (덤 취급, 작업 안 함) |
| Q2 | 설정화면(`/config`) TS 원복 | ✅ 완료 (빌드+테스트 확인) |
| Q3 | Codex 모델 저장 키 | ✅ 결정 완료 (현행 유지, 코드 변경 없음) |
| Q4 | 권한 타임아웃/Codex 자동승인 제거 | ✅ 완료 (빌드+전체테스트 확인) |
| Q5 | 채널 삭제 가드 | ✅ 결정 완료 (현행 유지, 코드 변경 없음) |

### High (26건)

전부 ⏳ 대기 — Critical 먼저 끝내고 순서대로 진행 예정.

### 이번 감사와 무관하게 작업 중 발견한 기존 버그 (참고, 이 문서의 C/H 목록에는 없음)

| 내용 | 상태 |
|---|---|
| `GrokSessionBridgeTests.swift:202` `nonBypassPermModeHandlerAllowMapsToAllow()` — `makeGrokBridge`가 `ConfigStore.shared`(실제 로컬 config.json)를 그대로 써서, 이 머신의 `autoAllowClaudeTools`에 "Bash"가 있으면 프레젠터가 호출 안 되고 폴링 루프가 무한대기하던 격리 누락 버그 | ✅ 완료 (커밋 `63def8e`, 빌드+테스트 확인) |

---

## 0. 조사 방법

- `src/` 전체(테스트 파일 포함, 약 140개 TS 파일 · 3만5천 줄)를 6개 영역으로 나눠 각 영역을 담당하는 조사 에이전트가 대응하는 `swift/Sources/` 파일을 1:1로 열어서 비교했다.
  - 영역: ① core(설정/인증/세션 오케스트레이션) ② Discord 인프라(게이트웨이/라우팅) ③ Discord 패널·위저드·인터랙션 ④ Discord 렌더러·이미지 렌더링 ⑤ Claude/Codex 백엔드 ⑥ Grok/Custom 백엔드·서비스·업데이트
  - 각 에이전트는 파일 단위로 `FULLY PORTED / PARTIALLY PORTED / NOT PORTED / N/A`를 판정하고 근거를 `file:line`으로 남겼다.
- 그 중 임팩트가 크고 **한 에이전트에서만** 나온(교차검증 안 된) 주장 6건은 내가 직접 grep/코드 읽기로 재확인했다(아래 "직접 검증"으로 표시된 항목). 2개 이상 영역에서 독립적으로 동일하게 발견된 항목은 그 자체로 교차검증된 것으로 간주했다.
- 문서 신뢰 금지 지침에 따라 `docs/cli-slash-command-parity.md`, `docs/grok-mode-parity.md` 등 기존 패리티 문서는 참고하지 않고 코드만 근거로 삼았다.

---

## 1. Critical — 기능이 조용히 사라진 것 (설정해도 동작 안 함 / 데이터 유실)

### Codex 백엔드

- **C1. [구현됨: `CodexTurnAccumulator.swift:82-86`, `CodexSessionBridge.swift:349-357`]** "생각 중"(thinking) 스트림 미표시. TS `eventMapper.ts:171-184`는 `item/reasoning/delta`(+3개 별칭)를 `kind:'thinking'`으로 매핑한다. Swift `CodexTurnAccumulator.swift`엔 reasoning 계열 케이스가 전혀 없었다 — **코드 자체 주석(`:132`)이 이 누락을 인정**했다. → `codexProgressEvents`에 4개 메서드명(원본+별칭 3개) 케이스를 추가해 `.thinking(text:delta:)`로 매핑(Grok `grokProgressEvents` 패턴과 동일 구조), `CodexSessionBridge.onNotification`의 progress 루프를 switch로 확장해 `StreamStatusHost.noteThinking`으로 배선. 테스트: `CodexTurnAccumulatorTests.swift`의 `progressEventsReasoningDeltaMapsToThinking`(4개 별칭 전부), `progressEventsReasoningDeltaEmptyIgnored`.
- **C2. [구현됨: `Codex/CodexTurnAccumulator.swift` `codexContextUsage(method:params:)`(신규), `Bridges/CodexSessionBridge.swift` `TurnBox.contextUsage`/`makeTurnResult`/`onNotification`]** 턴 진행 중 사용량(토큰 %) 패널 미표시. TS `eventMapper.ts:186-208` + `appSession.ts:211-219`는 `thread/tokenUsage/updated`마다 최신 스냅샷만 갱신하고(중간 emit 안 함) `turn/completed` 시점에 `context_usage`를 1회 방출한다. Swift `CodexSessionBridge.onNotification`엔 이 메서드 처리가 없어 Codex 세션은 사용량 패널이 절대 안 떴다.
  - **구현**: `DabMain.swift`가 이미 백엔드 무관하게 `TurnResult.contextUsage`로 패널을 그리고 있어(`caps.usagePanel` Codex도 기본 true), Codex `TurnResult.contextUsage`가 항상 `nil`인 것만 원인이었음 — 렌더링 쪽은 무변경. C1이 세운 "관심사 1개 = 순수 함수 1개" 컨벤션 그대로, `codexTurnStep`/`codexProgressEvents`/`codexToolEvents` 옆에 `codexContextUsage(method:params:) -> ContextUsageInfo?` 신규 함수 추가(`usage.total.totalTokens`/`usage.modelContextWindow` 파싱, `maxTokens<=0` 가드, `percentage = min(100, round(...))` TS와 동일). Claude `DabSessionBridge.TurnBox.contextUsage` 패턴을 그대로 미러링해 Codex `TurnBox`에도 `contextUsage` 필드 추가, `onNotification`에서 최신 스냅샷만 갱신(즉시 emit 없음), `makeTurnResult`가 그 값을 `TurnResult.contextUsage`로 실어 나름. Codex는 TS와 동일하게 `model` 필드를 세팅하지 않음(패널에서 모델명 없이 퍼센트/토큰만 표시).
  - 유닛 테스트 3건 추가(`CodexTurnAccumulatorTests.swift`): `contextUsageMapsTokenUsageUpdated`, `contextUsageCapsAt100Percent`, `contextUsageIgnoresOtherMethodsAndMissingFields`(메서드 불일치·params nil·tokenUsage 없음·totalTokens 없음·modelContextWindow<=0 전부 nil 확인) — `swift test --filter CodexTurnStepTests` 20건 전부 통과(빌드 13.37s). 전체 빌드/테스트 최종 확인은 사용자가 별도 진행.
- **C3. [구현됨: `Codex/AppServerClient.swift`(`AppServerDynamicToolCallParams`/`Result`/`Handler`, `setDynamicToolCallHandler`, `handleServerRequest`의 `item/tool/call` 분기, `resolveDynamicToolCall`/`parseDynamicToolCallParams`/`encodeDynamicToolCallResult`), `Bridges/CodexSessionBridge.swift`(`codexAttachFileDynamicTool`/`codexShareDocumentDynamicTool`, `ensureChannel`의 `startParams["dynamicTools"]` + `setDynamicToolCallHandler` 등록, `handleDynamicToolCall`/`handleShareDocumentCall`/`noteToolEvent`)]** 동적 도구(파일첨부/문서공유) 전체 미구현. TS는 `thread/start`에 `DynamicToolSpec`을 등록하고 `item/tool/call`에 응답한다(`appSession.ts:353-414`, `appServerClient.ts:335,345-376`). **직접 재확인**: `grep -rn "attach_file\|share_document\|item/tool/call\|dynamicTool" swift/Sources/DiscordAgentBridge/Codex swift/Sources/DiscordAgentBridge/Bridges/CodexSessionBridge.swift` → 0건. Codex `AppServerClient.handleServerRequest`(`:316-339`)는 승인 메서드 외엔 전부 `-32601 Method not found`로 응답 — Codex 세션은 Discord로 파일을 절대 못 보낸다(Claude는 됨).
  - **구현**: Codex는 Grok(C5, 별도 프로세스라 HTTP 루프백이 필요)과 달리 Claude 사이드카처럼 같은 프로세스 안에서 stdio JSON-RPC로 직접 통신하므로, 새 게이트웨이 없이 기존 `FileAttachHost`/`DocumentShareHost` 싱글턴(`Session/FileAttach.swift`/`Session/DocumentShare.swift`, `DabMain.swift`가 부팅 시 백엔드 무관하게 배선)을 그대로 재사용. `AppServerClient`에 TS `DynamicToolCallParams`/`DynamicToolCallResult` 1:1 타입을 추가하고, `onNotification`과 동일한 이유(핸들러가 `self`/`channelId`를 캡처해야 해서 static 기본 팩토리 클로저 안에서는 불가)로 **생성 후 setter**(`setDynamicToolCallHandler`, 기존 `onNotification` 등록 패턴과 동일)로 등록, `handleServerRequest`의 approval 분기 다음에 `item/tool/call` 분기를 추가(핸들러 없음/파싱 실패 fallback까지 TS `resolveDynamicToolCall`/`parseDynamicToolCallParams` 1:1). `CodexSessionBridge.ensureChannel`은 `thread/start`(fresh) params에 `attach_file`/`share_document` 스펙을 **항상** 등록(TS도 `wiring.ts`가 `sendFileFor`/`shareDocumentFor`를 항상 공급해 프로덕션에서 항상 등록됨; resume 경로는 TS와 동일하게 재등록 안 함 — 핸들러는 client에 붙어있어 무관), `handleDynamicToolCall`/`handleShareDocumentCall`이 승인 게이트를 거치지 않고(TS와 동일 — `item/tool/call`은 `requestApproval`과 별개 경로) `attachFileConfined`(경로 가둠)/`documentShareHost.share`를 직접 호출. `share_document`의 거부코드→텍스트 매핑은 Grok C5의 `shareResultText`(`Grok/AttachGateway.swift`)를 그대로 재사용해 TS `shareErrorText` 3중 포팅을 피함. 도구 호출은 `onNotification`의 기존 tool 루프와 동일한 3가지 부수효과(`box.stats.note`/`ToolActivityHost.shared.handle`/`StreamStatusHost.shared.noteToolUse`)를 `noteToolEvent` 헬퍼로 재사용해 attach_file/share_document도 다른 Codex 도구와 동일하게 Discord 작업 스레드·패널 카운트에 노출(TS `ctx.emit` 패리티).
  - 3안 중 옵션 1(post-construction setter + 도구활동 패널까지 반영)을 사용자가 확정 — 옵션 2(패널 노출 생략)는 패리티 갭이 남고, 옵션 3(생성자 주입)은 같은 파일 안에서 `onNotification`과 등록 패턴이 혼재해 일관성이 떨어진다는 판단으로 기각.
  - 유닛 테스트: `AppServerClientTests.swift`에 4건(`dynamicToolCallRoutesToHandlerAndRespondsSuccess`, `dynamicToolCallWithNoHandlerRespondsNoHandlerText`, `dynamicToolCallWithMissingCallIdRespondsInvalidParams`, `parseDynamicToolCallParamsHelper`) — `swift test --filter AppServerClientTests` 16건 전부 통과. `CodexSessionBridgeTests.swift`에 4건(`dynamicToolsRegisteredOnThreadStart`, `dynamicToolCallAttachFileRoutesToFileAttachHost`, `dynamicToolCallShareDocumentRoutesToDocumentShareHost`, `dynamicToolCallAttachFileMissingPathRespondsFailureWithoutCallingHost` — 페이크 서버에 `pushToolCall`/응답 캡처 추가) — `swift test --filter CodexSessionBridgeTests` 24건 전부 통과(빌드 17.58s, 각 테스트 실행 0.12s/0.007s). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C4. [구현됨: `Codex/CodexSqliteReader.swift`, `Codex/CodexDiscovery.swift`, `DabMain.swift` `listResumableForBackend` `.codex` 케이스]** `discovery.ts`/`sqliteReader.ts` 완전 미포팅. `~/.codex/session_index.jsonl` + rollout sqlite(`threads`/`thread_spawn_edges`)를 읽어 아카이브/서브에이전트 세션까지 재개 목록에 올리는 기능이 없다. Swift의 Codex "재개" 목록(`ResumeWizard.swift:253-276` → `listResumableFromStore`)은 **이 봇 프로세스가 직접 시작해 저장소에 남긴 세션만** 보여준다 — 터미널에서 직접 실행한 `codex` 세션이나, 봇 재시작 이전 세션은 안 보인다.

### Grok 백엔드

- **C5. [구현됨: `Grok/AttachGateway.swift`(신규, `GrokAttachGateway`/`GrokAttachGatewayProviding`), `GrokSessionBridge.swift:29,54`(buildMcpServers/unregisterAttach), `DabMain.swift`(`attach-mcp` 서브커맨드)]** Discord 파일첨부/문서공유 MCP 루프백 전체 미구현. TS는 `attachGateway.ts`(로컬 HTTP 서버)를 통해 Grok의 별도 프로세스가 `attach_file`/`share_document`를 콜백할 수 있게 한다(`acpSession.ts:205-235`, `agent/index.ts:23-32,79-88`). **직접 재확인**: `swift/Sources/.../attachGateway` 류 서버 자체가 없고(`grep -r "createServer\|HTTPServer\|127.0.0.1"` 0건), `GrokSessionBridge.swift:44`가 `GrokAcpClient(...)`를 생성할 때 `mcpServers` 파라미터를 아예 안 넘겨서(디폴트 `[]`) 항상 빈 배열로 시작한다. Grok 세션은 파일 첨부·문서 공유가 완전히 불가능하다.
- **C6. [구현됨: `AttachmentDownload.swift`(classifyTurnFiles/readImageBase64), `GrokSessionBridge.swift`(buildGrokPromptBlocks), `CodexSessionBridge.swift`(buildCodexTurnItems)]** 이미지 첨부가 실제 이미지로 전달 안 됨. TS `buildGrokPromptBlocks`(`acpSession.ts:430-441`)는 이미지 파일을 base64 ACP `image` 블록으로 보낸다. Swift는 `appendAttachedFileHints`(`AttachmentDownload.swift:120-126`)로 모든 파일(이미지 포함)을 그냥 `"Attached file: <path>"` 텍스트 한 줄로 다운그레이드한다. Codex도 동일 문제.
- **C7. [구현됨: `UsageFormat.swift`(`grokContextUsageInputs`/`grokContextUsage` 신규), `Bridges/GrokSessionBridge.swift`(`configSource` 주입 + `executeTurn` 끝부분)]** 컨텍스트 사용량(토큰 %) 패널 미표시. `GrokConfigSource.contextWindow(_:)`(`GrokCatalog.swift:258-261`)는 있는데 `GrokSessionBridge`에서 아무도 호출하지 않아 `TurnResult.contextUsage`가 항상 `nil`.
  - **구현**: TS `acpSession.ts:355-399`(`emitResult`)는 Codex(C2)와 달리 턴 중간 알림이 아니라 `session/prompt` 최종 응답 1회에서만 계산한다(`result._meta.totalTokens`/`modelId`, model = 세션 바인딩 모델 → 없으면 응답의 modelId → 없으면 카탈로그 기본값, `grokConfigSource.contextWindow(model)`으로 창 크기 조회, `min(100, round(...))`). Swift `executeTurn`은 이미 `promptResult: JSONValue`를 턴 끝에 들고 있으므로, C2가 세운 "관심사 1개 = 순수 함수 1개" 컨벤션 그대로 `UsageFormat.swift`(기존 `turnUsage(fromGrokPromptResult:)` 바로 옆)에 순수 함수 2개(`grokContextUsageInputs` — `_meta.totalTokens`/`modelId` 추출, `grokContextUsage` — totalTokens/model/maxTokens로 `ContextUsageInfo` 조립, `totalTokens<=0`/`maxTokens<=0` 가드) 추가. 액터 호출(모델 조회)만 `GrokSessionBridge`에 남기되, 이 브릿지가 이미 `gate`/`store`/`configStore`/`attachGateway`를 전부 생성자 주입(기본 `.shared`)하는 컨벤션을 그대로 따라 `configSource: GrokConfigSource = .shared`를 추가 주입 — 실제 `~/.grok/models_cache.json`을 참조하는 테스트가 로컬 파일에 오염되는, 이미 한 번 겪었던 `ConfigStore.shared` 격리 버그를 반복하지 않기 위함(3안 중 사용자가 이 옵션을 확정).
  - 유닛 테스트: `UsageFormatTests.swift`에 순수 함수 2건(`grokContextUsageInputsExtractsMetaFields`, `grokContextUsageBuildsPanelAndSkipsOnMissingInputs` — 퍼센트 100% 캡, totalTokens/maxTokens 각각 nil·0 가드 확인) + `GrokSessionBridgeTests.swift`에 라운드트립 4건(`contextUsageReachesTurnResult`, `contextUsageFallsBackToResponseModelIdWhenSessionModelUnset`, `contextUsageNilWhenNoMeta`, `contextUsageNilWhenModelContextWindowUnknown` — 페이크 `GrokConfigSource`(`fakeGrokConfigSource`, 인메모리 models_cache.json) + 페이크 서버의 `session/prompt` 응답에 `_meta` 주입) — `swift test --filter 'GrokSessionBridgeTests|UsageFormatTests'` 33건 전부 통과(빌드 19.33s, 테스트 0.226s). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C8. [구현됨: `Grok/GrokSqliteReader.swift`(신규), `Grok/GrokDiscovery.swift`(신규), `DabMain.swift` `listResumableForBackend` `.grok` 케이스]** 세션 재개 목록이 진짜 Grok 세션 검색이 아님. TS `GrokDiscovery`는 `~/.grok/sessions/session_search.sqlite`를 sql.js로 읽어 cwd/심링크 정규화까지 하며 어떤 grok 세션이든 찾아낸다. **직접 재확인**: Swift 전체에 SQLite를 읽는 코드가 없다. C4와 동일한 구조적 문제.
  - **구현**: C4(Codex)에서 이미 검증된 `sqlite3_deserialize` 메모리 역직렬화 read-only 패턴을 그대로 재사용하되, Codex 파일은 무변경 — TS 원본도 `discovery.ts` 자체 주석에서 "Codex의 `sqliteReader.ts`와 같은 read-only byte-copy 패턴"이라 명시하면서 코드는 공유하지 않은 선례를 그대로 따름(3안 중 사용자가 이 옵션을 확정, 제네릭 엔진 추출안은 호출부 2곳뿐인 상태에서의 과설계로 기각). Grok은 Codex와 달리 테이블이 `session_docs` 하나뿐이고 index-vs-sqlite 이원 fallback이 없어(TS도 실패 시 그냥 `[]`) `GrokDiscovery`가 Codex보다 훨씬 단순함. cwd 정규화(trailing slash 제거 + 심링크 realpath)는 새로 안 만들고 `Session/Confinement.swift`의 기존 `public func realpathOrResolve(_:)`를 재사용 — TS 주석이 "`sessionOrchestrator.ts`의 동명 헬퍼를 재사용하고 싶었지만 모듈 프라이빗이라 로컬 복사본을 뒀다"고 밝힌 제약이 Swift에는 없기 때문. `grokHome`은 Codex의 `codexHome`과 달리 config 오버라이드가 없어(기존 `resolveGrokHome()` 그대로 사용) `ConfigStore` 조회가 필요 없음. `DabMain.swift`의 `.grok` 케이스는 기존 `SessionStore` 기반 `listResumableFromStore` 호출을 완전히 대체(TS도 store fallback 없이 discovery로만 응답).
  - 유닛 테스트: `GrokSqliteReaderTests.swift` 3건(`readSessionDocsFromFileReturnsRowsNewestFirst`, `readSessionDocsFromFileThrowsOnMissingFile`, `readSessionDocsFromFileThrowsOnCorruptDb`) + `GrokDiscoveryTests.swift` 9건(`listsAllSessionsNewestFirstWhenNoCwdFilterGiven`, `filtersToGivenCwdAndPreservesRecencyOrder`, `mapsTitleToLabelAndUpdatedAtToIsoString`, trailing slash 양방향 2건, 심링크 정규화, cwd 불일치 제외, db 부재/손상 시 빈 배열 2건) — TS `discovery.test.ts`의 모든 케이스를 1:1로 미러링. `swift test --filter 'GrokSqliteReaderTests|GrokDiscoveryTests'` 12건 전부 통과(빌드 19.75s, 테스트 0.014s). `swift build --target dab`으로 `DabMain.swift` 연동부도 별도 빌드 확인. 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.

### Claude 백엔드 / 공통 세션

- **C9. [구현됨: `DabSessionBridge.swift:307-335`]** 권한 프로필(허용 도구 목록)이 실제로 적용 안 됨. `config.profiles[x].allowedTools`(`ConfigSchema.swift:62-71`)는 디코딩만 되고, `DabSessionBridge.swift:307-315`(수정 전)가 사이드카에 `config.allowedTools`/`permissionTimeoutSec`을 전달하지 않았다(오직 `autoAllowClaudeTools`만 전달). **core 에이전트와 claude/codex 에이전트가 각자 독립적으로 동일 지점을 발견 — 교차검증됨.** 결과적으로 `/mode perm readonly` 같은 프로필을 걸어도 "이 프로필에서 자동 허용할 도구 목록"은 전혀 반영되지 않고 permMode(허용 모드)만 바뀌었다.
  - **조사 결과 정정**: `policyTier`는 TS 원본(`permissionResolver.ts`)에서도 계산만 되고 사이드카 프로토콜(`src/sidecar/claude/protocol.ts`)이나 그 어떤 다운스트림 소비처도 없는 죽은 값(전수 grep 확인) — 진짜 패리티는 `policyTier`를 사이드카로 보내지 않는 것이며, 프로토콜에 새 필드도 필요 없다. Swift `Protocol.swift`의 `SessionStartParams.SessionConfig`는 `allowedTools`/`autoAllowClaudeTools`/`permissionTimeoutSec`를 이미 갖고 있었고(사이드카도 이미 지원) 배선만 빠져 있었다.
  - **구현**: 기존에 있었지만 어떤 프로덕션 브릿지도 쓰지 않던 `ConfigResolver`(global→server→binding 레이어드 리졸버, 이미 테스트됨)를 `DabSessionBridge.sessionHandle()`에서 재사용해 프로필(있으면 `profile.allowedTools`로 전역 `autoAllowClaudeTools`를 대체, TS와 동일) + 레이어드 `permissionTimeoutSec`를 계산, `SessionStartParams.SessionConfig.allowedTools`/`autoAllowClaudeTools`(동일 값)/`permissionTimeoutSec`로 사이드카에 전달. 삭제된 프로필 참조·config.json 자체가 없는 경우 모두 TS처럼 throw하지 않고 fail-secure 폴백(전역 autoAllowClaudeTools, 0 timeout — 기존 `ConfigStore.autoAllowClaudeTools()` 컨벤션과 동일).
  - 유닛 테스트 3건 추가(`DabSessionBridgeTests.swift`): `profileAllowedToolsReachSessionStartConfig`, `noProfileFallsBackToGlobalAutoAllow`, `deletedProfileReferenceFallsBackSilently` — `swift test --filter DabSessionBridgeTests` 28건 전부 통과(0.107s).

### 부팅/인프라

- **C10. [구현됨: `Session/SessionLifecycle.swift:377-405`(`resumeAll`), `DabMain.swift:110-119`(`onReady` 호출부), `DabMain.swift:182-189`(`channelConfirmedGone`)]** 재시작 시 살아있던 세션을 즉시 재연결하지 않음. **직접 재확인**: `DabMain.swift:151-165`의 `restoreSessionBindings()`는 `SessionStore`에서 읽은 바인딩을 `SessionRegistry.shared.bind(...)`로 **메모리에만** 복원할 뿐, 어떤 브릿지의 resume/connect도 호출하지 않는다(`softEnsureLive`는 메시지/슬래시커맨드 처리 시점에만 호출됨, 부팅 경로엔 없음). TS `sessionOrchestrator.ts:590-664`의 `resumeAll()`, `app.ts:361-402`의 "10003(채널이 진짜 삭제됨) 감지 + 정리", `Promise.allSettled` 병렬 재부착이 전부 없다. 이 경로만 커버하는 TS 테스트가 6개(`app.test.ts`) 있는데 Swift엔 대응 테스트가 없다.
  - **조사 결과 정정**: TS `resumeAll()` 자체는 순차 for문(`Promise.allSettled` 아님) — 병렬 `Promise.allSettled`는 `app.ts`의 별도 boot attach 단계(`wiring.attachWithRetry`, Discord 렌더러 재구독 + 채널 존재확인)에서만 쓰인다. Swift엔 TS의 "wiring/attach" 객체 자체가 없다(렌더러가 channelId만 받는 stateless 클로저라 재구독할 대상이 없음) — 그래서 채널 존재확인(10003)과 백엔드 재연결을 채널당 한 번에 처리해도 동일 효과이고, 오히려 TS가 갖고 있는 "resume 직후 gone 판명되면 즉시 kill"하는 낭비(코드 주석에 명시된 orphan 문제)가 없어진다(gone 체크를 resume보다 먼저 함). `DiscordAgentBridge`(라이브러리)는 DiscordBM 의존성이 없어(10003 감지에 필요) 실제 Discord API 호출은 `dab` 실행파일에서만 가능 — `SessionLifecycle`은 기존 `stopClaude`/`interruptClaude` 등과 동일한 클로저 주입 패턴을 그대로 따름(3안 중 사용자가 이 옵션을 확정).
  - **구현**: `SessionLifecycle.resumeAll(channelGone:resumeSession:)` 신규 — `store.active()`(non-archived)를 `TaskGroup`으로 병렬 순회, 채널마다 `channelGone`이 10003을 확인하면 기존 `stopChannel`(=`onChannelDelete`와 동일 경로: 3개 브릿지 stop + registry.unbind + store.remove)로 하드 클린업하고 resume은 아예 시도하지 않음, 아니면 `resumeSession`(기본값은 기존 `softEnsureLive` 재사용)으로 재연결 시도. 두 클로저 모두 non-throwing이라 한 채널의 실패가 다른 채널에 전파되지 않음(`Promise.allSettled`와 동일 보장이 타입 시스템으로 보장됨). `channelGone` 기본값 `{ _ in false }`(TS `wiring.ts`가 문서화한 "safe default — never reports gone"과 동일), `resumeSession`은 nil이면 `softEnsureLive`로 폴백 — 둘 다 파라미터로만 주입하고 `init()`은 무변경(기존 `SessionLifecycleTests` 11개 전부 무영향). `DabMain.swift`의 `onReady`는 `restoreSessionBindings()` 직후 `resumeAll(channelGone:)`을 호출하며, `channelGone` 구현(`channelConfirmedGone`)은 `client.getChannel(id:)` → `.httpResponse.asError()` → `.jsonError(let e)` → `e.code == .unknownChannel`로 판별(그 외 네트워크 오류 등은 전부 false — 일시 오류가 클린업을 트리거 못 하게).
  - 유닛 테스트 3건 추가(`SessionLifecycleTests.swift` "MARK: - C10 resumeAll"): `resumeAllCleansUpGoneChannelWithoutCallingResumeSession`(gone → stopChannel만, resume 호출 안 됨), `resumeAllResumesLiveChannelWithoutStopping`(안 gone → resumeSession만, stop 호출 안 됨), `resumeAllHandlesEachChannelIndependently`(gone/성공-resume/실패-resume 3채널 동시 처리 — 서로 결과가 전혀 안 섞임, 실패한 채널도 다른 채널에 영향 없음). `swift test --filter SessionLifecycleTests` 27건 전부 통과(빌드 10.52s, 테스트 0.031s), `dab` 실행파일 타겟(`DiscordBM` 의존 — `channelConfirmedGone`)도 같은 빌드에서 링크 확인. `channelConfirmedGone` 자체는 `dab` 실행파일 전용 코드라 이 저장소의 테스트 구조상(테스트 타겟이 `DiscordAgentBridge` 라이브러리만 대상) 단위테스트 불가 — 기존 `GuildChannelProvisionerAdapter.channelExists` 등 동일 계열 미검증 코드와 같은 처지. 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C11. [구현됨: `Session/Log.swift`(신규 — `LogLevel`/`LogSink`/`ConsoleSink`/`Logger`/`currentLogLevel`), 전역 `print`/`fputs` 호출부 다수]** 로거(`src/core/logger.ts`) 전체 미포팅이었음. 레벨 게이팅 없는 `print`/`fputs`가 산재(`DabMain.swift`에만 `print` 46곳 + `fputs` 21곳, 그 외 9개 파일에 각 1~9곳, 총 99곳). `config.logLevel`은 스키마 검증만 되고 **어디서도 읽히지 않았음**(전체 grep 6건 전부 `ConfigSchema.swift` 내부 선언). 일반 로그는 `redact()` 처리도 안 됨(`AuditLog.swift`만 문자열 패턴 스크러빙 적용).
  - **구현**: `Session/Log.swift` 신규 — TS `LogLevel`/`LEVEL_ORDER`를 그대로 미러링한 `LogLevel` enum(Comparable), TS `LogSink`/`consoleSink`를 미러링한 `LogSink` 프로토콜 + `ConsoleSink`(error/warn → 기존 `fputs(..., stderr)` 컨벤션 그대로, 나머지 → `print`), TS `RedactingLogger`를 미러링한 `Logger` struct(actor 아님 — 상태가 불변 name/level/sink뿐이라 `AuditLog`(append-only 파일 순서 보장 때문에 actor)와 달리 오버헤드 불필요, 3안 중 사용자 사전 확정). 메시지는 기존 `redactSecrets`(`Session/AuditLog.swift:63`, TS `redactString` 포트)를 재사용해 스크러빙 — TS `redact()`의 재귀 객체 마스킹은 이식하지 않음(Swift 호출부 전수 확인 결과 전부 문자열 보간이고 별도 meta 객체를 넘기는 곳이 없음, 구조화 로깅 호출부 없음 확인 완료).
  - TS는 `app.ts`에서 config를 1회 읽어 만든 단일 `'app'` 로거를 의존성 주입으로 전체에 threading하지만, Swift는 파일마다 지연 생성되는 `private let log = Logger(name: "...")` 전역이 흩어져 있어 생성 시점이 부팅 config 로드 시점과 어긋날 수 있음 — 그래서 `level`을 명시하지 않으면 매 호출마다 전역 `currentLogLevel`(`LockedBox<LogLevel>` 재사용, 기존 `Sidecar/LockedBox.swift` 패턴)을 동적으로 읽도록 설계(명시적 `level`을 준 경우만 고정 — 테스트용). `DabMain.swift`의 `onReady` 이전, 기존 `ConfigStore.shared.load()` 호출(로케일 적용과 같은 지점)이 성공하면 그 값으로 `currentLogLevel`을 1회 설정, 실패 시 기본 "info" 유지.
  - 로거 이름은 TS `grep -rn "createLogger(" src` 확인 결과 프로덕션 호출은 사실상 `'app'`(`app.ts`) 하나뿐이라(테스트만 `'usage'`/`'grok-usage'` 등 사용) TS와 1:1 매핑할 지점이 많지 않음 — `DabMain.swift`는 TS `app.ts`의 boot/이벤트 핸들러 역할과 대응되므로 `"app"`으로, `UsageService.swift`의 3개 actor(Claude/Grok/Codex)는 TS 테스트 네이밍(`'usage'`/`'grok-usage'`)을 그대로 따르고 Codex는 대응 이름이 없어 동일 패턴으로 `"codex-usage"`, 그 외 파일(`DabSessionBridge`→`"claude"`, `CodexSessionBridge`→`"codex"`, `GrokSessionBridge`→`"grok"`, `AutoUpdateWiring`→`"auto-update"`, `ConfigStore`→`"config"`, `CodexDiscovery`→`"codex-discovery"`, `SessionPersist`→`"session-persist"`, `GuildChannelProvisionerAdapter`→`"guild-provision"`)는 파일명 기반으로 지음.
  - **CLI 출력 제외**: `DabMain.swift`의 `--version`/`--setup` 안내/토큰 누락 usage 에러, `codex-smoke`/`grok-smoke`/`sidecar-smoke` 서브커맨드 진단 출력, `attach-mcp` 서브커맨드의 stdio JSON-RPC 와이어 프로토콜 출력(`writeAttachMcpLine` — 로그가 아니라 Grok 프로세스가 파싱하는 프로토콜 그 자체라 감싸면 프로토콜이 깨짐)은 전부 그대로 둠. `Service/ServiceCommand.swift`의 `log:` 기본값(`{ print($0) }`)도 `dab service status/restart`의 사용자 대면 CLI 출력(한국어 안내문)이라 로거 대상에서 제외 — 애초 조사 시 "1곳"으로 집계됐던 곳이지만 실제로는 CLI 출력이라 판단해 전환 대상에서 뺌(오케스트레이터 확인 필요).
  - 유닛 테스트 7건 신규(`LogTests.swift`): 임계값 미달 억제, 임계값 이상 통과 + 포맷(`[LEVEL] name: msg`) 확인, 민감정보 스크러빙 확인, `level` 미지정 시 `currentLogLevel` 동적 반영, `level` 명시 시 `currentLogLevel` 변경 무시, `LogLevel` 순서 비교. 전역 `currentLogLevel`을 변경하는 테스트가 있어 `I18nTests.swift`와 동일하게 `@Suite("Logger", .serialized)` 적용.
  - **수정(오케스트레이터 빌드 검증 중 발견)**: `UsageService.swift`의 `claudeUsageLog`/`grokUsageLog`/`codexUsageLog` 3개를 처음엔 `private let`으로 선언했는데, 이걸 참조하는 `ClaudeUsageService`/`GrokUsageService`/`CodexUsageService`의 이니셜라이저가 전부 `public init`이라 "기본 인자값이 이니셜라이저보다 낮은 접근수준을 참조할 수 없다"는 Swift 규칙에 걸려 빌드 실패 — `public let`으로 수정해 해결.
  - 최종 확인: `swift build --package-path swift`, `swift build --package-path swift --target dab` 모두 성공, `swift test --package-path swift` 전체 스위트 1027개 테스트 전부 통과(3.591초, 기존 테스트 회귀 없음).
- **C12. [초안 구현됨: `DiscordAgentBridge/Token.swift`(`DiscordToken.resolve(configToken:)`), `dab/DabMain.swift`(`--version`/`--setup` 분기, `printSetupGuidance()`, `configToken` 배선)]** CLI 진입점(`src/cli.ts`) 전체 미포팅이었음. `--version`/`--setup`/`service <sub>` argv 분기, `needsSetup()` 게이트가 없었고, `DabMain.swift:8-26`(수정 전)이 곧바로 `DiscordToken.resolve()`(env var 또는 argv[1])로 토큰을 읽어 `config.json`의 `discord.token`/`discord.clientId` 필드를 완전히 우회했다(스키마엔 있지만 읽는 곳 전무 — 죽은 필드).
  - **범위**: `service <sub>`는 C13(별도 WO)이라 이번 변경에서 완전히 제외. `--version`/`--setup` + config.json 토큰 배선만 다룸.
  - **조사 결과**: TS `runSetup()`은 `@inquirer/prompts` 기반 인터랙티브 터미널 위저드(토큰/ClientID 입력 → `config.json` 저장)인데, Swift 포팅본엔 이에 대응하는 게 애초에 존재하지 않는다(전수 grep 0건) — 실제 Swift 배포 흐름은 `swift/scripts/install.sh:143`처럼 `.env` 파일에 `DISCORD_BOT_TOKEN`을 직접 채우는 방식이라 아키텍처 자체가 다르다. `discord.clientId`는 TS에서도 위저드 초대링크 생성 + `DiscordClient` 생성자(`app.ts:378`)에만 쓰이는데, Swift는 gateway `READY` 페이로드의 `payload.application.id`(`DabMain.swift` `registerAgentCommand(appId:...)`)로 앱 ID를 직접 받아 써서 운영상 clientId 자체가 불필요 — 그대로 죽은 채 둠(문서화된 의도적 결정).
  - **구현(3안 중 옵션 1 사용자 확정)**: 인터랙티브 위저드를 새로 만들지 않고(비존재 서브시스템 신설은 과설계, `.env` 기반 실제 배포와 충돌), `--version`은 이미 오토업데이터가 쓰던 `readAppVersion()`(`Update/Version.swift:82`)을 그대로 재사용해 출력, `--setup`은 안내 텍스트(`printSetupGuidance()` — 토큰을 줄 수 있는 3가지 경로 + `/config`로 역할/기본값은 나중에 Discord에서)만 출력하고 봇 기동 안 함(TS의 "위저드만, 자동시작 없음" 계약과 동일 효과). `DiscordToken.resolve`에 `configToken: String? = nil` 파라미터를 **기본값과 함께 추가**해 기존 유일 호출부/4개 테스트 무변경, 우선순위 맨 끝(env → argv → config.json)에만 편입 — 기존 env/argv 우선 배포 방식(launchd/systemd)에 회귀 없이 죽은 필드만 해소. `DabMain.swift`의 토큰 획득부는 `ConfigStore.shared.load().discord.token`을 `configToken`으로 넘기도록 배선(`try?` 폴백 — config 자체가 없거나 파싱 실패해도 기존처럼 env/argv 경로로 계속 동작).
  - 유닛 테스트 4건 추가(`TokenAndTextTests.swift`): `fallsBackToConfigTokenWhenEnvAndArgvAbsent`, `emptyConfigTokenIsNotATokenEither`, `argvStillWinsOverConfigToken`, `envStillWinsOverConfigToken` — `swift test --filter DiscordTokenTests` 9건(기존 5건 포함) 전부 통과(빌드 14.55s, `dab` 실행파일 타겟도 같은 빌드에서 링크 확인). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C13. [구현됨: `Service/ServiceCommand.swift`(신규, `ServiceCommandDeps`/`runServiceCommand`/`serviceStatus`/`serviceRestart`), `dab/DabMain.swift`(`"service"` 분기)]** `dab service install/uninstall/status/restart` 전체 없음이었음. `DabMain.main()`은 `sidecar-smoke`/`codex-smoke`/`grok-smoke`만 인식하고 `"service"` 분기가 없었다. install/uninstall은 셸 스크립트(`swift/scripts/install*.sh`, `install-windows.ps1`)로 대체됐지만, **status/restart는 어떤 플랫폼에도 스크립트조차 없었다** — launchd `status()`(`launchctl list` 파싱) 자체가 어디에도 없었음(직접 재확인: 코드 전체에서 `launchctl list` 언급은 주석 1곳뿐).
  - **범위**: macOS(launchd)만 — Linux/Windows는 Q1 결정대로 그대로 덤 취급. install/uninstall은 재구현하지 않고 기존 셸 스크립트 안내만 함(`service install`/`service uninstall`/그 외 미지원 서브커맨드는 전부 사용법 출력 후 실패).
  - **구현(3안 중 옵션 1 사용자 확정)**: TS `src/service/index.ts`+`launchd.ts`의 모듈 경계(자동업데이트 전용 `src/update/`와 분리)를 그대로 따라 신규 `Service/ServiceCommand.swift` 추가 — 옵션 2(기존 `Update/Installer.swift`에 얹기)는 동작은 동일하지만 자동업데이트 관심사와 섞여 기각, 옵션 3(신규 셸 스크립트 `status.sh`/`restart.sh`)은 유닛테스트 불가 + `dab service` 서브커맨드 자체가 여전히 안 생겨 패리티 갭이 실질적으로 안 메워져 기각. `status`는 TS와 동일하게 `launchctl list`(인자 없음) 실행 후 stdout 전체 줄에서 라벨(`com.discord-agent-bridge`) 포함 여부로 "실행 중" 판정 + plist 파일 존재 여부로 "등록" 판정. `restart`는 TS `launchd.ts restart()` 및 `install.sh`의 `load()` 헬퍼와 동일하게 `launchctl unload <plist>`(실패 무시) → `launchctl load -w <plist>` 시퀀스 사용(Installer.swift의 `launchctl kickstart -k`는 실행 중인 자기 자신의 자동업데이트 self-restart 전용이라 별개 — unload가 그 프로세스 자신을 죽이는 걸 피하려고 kickstart를 쓰는 것이므로, 별도 프로세스로 실행되는 `dab service restart`엔 해당 없음). 새 프로세스 스폰 코드는 만들지 않고 기존 `Update/Installer.swift`의 `UpdateCommandRunner`/`runUpdateCommand`(이미 injectable)와 `launchdPlistPath(home:)`, `Session/FolderPanel.swift`의 공용 `ProcessCapture`를 그대로 재사용. `DabMain.swift`는 `"service"` 분기 1개만 추가해 `runServiceCommand(argv:)` 결과를 `exit(ok ? 0 : 1)`로 매핑.
  - 유닛 테스트 5건 신규(`ServiceCommandTests.swift`): `statusReportsRunningWhenLaunchctlListContainsLabel`, `statusReportsNotRunningWhenLabelAbsent`, `restartUnloadsThenLoads`(unload→load -w 순서·인자 확인), `restartFailsCleanlyWhenLoadReturnsNonZero`, `unknownSubcommandPrintsUsageAndFails` — TS `service.test.ts`의 launchd describe 블록과 1:1 미러(launchctl 실제 호출 없음, `ServiceCommandDeps`로 전부 주입). `swift test --package-path swift --filter ServiceCommandTests` 5건 전부 통과(빌드 19.91s, `dab` 실행파일 타겟도 같은 빌드에서 링크 확인). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C14. [구현됨(초안): `Sources/DiscordAgentBridge/Render/SendRetry.swift`(신규, `sendWithRetry`/`SendAttemptResult`/`SendRetryOutcome`), `Sources/dab/MessageRetry.swift`(신규, `createMessageWithRetry`), `DabMain.swift`/`AutoUpdateWiring.swift`의 `try? client.createMessage(...)` 15곳]** 채널 전송 재시도 엔진 전체 없음. **직접 재확인**: `grep -rn "10003\|exponential\|backoff\|retryAttach\|ensureAttached"`가 `UsageService.swift`(사용량 폴링용, 무관)만 걸리고 메시지 전송 경로엔 0건. TS `wiring.ts`의 5회 지수 백오프(300/600/1200/2400ms) + "채널이 진짜 삭제됨(10003) vs 일시적 오류" 구분이 없다 — Swift는 `try? client.createMessage(...)`로 실패 시 그냥 조용히 드롭한다(전용 TS 테스트 18개, `wiring.test.ts:538-755`).
  - **조사 결과**: TS `wiring.test.ts:538-755`가 검증하는 5회 백오프/10003 판별은 실제로는 `wiring.ts`의 **"attach" 단계**(채널을 렌더러에 붙이기 전 존재 확인, `attachWithRetry`/`ensureAttached`)에만 있다 — TS의 실제 메시지 전송(`channel.send`)은 `streamEmbed.ts:118-134`/`renderers/index.ts`에서 의도적으로 swallow하고 재시도하지 않는다("드롭 프레임은 무해, 턴은 계속된다"는 주석이 명시적으로 있음). Swift는 TS의 "attach" 개념 자체가 없어(C10 구현 노트에 이미 명시: "Swift has no separate Discord wiring/attach object") 채널 존재 확인과 전송이 `client.createMessage(...)` 한 번으로 합쳐져 있다 — 그래서 TS의 attach 재시도/10003 판별 신호를 적용할 자리가 "전송 호출 그 자체"뿐이다. C10과 동일한 논리의 재해석(사용자 확정).
  - **구현(3안 중 옵션 1 사용자 확정)**: `try?`로 조용히 드롭하던 15곳 전부를 `createMessageWithRetry`로 교체(`DabMain.swift` 13곳: idle watchdog 알림/모드전환 알림×2/usage·auth-denied·첨부실패 회신/턴 결과 본문·usage embed·context fallback·rate-limit·mention·에러청크/권한요청 버튼, `AutoUpdateWiring.swift` 2곳: 업데이트 프롬프트·컨트롤채널 공지). 이미 `try`+do/catch로 실패를 반환값으로 알리던 호출부(`SlashSupport.swift` 5곳, `DabMain.swift`의 `emitDeliverPayload`/권한임베드/파일첨부 3곳, 총 8곳)는 **그대로 둠** — 옵션3(전부 재시도화)의 위험 분석대로, 그중 슬래시 커맨드 상호작용 응답 경로는 Discord ~3초 interaction ack 데드라인과 얽혀 있어 재시도 대기(최대 4.5초)를 얹으면 일시적 오류가 오히려 interaction-token 만료로 확정 실패가 될 수 있음(TS도 이 경로들엔 애초에 재시도를 두지 않음). 엔진(`sendWithRetry`)은 DiscordBM 의존이 없는 `DiscordAgentBridge` 라이브러리에 제네릭(`SendAttemptResult<Success>`/`SendRetryOutcome<Success>`)으로 둬 테스트 가능하게 하고(패키지 경계상 `DiscordAgentBridge`엔 DiscordBM 의존성이 없음 — C10의 `channelConfirmedGone`과 동일한 이유), `dab` 타겟의 `createMessageWithRetry`가 DiscordBM 전용 10003 판별(`resp.asError()` → `.jsonError` → `.code == .unknownChannel`, `channelConfirmedGone`과 동일 판별)만 얹는다. `onGone` 콜백은 guildId가 이미 스코프에 있는 세션 바인딩 호출부(턴 처리 흐름 등)에만 `SessionLifecycle.shared.stopChannel(...)`로 연결(멱등이라 라이브 `channelDelete`/부팅 `resumeAll`과 중복 호출돼도 안전한 여분의 안전망); guildId가 없거나(idle watchdog 알림, 권한요청 버튼) 세션 바인딩 개념이 없는 컨트롤채널 공지는 `onGone: nil`로 스킵(다른 두 경로가 이미 커버).
  - 유닛 테스트 5건 신규(`SendRetryTests.swift`, TS `wiring.test.ts:538-755`와 1:1 구조 미러): `succeedsFirstAttemptNoDelay`(1회 성공, 지연 없음), `recoversOnThirdAttempt`(2회 실패 후 3회째 성공, 지연 [300,600]), `exhaustsAtFiveAttempts`(5회 소진, 지연 [300,600,1200,2400]), `goneStopsImmediately`(gone 즉시 중단, 지연 없음), `stopsTheMomentItTurnsGone`(도중 gone 전환 시 그 순간 중단, 예산 안 씀). `swift test --package-path swift --filter SendRetryTests` 5건 전부 통과(빌드 5.07s, 테스트 0.001s), `swift build --package-path swift`로 `dab` 실행파일 타겟도 같은 빌드에서 링크 확인(15곳 치환 전부 컴파일 통과). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **C15. [구현됨: `Render/ToolActivityHost.swift`(`ToolUseNotifier` typealias, `setNotifier`/`setNotifyContext`, `handle` 상단의 알림 훅), `dab/DabMain.swift`(부팅 시 `setNotifier` 배선, 턴마다 `setNotifyContext` 배선)]** "도구 사용 알림" 설정이 죽은 값이었음. `notifications.events.toolUse`를 켜도 `postStatusNotification`이 `.toolUse` 케이스로 호출되는 곳이 코드 전체에 없었다(`.result`/`.rateLimit`/`.error`만 호출됨). `SessionNotifier.formatNotification`엔 `toolUse` 케이스가 있어서 "구현했는데 안 불림" 형태의 죽은 코드였음.
  - **조사 결과**: TS `wiring.ts:509-529`(`attachNotifier`)는 `SessionNotifier`를 `RendererDispatcher`(도구 스레드/디프 렌더링)와 **완전히 독립된** 별도 이벤트버스 구독으로 붙여서, 렌더 capabilities(`toolThreads`/`fileDiff`)와 무관하게 도구가 호출되는 매 순간 실시간으로 상태 채널에 한 줄씩 올린다(턴 종료 후 집계가 아님). Swift는 Claude/Codex/Grok 3개 브릿지 모두 `.toolUse`/`.toolResult`를 예외 없이 `ToolActivityHost.shared.handle(channelId:event:)` 한 곳으로 퍼널링하고 있어(`DabSessionBridge.swift:503`, `CodexSessionBridge.swift:437,557`, `GrokSessionBridge.swift:187`), 이게 3개 백엔드가 공유하는 유일한 tool_use 공통 지점이었다.
  - **구현(3안 중 옵션 1 사용자 확정)**: 새 파일 없이 기존 `ToolActivityHost`에 알림 훅을 추가 — `ToolUseNotifier` 타입(`channelId`/`guildId`/`backend`/`event`), `setNotifier(_:)`(부팅 시 1회, `postStatusNotification` 호출로 배선), `setNotifyContext(channelId:guildId:backend:)`(턴마다 1회, 기존 `setCapabilities` 호출 바로 옆, `StreamStatusHost.begin(channelId:guildId:messageId:)`와 동일한 "dab가 턴 시작 시 guildId 주입" 패턴 재사용)를 추가. `handle(channelId:event:)`의 `toolThreads`/`fileDiff` 게이트(`if !caps.toolThreads && !caps.fileDiff { return }`) **이전**에 `.toolUse` 알림을 걸어서 TS와 동일하게 렌더 capabilities와 완전히 독립시킴(옵션2 — 별도 신규 host + 브릿지 3개 파일 4곳 호출 추가 — 는 diff가 이 WO의 "소규모, 독립" 성격을 벗어나 기각, 옵션3 — 턴 종료 시 집계 요약 1줄 — 은 TS의 "도구 호출마다 실시간 1줄" 동작과 달라 요구사항을 절반만 채워 기각). `dispose(channelId:)`에 `notifyContextByChannel` 정리도 추가(caps/factory 상태와 동일 라이프사이클).
  - 유닛 테스트 3건 신규(`CapabilitiesTests.swift` "ToolActivityHost C15 tool_use notifier" 스위트): `toolUseFiresNotifierIndependentOfCaps`(toolThreads/fileDiff 둘 다 꺼도 알림은 발화, 스레드 포스팅은 여전히 0건 — 두 관심사가 서로 독립임을 증명), `toolResultDoesNotFireNotifier`(TS처럼 tool_use만 발화, tool_result는 무시), `missingNotifyContextSkipsNotifier`(`setNotifyContext` 안 한 채널은 guildId가 없어 알림 스킵). 최종 확인: `swift build --package-path swift`(3.95s), `swift build --package-path swift --target dab`(1.34s) 모두 성공, `swift test --filter CapabilitiesTests` 15건 전부 통과(0.148s) — 기존 게이팅 테스트 3건도 회귀 없음.
- **C16. [구현됨: `SessionStore.swift:113-117,176,200-202,219-260,264-280` (StoreFile.presetDrafts + presetDraft/setPresetDraft/removePresetDraft), `ChannelWizard.swift:835-857` (PresetDraftRegistry → SessionStore 위임), `ConfigSchema.swift:273` (PresetDraft: Codable)]** "프리셋으로 저장" 임시 데이터가 재시작하면 사라짐. **직접 재확인**: `PresetDraftRegistry`(`ChannelWizard.swift:836-850`)는 순수 인메모리 `actor` 딕셔너리 — 디스크 읽기/쓰기 코드가 없다. TS `state/store.ts:116-136`은 정확히 "재시작하면 초안이 날아가는 문제"를 고치려고 `state.json`에 영속화했는데, 그 이유 자체가 재발한 상태. → TS와 동일하게 같은 파일(`swift-state.json`)에 `presetDrafts` 최상위 필드를 `autoUpdate` 추가 선례 그대로 미러링해 추가(버전업/마이그레이션 불필요), `mutate()`/`setUpdateMeta()`도 디스크의 `presetDrafts`를 이어받도록 보강해 서로 클로버하지 않게 함. `PresetDraftRegistry`는 공개 API(`set/get/remove`, `key(...)`) 그대로 두고 내부만 `SessionStore.shared` 위임으로 교체 — `DabMain.swift` 호출부 5곳 무변경. 테스트 5개 신규(`SessionStoreTests.swift` "MARK: - C16"): 재시작 후 초안 유지, 채널간 미혼합, 삭제, 채널바인딩/autoUpdate 변경이 presetDrafts를 안 날리는지 상호 확인.

---

## 2. High — 부분 포팅 (동작이 다르거나 정보가 손실됨)

### 권한/보안

- **H1.** 권한 요청 임베드가 도구의 전체 JSON 입력(Edit의 old/new 문자열, WebFetch URL, 커스텀 MCP 도구 인자 등)을 안 보여주고 `command`/`file_path`만 뽑아 보여줌(`DabSessionBridge.swift:652-656` vs `permissionButtons.ts:97-104`) — 그 외 도구는 승인자가 아무 상세정보 없이 승인/거부해야 함.
- **H2.** 결정 후 재렌더링이 "색상+제목+본문 임베드"에서 평문 한 줄(`"🔐 ALLOW — @user"`)로 다운그레이드(`DabMain.swift:220-223`). `perm.request.body`/`perm.decided.*` i18n 키가 `I18n.swift`에 아예 없음.
- **H3. [구현됨: `Session/PermissionGate.swift` `await(prompt:)`]** (Swift만 있는 추가 동작, 참고용) 권한 게이트에 TS엔 없는 "미응답 시 자동 거부 타임아웃"이 있었음(`PermissionGate.swift:72-89`, 수정 전) — 9장 Q4 결정에 따라 제거. `timeoutNs` 파라미터·`Pending.timeoutTask`·타이머 `Task`/`settle` 분기를 전부 삭제해 TS와 동일하게 무한 대기로 전환. `DabSessionBridge`/`CodexSessionBridge`/`GrokSessionBridge` 3곳의 `permGateTimeoutNs` 계산 프로퍼티와 호출부 인자도 함께 제거(공유 액터라 시그니처 변경 시 3곳 다 갱신 필요). 테스트: `PermissionGateTests.swift`의 `timeoutDeniesByDefault` 삭제, `nilApproverCannotBeResolved`는 타임아웃 의존을 걷어내고 "아무도 못 정하지만 계속 pending"만 검증하도록 정리, `unansweredAskStaysPendingIndefinitely` 신규 추가 — `swift test --filter 'PermissionGateTests|DabSessionBridgeTests|CodexSessionBridgeTests|GrokSessionBridgeTests'` 86건 전부 통과(0.235s). 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.
- **H4. [보안] 이미지 렌더링용 headless 브라우저에 네트워크 차단이 빠짐.** TS는 표/mermaid 스크린샷을 찍는 브라우저에서 아웃바운드 네트워크를 통째로 막는다(`setRequestInterception`+`setOfflineMode(true)`, `browserRenderer.ts:143-148`). Swift `BrowserImageRenderer.swift`는 `chrome --headless=new --screenshot=...`를 프로세스로 실행할 뿐 네트워크 차단 플래그가 전혀 없다(`:216-227`) — 신뢰할 수 없는 표/mermaid 콘텐츠(사용자가 입력한 텍스트에서 파싱됨)가 외부로 네트워크 요청을 보낼 수 있다.
- **H25. [구현됨: `Bridges/CodexSessionBridge.swift` `ensureChannel` `onApproval`]** (Swift만 있는 동작) Codex 승인 요청도 도구 이름이 전역 `autoAllowClaudeTools`에 있으면 Discord에 묻지도 않고 자동 승인했음(`CodexSessionBridge.swift:255-260`, 수정 전) — 9장 Q4 결정에 따라 제거. `onApproval` 핸들러 안의 `isAutoAllowedClaudeTool(...)` 체크를 삭제해 Codex 승인이 그 세션의 `approvalPolicy`/샌드박스(`resolveThreadPolicy`)로만 결정되도록 함(TS 동일). 그 체크에만 쓰이던 `configStore` 프로퍼티/init 파라미터도 완전히 죽은 코드가 되어 함께 제거(다른 참조 없음, 확인 완료). Grok(`GrokSessionBridge.swift`)의 동일한 `isAutoAllowedClaudeTool` 참조는 이번 결정(H25) 대상이 아니라 그대로 둠(문서·사용자 지시 모두 Codex만 지목) — 다만 구조적으로 동일한 패턴이라 필요 시 별도 검토 대상. 전용 테스트는 없었음(기존 `nonAutoPolicyHandlerAllowMapsToAccept` 등은 승인 플로우 자체를 검증할 뿐 auto-allow-list 우회는 다루지 않았음) — 기존 CodexSessionBridge 테스트 전부(`swift test --filter CodexSessionBridgeTests`, H3와 동일 실행에 포함) 통과로 회귀 없음 확인.

### Chromium 이미지 렌더링

- **H5.** Chromium 자동 설치가 런타임에 Node.js/npx를 요구하게 됨. TS는 `@puppeteer/browsers` 라이브러리를 인프로세스로 호출해서 빌드 타임 외엔 Node 불필요(`chromiumProvisioner.ts:95-147`). Swift는 `npx @puppeteer/browsers install chrome@stable`을 셸아웃(`ChromiumProvisioner.swift:145-191`)해서 Node/npx가 PATH에 없으면 `.nodeUnavailable`로 실패 — Swift 포팅이 없애려던 바로 그 런타임 의존성이 재도입됨.
- **H6.** 신규 서버 초대/최초 `/setup` 성공 후 "Chromium 설치할까요?" 선제 안내 프롬프트 미포팅(`client.ts:601,724`, `router.ts:266-276` `maybePromptRenderSetup`) — **discord 렌더러/패널/인프라 3개 에이전트가 독립적으로 동일 항목을 발견**(교차검증 강함). Swift는 `/config` 패널을 수동으로 열어야만 설치 가능.
- **H7.** 설치 진행률(%) 표시 없음 — `ChromiumProvisioner.install(onProgress:)` 콜백을 지원하는데 호출부(`DabMain.swift:992-1017`)가 `onProgress`를 안 씀. 성공/실패 메시지도 i18n 아닌 하드코딩 영어.

### 스트리밍/렌더링 세부

- **H8.** 스트림 임베드 푸터에서 경과시간+델타개수가 빠지고 도구 개수만 표시(`StreamEmbed.swift:47-84` vs `streamEmbed.ts:219-222`). "Thought for Ns" 생각-완료 제목도 `stream.thought` i18n 키만 존재하고 실제로 참조하는 코드가 없음(죽은 키).
- **H9.** 텍스트 1초/생각 2초로 다른 디바운스 간격이 Swift에서 둘 다 1초로 통일(`StreamStatusHost.swift:22`).
- **H10.** 턴 진행 중 여러 번 오는 사용량/레이트리밋 이벤트를 실시간으로 안 올리고 턴 종료 후 마지막 값 1번만 게시 — 중간 발생분이 소실됨(`DabMain.swift:1874-1922` vs `index.ts:323-365`).
- **H11.** `Capabilities`가 TS 8개 플래그(thinking/permissionPrompts/progress/transcript/sessionResume/fileAttach/permissionModes 등) → Swift 4개(streaming/toolThreads/fileDiff/usagePanel)로 축소. 지금은 4개 백엔드가 전부 true라 무해하지만, 백엔드별 세분화된 기능 게이팅을 표현할 수 없음.

### i18n / UI 텍스트

- **H12. 번역 키가 240개 중 102개만 포팅됨, 그마저 방향이 반대로 깨져있음.** 위저드(`ChannelWizard.swift:610-723`)·폴더브라우저(`DirectoryBrowser.swift:156-200`)·재개화면(`ResumeWizard.swift:166-224`)·폴더패널(`FolderPanel.swift:16`)은 한국어 하드코딩 — 로케일을 영어로 바꿔도 이 화면들은 그대로 한국어. 반대로 `ConfigPanel.swift:311-399`는 영어 하드코딩 — 한국어로 바꿔도 그대로 영어. `I18n.swift`엔 대응되는 `wizard.*`/`resume.*` 키가 이미 존재하는데(`:166-175`, `:304-307`) 그냥 안 불림. `cmd.mode.unavailable` 키도 없어서 알 수 없는 backend 응답이 `"알 수 없는 backend"` 하드코딩.

### 동시성/일관성

- **H13.** 같은 채널에서 버튼 연타(동시 컴포넌트 상호작용) 시 상태머신을 보호하는 직렬화 큐(`enqueueWizard`)가 없음 — `ChannelWizard`가 락 없는 `@unchecked Sendable` 클래스라 두 인터랙션이 동시에 상태를 레이스할 수 있음.
- **H14.** 프리셋 삭제 시 TS는 `onDeletePreset`의 반환값(설정 파일 기준 최신 목록)으로 화면을 갱신하는데, Swift는 로컬에서 먼저 낙관적으로 지우고 저장은 `try?`로 fire-and-forget(`ChannelWizard.swift:508-513`) — 디스크 저장이 실패해도 화면엔 이미 사라진 것처럼 보임.
- **H17.** 부팅 시 stray `Task{}` 예외를 잡아주는 앱 레벨 안전망(`installGlobalSafetyNet`)과 PID 파일 기록/삭제가 없음.
- **H18.** `config.json` 전체를 TS의 zod처럼 엄격 검증하지 않고 일부 enum 필드만 스팟체크(`ConfigSchema.swift:485-507`) — `profiles` 안의 이상한 값이 Codable 디코딩만 통과하면 걸러지지 않을 수 있음.
- **H19.** 서버 레벨에서 `permissionProfile: null`로 명시적으로 지워도 "필드 없음"과 구분이 안 돼(`String?`) 무시됨(코드 자체 주석이 인정, `ConfigResolver.swift:202-208`).
- **H20. [배포 환경] `resolveCli`에 PATH 외 well-known 경로 폴백이 없음.** **직접 재확인**: `Transport.swift:93-105`의 `resolveExecutable`은 `PATH`만 순회하고 끝난다. TS `resolveCli.ts:95-134`는 launchd/systemd처럼 PATH가 최소화된 환경을 대비해 `~/.local/bin`, `~/.grok/bin`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin` 등을 추가로 뒤졌는데 이게 없다 — **정확히 launchd 백그라운드 서비스로 돌릴 때 codex/grok CLI를 못 찾을 수 있는 지점**.
- **H21.** TS `ModeRegistry`는 "등록만 하면 끝"인 개방형 구조인데 Swift는 고정 `Backend` enum + 5곳(ProviderCatalog/SessionLifecycle/UsageService/Capabilities 등) 분산 switch. 지금 4개 백엔드엔 기능적으로 문제없으나 확장성이 떨어짐.
- **H22.** `eventBus.ts`(범용 pub/sub)가 관심사별 전용 액터(`ToolActivityHost`/`StreamStatusHost`/`IdleWatchdog`/`ImageRenderHost` 등)로 대체됨. 지금 쓰는 렌더러엔 충분하나 새 이벤트 소비자를 추가하려면 매번 새 Host 타입을 만들어야 함.
- **H24.** Codex 앱서버 프로세스 실패 원인 분류(ENOENT→"찾을 수 없음", 인증실패→로그인 안내, 그 외→종료코드+stderr) 없이 뭉뚱그려 일반 에러 메시지만 표시(`AppServerClient.swift`).
- **H26. [구현됨(초안): C14와 동일 커밋 — `Sources/dab/MessageRetry.swift`, `try? client.createMessage(...)` 15곳]** Discord 전송 실패 시 재시도가 없어(H4/C14와 연결) 일시적 API 오류에도 조용히 드롭됨. — C14(WO-P13)와 완전히 동일한 원인(재시도 없음)이라 별도 작업 없이 C14 구현으로 함께 해소됨. 전체 빌드/전체 테스트 최종 확인은 사용자가 별도 진행.

### DM/커맨드 라우팅

- **H15.** TS는 DM을 구조적으로 완전 차단(`messageRouter.ts:144`)하는데 Swift엔 그 가드가 없어서, `dmPolicy=allow`로 설정하면 `!claude/!codex/!grok/!custom <prompt>` 접두사로 DM에서도 턴을 실행할 수 있음(TS는 어떤 설정으로도 구조적으로 불가능). 기본값은 deny라 기본 설정에선 문제없음.
- **H16.** 슬래시 커맨드 등록이 서버별 즉시 등록(TS)에서 전역 등록(Swift, 최대 1시간 전파 지연)으로 바뀌고, 신규 서버 가입 시 재등록도 안 함.

---

## 3. 사용자 판단 필요 (임의로 결정하지 않음 — 확인 후 진행)

| # | 질문 | 결정 (2026-07-26) |
|---|---|---|
| Q1 | `systemd`(Linux)/`schtasks`(Windows) 지원을 정식 스코프로 볼 것인가? | **덤 취급 — 이번 작업 대상 아님.** macOS만 정식 보장, Linux/Windows 스크립트는 "있으면 좋은 것" 수준으로 남긴다. |
| Q2 | `ConfigPanel`의 `dmPolicy` 행 추가, `locale` 이동, `renderDecline`이 `render.enabled`까지 끄는 것 — 유지 vs TS로 복귀? | **TS와 완전히 동일하게 되돌린다.** |
| Q3 | Codex 모델을 `codexModel` 키에 저장(Swift) vs 항상 `claudeModel`에 저장(TS) — 유지 vs 복귀? | **Swift 현재 동작 유지 — `codexModel` 키가 맞다.** 되돌리지 않는다. (참고: 이 항목은 "모델 목록을 실시간으로 가져오는지"와는 무관 — 그건 이미 별도로 확인 완료, 전부 정상 동작 중.) |
| Q4 | H3(미응답 시 자동 거부 타임아웃), H25(Codex가 Claude 전용 자동허용 목록을 곁눈질해 세션 권한과 무관하게 자동승인) — 유지 vs 제거? | **둘 다 제거하고 TS 동작으로 되돌린다.** H3: 응답 없으면 무한 대기(타임아웃 로직 삭제). H25: Codex 자동승인은 그 세션 생성 시 정한 권한/샌드박스 설정으로만 결정 — `autoAllowClaudeTools` 참조를 끊는다. |
| Q5 | `/agent close` 채널 삭제 가드를 Swift가 더 엄격하게(제어채널+카테고리+세션카테고리+상태채널 보호) 만든 것(TS는 제어채널만 보호) — 유지 vs 복귀? | **지금처럼(Swift 쪽 더 엄격한 버전) 유지한다.** |

---

## 4. 정상 포팅 확인 (샘플 — 전체 부정 방지용)

아래는 이번 조사에서 **줄 단위로 대조해 완전히 일치함을 확인한** 굵직한 시스템들이다. 포팅 전체가 부실한 게 아니라, 위 40여 개 항목이 상대적으로 좁은 구멍이라는 걸 보여주기 위해 남긴다.

- `Session/Authorizer.swift` ↔ `src/core/auth.ts` — 티어 판정/관리자 우회/프로젝트 ACL 전부 1:1, 유저 단위 권한 부여는 Swift가 추가.
- `UsageService.swift`(Claude/Codex/Grok 전부) ↔ 각 `usageService.ts` — OAuth 갱신, 429 백오프, 캐시 폴백까지 정확히 일치.
- `Render/BlockParser.swift`, `Render/HtmlTemplates.swift`, `Render/DiffView.swift` ↔ 대응 TS — FSM/이스케이프/파싱 로직 전부 일치.
- `Session/ChannelWizard.swift` 상태머신 ↔ `channelWizard.test.ts`의 모든 전환 케이스 — i18n/동시성 이슈(H12/H13) 제외하면 완전 일치.
- `Codex/CodexPolicy.swift`, `Provider/CodexCatalog.swift`, `Provider/GrokCatalog.swift` — 자체 주석으로 TS 줄 번호를 인용하며 1:1 포팅.
- `Sidecar/ClaudeSidecarClient.swift` ↔ `sidecarClient.ts` — Claude 백엔드는 실제로 **동일한 Node 사이드카 프로세스(`src/sidecar/claude/*`)를 그대로 spawn**해서 재사용하는 구조라, 프로토콜/세션 로직 자체는 TS와 완전히 같은 코드가 실행됨(C9의 "허용 도구 미전달"만 호스트 쪽 배선 문제).

---

## 5. 조사 커버리지

TS 138개 파일(테스트 포함) 전체와 Swift 81개 파일 전체를 6개 병렬 조사로 읽었다. 담당 매핑과 세부 file:line 근거는 각 항목 본문 참조. 이 문서 이후 신규 커밋으로 코드가 바뀌면 file:line은 드리프트할 수 있으니 재작업 전 심볼명으로 재확인할 것.

---

## 6. 작업 지시서 (Critical + Q2/Q4 확정 반영 — 우선순위 순)

> 사용자 지시(2026-07-26): "우선순위 높은 것부터 낮은 것까지 전부 루프 돌면서 계속 이어서 진행." 각 WO는 1장의 해당 C#/H# 항목 본문(재현·근거)을 그대로 스펙으로 삼는다 — 여기서 코드를 다시 베끼지 않는다. 구현 중 재량이 필요하면 담당 DEV가 옵션을 제시하고 오케스트레이터가 그 자리에서 결정한다(사용자에게 재질문하지 않음 — 이미 포괄 승인됨). 같은 파일을 건드리는 WO는 순차 진행, 겹치지 않는 파일은 병렬 진행.

| 순서 | WO | 충족 | 대상 파일(주 파일) | 비고 |
|---|---|---|---|---|
| 1 | WO-P1: Codex 생각 중(thinking) 스트림 | C1 | `CodexTurnAccumulator.swift` | 독립 |
| 2 | WO-P2: Codex 사용량 패널 | C2 | `CodexSessionBridge.swift` | WO-P3와 순차 |
| 3 | WO-P3: Codex 동적 도구(파일첨부/문서공유) [구현됨: `Codex/AppServerClient.swift`, `Bridges/CodexSessionBridge.swift` — 1장 C3 참고] | C3 | `AppServerClient.swift`, `CodexSessionBridge.swift` | WO-P2 이후 |
| 4 | WO-P4: Codex discovery/sqlite 재개 목록 | C4 | 신규 파일 + `ResumeWizard.swift` 연동 | WO-P7과 SQLite 유틸 공유 가능성 — 먼저 진행 |
| 5 | WO-P5: Grok MCP 루프백(파일첨부/문서공유) | C5 | `GrokSessionBridge.swift` + 신규 로컬 서버 | WO-P6과 순차 |
| 6 | WO-P6: Grok 사용량 패널 [완료: 1장 C7 참고] | C7 | `GrokSessionBridge.swift` | WO-P5 이후 |
| 7 | WO-P7: Grok sqlite 재개 목록 [완료: 1장 C8 참고] | C8 | `Grok/GrokSqliteReader.swift`, `Grok/GrokDiscovery.swift`, `DabMain.swift` | WO-P4 완료 후(공유 유틸 재사용 검토 — 결과: Codex 파일 무변경, 패턴만 복사) |
| 8 | WO-P8: 첨부 이미지 실제 이미지로 전달 | C6 | `AttachmentDownload.swift` | Codex/Grok 공통, 독립 |
| 9 | WO-P9: Claude 권한 프로필(allowedTools) 배선 | C9 | `DabSessionBridge.swift` | 독립 |
| 10 | WO-P10: 부팅 시 즉시 재연결 + 채널 삭제(10003) 감지 | C10 | `DabMain.swift`, `SessionLifecycle.swift` | DabMain 계열 — 이하 순차 |
| 11 | WO-P11: CLI 진입점(`--version`/`--setup`, config token 배선) [완료: 1장 C12 참고] | C12 | `DabMain.swift` | WO-P10 이후 |
| 12 | WO-P12: `dab service status/restart` [완료: 1장 C13 참고] | C13 | `Service/ServiceCommand.swift`(신규), `DabMain.swift` | WO-P11 이후 |
| 13 | WO-P13: 메시지 전송 재시도 엔진 [완료(초안): 1장 C14/H26 참고] | C14 | 전송 호출부(여러 렌더/알림 파일) | WO-P10 이후 |
| 14 | WO-P14: "도구 사용 알림" 배선 [완료: 1장 C15 참고] | C15 | `Render/ToolActivityHost.swift`, `dab/DabMain.swift` | 소규모, 독립 |
| 15 | WO-P15: 프리셋 초안 디스크 영속화 [완료] | C16 | `ChannelWizard.swift` (`PresetDraftRegistry`) | `SessionStore.swift` 패턴 미러링, 독립 |
| 16 | WO-P16: `/config` 패널 TS 원복 (Q2) [구현됨: `ConfigPanel.swift:24-105,342-436,755-761,906-940`] | Q2 | `ConfigPanel.swift` | `dmPolicy` 행 제거, `locale` 원위치, `renderDecline`이 `render.enabled` 끄지 않게 |
| 17 | WO-P17: 권한 타임아웃 제거 + Codex 자동승인 분리 (Q4) [완료: 1장 H3/H25 참고] | H3, H25 | `PermissionGate.swift`, `CodexSessionBridge.swift` | 독립 |
| 18 | WO-P18: 로거 포팅 (`src/core/logger.ts`) [완료: 1장 C11 참고] | C11 | `Session/Log.swift`(신규), 전역(모든 `print`/`fputs` 호출부) | **가장 넓게 퍼짐 — 마지막에 진행**(다른 WO들이 먼저 끝나 print 호출부가 안정된 뒤 일괄 교체) |

완료 판정은 매 WO 공통: `swift build --package-path swift` 성공 + 해당 영역 유닛 테스트 신규 작성·필터 통과 + 문서(`docs/swift-port-parity-gaps.md`) 해당 C#/H# 옆에 `[구현됨: file:line]` 표기.
