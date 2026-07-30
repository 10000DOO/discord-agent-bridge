# 설계: `/orchestration` 프로젝트 스코프 전환

- 상태: **FINAL — 미결 사항 3건 모두 사용자 확정 완료. 구현 착수 가능.**
- 대상: Swift (`swift/Sources/DiscordAgentBridge`, `swift/Sources/dab`) + TypeScript sidecar (`src/`)
- 작성: ARCH (design-only, 코드 미수정)

---

## 0. 왜 이 문서가 "As-is/Impact/Migration/Rollback"을 포함하는가

`/orchestration`은 **이미 존재하는 커맨드**이고 이미 배포된 동작(전역 3-백엔드 설치)을 갖고 있다. 이번 요청은 그 동작을 완전히 다른 스코프(세션 채널 전용, 프로젝트 로컬 설치, 세션 재시작)로 바꾸는 것이므로 "기존 구조 변경" 규칙(As-is/To-be, Impact, Migration, Rollback 4종 필수)이 적용된다.

---

## 1. As-Is (현재 동작 — 코드로 확인함)

### 1.1 현재 `/orchestration`의 실제 동작

- 등록: `SlashCommandSpec.swift:236-241` `orchestrationCommandSpec()` — 채널 제한 없음, 관리자 권한도 요구하지 않음(`requiresAdministrator` 기본값 false).
- 디스패치: `DabMain.swift:1191-1207` — 인터랙션을 defer한 뒤 `OrchestrationInstaller.install(homes: .standard())`를 호출하고 결과 요약을 에페메럴로 응답.
- `OrchestrationHomes.standard()` (`Orchestration/OrchestrationInstaller.swift:16-23`) → `~/.claude`, `~/.codex`, `~/.grok` (**항상 전역 홈, 세션/프로젝트와 무관**).
- `OrchestrationInstaller.install(homes:)`가 Claude/Codex/Grok **세 백엔드 모두**에 대해:
  - `CLAUDE.md`/`AGENTS.md`: 마커(`<!-- dab-orchestration BEGIN/END -->`)로 감싼 블록을 "있으면 제거 후 파일 끝에 재추가" (`replaceMarkedBlock`) — 기존 파일의 다른 내용은 보존.
  - `skills/{id}/SKILL.md` 4개, `agents/{id}.md|.toml` 5개: 디렉터리/파일을 **삭제 후 재작성** (이미 delete-then-recreate 멱등 패턴 존재, `install_removesThenRecreatesSkillsAndAgents` 테스트로 검증됨).
  - Claude만 추가로 `settings.json`의 `enabledPlugins`에 LSP 플러그인 2개를 강제 on (`ensureLSPPluginsEnabled`).
  - Grok만 추가로 `config.toml`/`lsp.json` LSP 설정 patch.
- 콘텐츠 출처: `Orchestration/OrchestrationBundle.swift`에 **Swift 문자열 리터럴로 하드코딩**되어 있음 (4 skills + 5 subagents + rules block). 주석에 "원본은 `docs/orchestration-slim-guide.md`/`docs/orchestration-skill-subagent-specs.md`을 DAB-슬림화해 옮겨적었다"고 명시 — 즉 **런타임에 문서 폴더를 읽지 않고, 사람이 수동으로 Swift 리터럴로 옮겨 심는 것이 이 저장소의 기존 관례**.
- 세션 재시작/종료 로직 **없음** — 파일만 쓰고 끝난다.
- `docs/sample/`의 27개 파일(1 CLAUDE.md + 6 agents + 20 skills, 132KB)은 `OrchestrationBundle`과 **내용이 다른, 더 최신/완전한 세트**이며 현재 어떤 코드에서도 참조되지 않는다.

### 1.2 채널 종류 판별 — 기존 관례

`Session/GuildChannels.swift:39-45` `GuildChannelNames`:
```
controlCategory = "🤖 Agent"
controlChannel  = "session-generator"
statusChannel   = "agent-status"
sessionsCategory = "Agent - Sessions"
redmineReportChannel = "redmine-report"
```
길드별 실제 채널 ID는 `ConfigStore`가 `servers/<guildId>.json`에 `ServerConfig.channels: ServerChannels?` (categoryId/controlChannelId/sessionsCategoryId/statusChannelId)와 `ServerConfig.redmine?.reportChannelId`로 영속화한다 (`ConfigSchema.swift:418,475,489`).

**그런데 현재 어떤 슬래시 커맨드도 "이 채널이 control/status/redmine 채널인지"를 명시적으로 검사하지 않는다.** 대신 대부분의 커맨드(`/model`,`/effort`,`/clear`,`/mode perm` 등)는 `SessionStore.shared.binding(channelId:)` / `SessionRegistry.shared.binding(channelId:)`에 바인딩이 있는지만 보고, 없으면 `router.noSession`("이 채널에 바인딩된 세션이 없습니다. `/agent start`로 시작하세요.")으로 거절한다. control/status/redmine 채널은 보통 세션 바인딩이 없기 때문에 **결과적으로만** 걸러진다 — 하지만 `sessionsCategoryId`가 비어 있는 소규모 길드에서는 `/agent start`의 폴백 경로(`GuildChannels.swift:185-205 resolveSessionChannelId`)가 **원래 커맨드를 실행한 채널에 그대로 바인딩**할 수 있으므로, `session-generator` 채널 자체에 세션이 바인딩되는 경우가 실제로 존재할 수 있다. 즉 "바인딩 존재 여부"만으로는 세 채널을 확실히 걸러낼 수 없다 — **명시적 채널-종류 가드가 별도로 필요하다.**

"잘못된 컨텍스트에서 커맨드 실행" 거절의 기존 관례는 `auth.denied`를 DM 컨텍스트에 재사용하는 것 (`DabMain.swift:971,1021`: `I18n.t("auth.denied", ["reason": "DM"])`). 채널-종류 전용 메시지 키는 아직 없다.

### 1.3 세션 재시작(`/clear`)의 실제 메커니즘

`DabMain.swift:653-671` `case "clear"` → `SessionLifecycle.clearChannel(...)` (`SessionLifecycle.swift:184-218`):
1. `resolveSession()`으로 현재 `PersistedSession` 로드 (스토어 우선, 없으면 레지스트리+`defaultCwd`로 스텁 구성).
2. `backendSessionId = nil`, `lifecycleGeneration = UUID()`, 타임스탬프 갱신 → **먼저 스토어에 upsert**.
3. `stopAllBridges(channelId:)` — Claude/Codex/Grok 세 브리지 모두에 정지 요청(살아있는 프로세스가 있는 백엔드가 어느 쪽인지 확신할 수 없으므로 항상 전부 정지).
4. `registry.bind(channelId:, sessionConfig(from: session))`로 레지스트리 재바인딩.
5. 감사 로그 기록.

**중요:** 이 흐름은 "즉시 새 프로세스를 스폰"하지 않는다. 다음 사용자 메시지(다음 턴)가 올 때 `DabSessionBridge`의 ensure 경로(`DabSessionBridge.swift:~270-410`)가 `backendSessionId == nil`이므로 **fresh 세션으로 재연결**한다 — 이것이 사용자가 말한 "새 세션을 연결하는 작업"의 정체다. 새 채널을 만들거나 옮기지 않고, **같은 채널에 바인딩된 채로 다음 턴에 새 컨텍스트로 시작**하는 것.

### 1.4 실제 `claude` 프로세스가 뜨는 지점 — Swift가 아니라 TS 사이드카

Swift는 `claude` CLI를 직접 spawn하지 않는다. `DabSessionBridge`는 Node.js **사이드카 프로세스**(`resolveClaudeSidecarSpawn()` → `node dist/sidecar/claude/cli.js`, 저장소 내 `src/sidecar/claude/cli.ts`)와 NDJSON RPC로 통신하고, `sessionStart`/`sessionResume` RPC(`SessionStartParams`, `Sidecar/Protocol.swift:61-141`)를 보낸다. 사이드카(`src/sidecar/claude/sessionBridge.ts` → `src/modes/claude/session.ts`)가 **Claude Agent SDK**(`@anthropic-ai/claude-agent-sdk`)의 `query()`를 호출하며, 그 SDK의 `Options`가 CLI 플래그에 대응한다.

**결정적 발견**: `src/modes/claude/session.ts:161`에 이미 다음이 하드코딩되어 있다.
```ts
settingSources: ['user', 'project', 'local'],
```
즉 지금도 **모든 Claude 세션이 이미 project(`.claude/`)를 읽는다** — 다만 user(`~/.claude`)+local도 함께 얹는다. 요청하신 `--setting-sources project`(=SDK `settingSources: ['project']`)는 이 하드코딩을 **채널별로 조건부**로 바꿔야 하는 것이며, 이는 Swift만으로 끝나지 않고 **TS 사이드카까지 관통하는 값 하나를 새로 배선**해야 함을 의미한다. 이 값은 지금 `SessionStartParams`(Swift/TS 양쪽) 어디에도 존재하지 않는다.

---

## 2. To-Be — 요구사항 정리

1. `/orchestration`은 "세션 채널"(활성 에이전트 세션이 바인딩되어 있고, session-generator/agent-status/redmine-report가 아닌 채널)에서만 동작. 그 외 채널에서는 거절.
2. 성공 시:
   a. `<cwd>/.claude/`가 이미 존재하면, 지우기 전에 그 디렉터리 전체를 zip으로 백업(`<cwd>/.claude-backups/orchestration-{stamp}.zip`). 존재하지 않으면(최초 실행) 이 단계는 완전히 스킵.
   b. 그 채널이 바인딩된 프로젝트 폴더(`cwd`) 아래 `.claude/CLAUDE.md` + `.claude/agents/*.md` + `.claude/skills/*/SKILL.md`를 `docs/sample/` 27개 파일 내용으로 **통째로 삭제 후 재작성**. **전역 `~/.claude/`는 절대 건드리지 않음.**
   c. 그 채널의 세션을 `/clear`와 동일한 메커니즘(스토어 upsert → 전 브리지 정지 → 레지스트리 재바인딩)으로 초기화하되, **다음 세션 시작부터 `settingSources: ['project']`만 사용**하도록 채널 상태에 플래그를 남김.
3. 재호출(이미 활성 상태)도 **완전히 같은 절차**(백업 → 삭제 후 재생성 → 재시작)를 반복 — "이미 켜져 있는지" 별도 판별이 필요 없는 이유는 §5 참조. 백업 단계의 유일한 분기는 "`.claude/`가 실존하는가"라는 파일시스템 존재 검사 하나뿐이며, 이는 상태 플래그가 아니라 §5가 이미 세운 멱등성 원칙과 같은 성격의 전제조건 검사다.

---

## 3. 아키텍처 개요

```
Discord "/orchestration" 인터랙션
        │
        ▼
DabMain.swift  case "orchestration"
        │  1) 채널-종류 가드 (GuildChannels.isControlPlaneChannel)
        │  2) 세션 바인딩 존재 + cwd 확보 (SessionStore.binding(channelId:).cwd)
        │           │ 실패 시 각각 거절 메시지, 아래로 진행 안 함
        ▼
OrchestrationInstaller.installProject(root: cwd)
        │  0) <root>/.claude/ 가 존재하면 zip으로 백업 (없으면 스킵) — 실패 시 여기서 즉시 중단
        │     → <root>/.claude-backups/orchestration-{stamp}.zip
        │  OrchestrationProjectBundle (docs/sample 27개 파일 내용의 Swift 리터럴 사본)
        │  - CLAUDE.md: 전체 파일 삭제 후 재작성
        │  - skills/{id}/, agents/{id}.md: 삭제 후 재작성 (기존 3-backend 설치와 동일 패턴)
        ▼
SessionLifecycle.enableOrchestrationMode(channelId:...)   ← clearChannel과 동형 시블링 메서드
        │  PersistedSession.projectSettingSourcesOnly = true 로 세팅한 뒤
        │  clearChannel과 동일한 절차(backendSessionId=nil, stopAllBridges, registry rebind)
        ▼
(다음 턴) DabSessionBridge ensure()
        │  SessionStartParams.projectSettingSourcesOnly = persisted.projectSettingSourcesOnly
        ▼  (RPC)
src/sidecar/claude/sessionBridge.ts buildContext()
        │  ModeContext.projectSettingSourcesOnly 전달
        ▼
src/modes/claude/session.ts
        settingSources: ctx.projectSettingSourcesOnly ? ['project'] : ['user','project','local']
```

---

## 4. 인터페이스 계약 (신규/변경 시그니처)

### 4.1 Swift — 채널 종류 판별 (신규, `GuildChannels.swift`)
```swift
/// session-generator / agent-status / redmine-report 채널인지 판별하는 순수 함수.
/// 세션 바인딩 유무와 무관하게 항상 우선 검사된다 (바인딩만으로는 걸러지지 않는 폴백 경로가 있음, §1.2).
public func isControlPlaneChannel(
    channelId: String,
    serverChannels: ServerChannels?,
    redmineReportChannelId: String?
) -> Bool
```

### 4.2 Swift — 프로젝트 설치기 + 백업 (신규, `Orchestration/OrchestrationInstaller.swift`)

새 파일을 만들지 않고 기존 `OrchestrationInstaller.swift`에 메서드 2개만 추가한다(ponytail: 파일 수 최소화 — 이 백업 로직은 `installProject` 하나만을 위해 존재하므로 별도 타입/파일을 둘 이유가 없다).

```swift
extension OrchestrationInstaller {
    /// `<root>/.claude/{CLAUDE.md, agents/*.md, skills/*/SKILL.md}`만 다룸.
    /// Codex/Grok/settings.json/LSP 패치는 대상 아님(§6 결정 ①).
    /// 0단계로 기존 `.claude/`를 zip 백업한 뒤 진행 — 백업 실패 시 삭제/재작성 없이 즉시 중단.
    public static func installProject(
        root: URL,               // = <project cwd>
        fileManager: FileManager = .default
    ) -> OrchestrationInstallReport   // 기존 타입 + backupPath 필드 1개 추가 (§4.2 하단)
}

/// `<root>/.claude`가 있으면 `<root>/.claude-backups/orchestration-{stamp}.zip`으로 백업.
/// 없으면 (path: nil, error: nil) — 최초 실행에는 아무것도 하지 않는다(단일 무조건 경로,
/// "이미 오케스트레이션 켜져 있는지" 상태 플래그 아님 — 순수 존재 검사, §5와 동일 원칙).
/// `/usr/bin/zip -r -q`로 셸아웃 — 이 저장소가 이미 Process()로 시스템 바이너리를 호출하는
/// 관례(Update/Installer.swift runUpdateCommand/spawnDetachedDab)를 그대로 따름, 새 의존성 없음.
private static func backupExistingClaudeDir(
    root: URL, fileManager: FileManager
) -> (path: String?, error: String?)
```

`OrchestrationInstallReport`에 필드 1개 추가:
```swift
public struct OrchestrationInstallReport: Sendable, Equatable {
    public var removedPaths: [String]
    public var writtenPaths: [String]
    public var errors: [String]
    public var backupPath: String?   // 신규 — 백업 zip 경로. 백업 안 했으면 nil.
}
```

#### 4.2a 백업 메커니즘 — 구체 설계 (결정 ② 확정 반영)

**위치**: `<project-root>/.claude-backups/orchestration-{stamp}.zip`
- 사용자 제안 경로를 그대로 채택. `.claude/`(지워질 대상) 안이 아니라 프로젝트 루트의 별도 dot-디렉터리에 둔다 — 지워질 디렉터리 안에 백업을 두면 삭제 시점에 백업 자체가 같이 사라지거나 zip이 자기 자신을 포함하는 문제가 생긴다.
- 이 저장소에 이미 있는 "툴 산출물은 프로젝트 루트의 dot-디렉터리에" 관례(`docs/sample`의 `issue-analysis`/`impact-analyzer` 스킬이 쓰는 `.dab-index/`)와 결이 같다. `.claude-backups/`도 같은 이유로 `.gitignore`에 없으면 추가하는 것을 권장하되(백업 zip에는 이전 프로젝트 설정이 통째로 들어가므로 커밋 대상이 아님), 이번 요구사항 범위는 아니므로 **체크리스트에 "선택 사항"으로만 남긴다** — 강제하지 않음.
- 타임스탬프: 이 저장소에 이미 있는 백업 관례인 `SessionStore.swift:410-422 backupCorruptFileAndReset`과 동일한 스타일 — `ISO8601DateFormatter` 문자열의 `:`를 `-`로 치환. 실제로 그 파일에 이미 있는 내부(모듈 전역) 헬퍼 `iso8601Now()`(`SessionPersist.swift:67`)를 그대로 호출하면 된다 — 같은 모듈(`DiscordAgentBridge`)이라 새로 만들 필요 없음.

**트리거**: `<root>/.claude` 존재 여부 단 하나. `FileManager.fileExists(atPath:)`로 확인 — 있으면 zip, 없으면(최초 실행) 완전히 스킵하고 `backupPath = nil`. "오케스트레이션이 이미 켜져 있는가"라는 상태를 조회하는 것이 아니라 "지울 대상이 실제로 존재하는가"라는 사전조건 확인이므로 §5의 무분기 철학과 그대로 맞는다 — 최초 실행과 재실행이 같은 코드 경로를 타되, 이 한 줄의 존재 검사만 자연히 다르게 평가될 뿐이다.

**백업 범위**: `.claude/` 디렉터리 전체(트리 전체)를 zip — CLAUDE.md/agents/skills 세 가지만이 아니다. 이 봇이 실제로 건드리는 건 그 세 가지뿐이지만, 프로젝트의 `.claude/`에는 무관한 `settings.json`/`settings.local.json`/`mcp.json`/사람이 직접 추가한 다른 에이전트·스킬 등이 이미 있을 수 있고, 전체를 백업해 두면 무엇이 원래 있었는지와 무관하게 항상 완전한 복구가 가능하다. 부분 백업보다 코드도 더 단순하다(하위 경로를 골라내는 로직이 필요 없음).

**zip 생성 방법**: 이 저장소의 `Package.swift`에는 압축 관련 의존성이 전혀 없고(ZIPFoundation 등 없음), `Compression` 프레임워크나 `ditto`/`zip` 사용 이력도 없다 — 즉 "이미 쓰는 패턴"이 없다. 다만 시스템 바이너리를 `Process`로 셸아웃하는 관례는 이미 여러 곳에 있다(`Update/Installer.swift:365-410 runUpdateCommand`, `Update/Installer.swift:770 spawnDetachedDab`, `DabMain.swift`/`FolderPanel.swift`/`UsageService.swift`의 `which` 호출). 새 SPM 의존성을 추가하는 대신 그 관례를 그대로 따라 macOS가 기본 제공하는 `/usr/bin/zip`을 동기적으로 호출한다:
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
process.currentDirectoryURL = root                       // cwd = 프로젝트 루트
process.arguments = ["-r", "-q", zipURL.path, ".claude"]  // .claude/를 상대경로로 압축 → 나중에 unzip 시 .claude/ 그대로 복원
try process.run(); process.waitUntilExit()
```
`runUpdateCommand`가 쓰는 비동기+장시간 타임아웃 캡처 구조는 여기서 과함(수십 KB짜리 마크다운 폴더 압축은 순간적으로 끝남) — `installProject`가 이미 동기 함수이므로 `spawnDetachedDab`처럼 더 단순한 동기 `Process` 호출로 충분하다.

**실패 시 처리 (안전 우선)**: `process.terminationStatus != 0`이거나 `run()`이 throw하면 **백업 실패로 보고 그 즉시 `installProject` 전체를 중단** — CLAUDE.md/agents/skills 삭제·재작성을 진행하지 않는다. 이는 새로 만든 규칙이 아니라 이 저장소가 이미 `backupCorruptFileAndReset`에 명시적으로 남겨둔 원칙("A failed backup must never be followed by overwriting the source file")을 그대로 적용한 것이다. 이 경우 `OrchestrationInstallReport.errors`에 사유를 담아 반환하고, 세션 재시작(`enableOrchestrationMode`)도 호출하지 않는다.

**최초 실행 vs 재실행 — 동일 무분기 경로 확인**: `installProject` 본문은 항상 `backupExistingClaudeDir` → (CLAUDE.md 삭제/재작성) → (skills/agents 삭제/재작성) 순서로 실행되는 **단일 코드 경로**다. 최초 실행은 1번째 단계에서 존재 검사가 거짓이라 백업을 건너뛸 뿐이고, 재실행은 같은 검사가 참이라 zip을 만들 뿐 — "오케스트레이션이 이미 활성 상태인지"를 조회하는 별도 분기나 상태 플래그는 여전히 없다(§5의 결론과 완전히 일치).

**Discord 응답 메시지 반영**: 백업이 실제로 일어났을 때만(`backupPath != nil`) 한 줄 추가 — 예: "이전 `.claude/` 설정을 `.claude-backups/orchestration-2026-07-30T...zip`으로 백업했습니다." 백업이 없었으면(최초 실행) 이 줄 자체를 생략 — 기존 `OrchestrationInstallReport.summaryMarkdown`이 이미 쓰는 "비어 있으면 섹션 자체를 생략" 스타일과 동일.

### 4.3 Swift — 콘텐츠 번들 (신규 파일 `Orchestration/OrchestrationProjectBundle.swift`)
```swift
public enum OrchestrationProjectBundle {
    public struct Skill: Sendable, Equatable { public let id: String; public let markdown: String }
    public struct Subagent: Sendable, Equatable { public let id: String; public let markdown: String }

    public static let claudeMdBody: String          // docs/sample/CLAUDE.md 전체 내용 그대로
    public static let skills: [Skill]                // docs/sample/skills/*/SKILL.md 20개, 파일 그대로
    public static let subagents: [Subagent]           // docs/sample/agents/*.md 6개, 파일 그대로 (frontmatter 포함)
}
```
`OrchestrationBundle`(기존)과 달리 백엔드별 필드 분리가 필요 없다 — Claude 전용이라 파일 내용을 그대로 옮기면 끝.

### 4.4 Swift — 채널 세션 상태에 플래그 추가
```swift
// SessionStore.swift: PersistedSession
public var projectSettingSourcesOnly: Bool = false   // 디코드 시 키 없으면 false (archived와 동일한 하위호환 패턴)

// SessionRegistry.swift: SessionConfig
public var projectSettingSourcesOnly: Bool = false

// BindingUpdate.swift: sessionConfig(from:) 에 한 줄 추가해 위 필드 전달
```

### 4.5 Swift — 세션 재시작 메서드 (신규, `SessionLifecycle.swift`)
`clearChannel`(§1.3)과 동형인 4번째 시블링(기존에도 `clearChannel`/`rebindBackend`/`reconfigureBinding` 3개가 이미 이 패턴으로 공존 — 신규 조합마다 전용 메서드를 두는 것이 이 파일의 기존 관례).
```swift
@discardableResult
public func enableOrchestrationMode(
    channelId: String, actorId: String, guildId: String,
    roleTier: String = "execute", defaultCwd: String = NSHomeDirectory()
) async -> Bool
// resolveSession → projectSettingSourcesOnly=true, backendSessionId=nil, lifecycleGeneration 갱신
// → store.upsert → stopAllBridges → registry.bind → audit(action:"orchestration")
```

### 4.6 Swift — RPC 파라미터 (`Sidecar/Protocol.swift`)
```swift
public struct SessionStartParams: Sendable, Equatable {
    // ... 기존 필드 ...
    public var projectSettingSourcesOnly: Bool = false
    // asParams()에서 true일 때만 "projectSettingSourcesOnly": .bool(true) 추가 (기존 옵셔널 필드들과 동일한 절약 스타일)
}
```
`DabSessionBridge.swift`의 `SessionStartParams(...)` 생성 지점(~line 403-406, 기존 `sessionCfg` 조립부 바로 아래)에서 `persisted?.projectSettingSourcesOnly ?? false`를 채워 넣는다.

### 4.7 TypeScript — 동일 값 관통
```ts
// src/sidecar/claude/protocol.ts — SessionStartParams
projectSettingSourcesOnly?: boolean;

// src/core/contracts.ts — ModeContext
projectSettingSourcesOnly?: boolean;

// src/sidecar/claude/sessionBridge.ts — buildContext()
...(params.projectSettingSourcesOnly !== undefined
  ? { projectSettingSourcesOnly: params.projectSettingSourcesOnly } : {}),

// src/modes/claude/session.ts:161
settingSources: ctx.projectSettingSourcesOnly ? ['project'] : ['user', 'project', 'local'],
```

### 4.8 `/orchestration` 디스패치 (`DabMain.swift`, `case "orchestration":` 전면 교체)
의사 흐름(기존 defer-then-updateOriginalInteractionResponse 패턴 그대로 재사용):
```
defer ephemeral ack
serverChannels = ConfigStore.shared.loadServerConfig(guildId:)?.channels
redmineReportId = ConfigStore.shared.loadServerConfig(guildId:)?.redmine?.reportChannelId
if isControlPlaneChannel(channelId, serverChannels, redmineReportId):
    respond(I18n.t("orchestration.wrongChannel")); return
guard let cwd = SessionStore.shared.binding(channelId:)?.cwd else:
    respond(I18n.t("router.noSession")); return   // 기존 키 재사용
report = OrchestrationInstaller.installProject(root: URL(fileURLWithPath: cwd))
guard report.errors.isEmpty else:
    respond(report.errors를 포함한 실패 메시지); return   // 백업 실패 시 여기서 멈춤(§4.2a), 세션은 건드리지 않음
_ = await SessionLifecycle.shared.enableOrchestrationMode(channelId:, actorId:, guildId:, roleTier: tier, defaultCwd: cwd)
respond(report를 새 i18n 키로 포맷 + backupPath가 있으면 백업 경로 한 줄 + "다음 메시지부터 새 세션으로 재연결됩니다" 안내)
```

### 4.9 i18n (`I18n.swift`)
- 신규: `orchestration.wrongChannel` (ko/en) — "이 명령어는 세션 채널(프로젝트 폴더가 연결된 채널)에서만 사용할 수 있습니다." / "This command can only be used in a session channel bound to a project folder."
- `router.noSession` 재사용 (신규 키 불필요).
- 신규: 프로젝트 설치 결과 포맷용 키 3~4개 (기존 `orchestration.install.*`의 Claude/Codex/Grok 경로 안내 부분만 프로젝트 경로 안내로 교체한 버전). 기존 `orchestration.install.*` 전체를 재사용하지 않는 이유: 그 카피는 "Claude/Codex/Grok 세 백엔드"를 명시적으로 언급해 새 동작과 맞지 않음.
- 신규: `orchestration.project.backedUp` (ko/en, `{path}` 자리표시자) — `backupPath`가 non-nil일 때만 응답 끝에 한 줄 추가. 예: "이전 설정을 `{path}`로 백업했습니다." / "Backed up the previous configuration to `{path}`."

---

## 5. "이미 오케스트레이션 활성 상태"를 어떻게 판별할 것인가 — 판별 자체가 불필요하다

요구사항 2와 3을 나란히 놓고 보면: 최초 호출도, 재호출(이미 활성)도 **정확히 같은 절차**(파일 삭제 후 재생성 + 세션 초기화 + 플래그 세팅)를 수행한다. 다른 분기가 없다.

- 파일 쪽: `installProject`는 skills/agents 디렉터리를 항상 "있으면 삭제, 재생성"(`removeIfExists` 후 `ensureDir`+`writeFile`) — 이미 `OrchestrationInstaller`가 이 패턴으로 구현/테스트되어 있고(`install_removesThenRecreatesSkillsAndAgents`), 존재 여부를 사전에 몰라도 안전하게 멱등.
- 플래그 쪽: `projectSettingSourcesOnly = true`를 매번 무조건 쓴다 — 이미 true였어도 true를 다시 쓰는 것은 no-op.
- 세션 재시작 쪽: `enableOrchestrationMode`는 `clearChannel`과 마찬가지로 몇 번을 다시 호출해도 안전(매번 새 `lifecycleGeneration`, 매번 브리지 정지).

**따라서 "SessionStore/ConfigStore에 별도의 `orchestrationActive` 플래그를 두고 사전 조회"하는 메커니즘을 만들 필요가 없다** — 항상 같은 동작을 하면 되므로 사전 판별 자체가 불필요한 코드가 된다(YAGNI). 이것이 가장 단순하고 정확한 접근이라고 판단한 근거다.

굳이 파일 존재 여부로 "재설치였는지"를 사용자에게 알려주고 싶다면, `installProject`가 이미 반환하는 `OrchestrationInstallReport.removedPaths`(비어있지 않으면 재설치였다는 뜻)를 응답 메시지에 그대로 노출하면 충분하다 — 이 또한 기존 필드 재사용이지 신규 상태가 아니다.

---

## 6. 결정 사항 (사용자 확정 완료)

### ① 기존 "전역 3-백엔드 설치" 동작 — **폐기 확정**
`DabMain.swift`의 `case "orchestration"`을 §4.8 로직으로 전면 교체한다. `Orchestration/OrchestrationBundle.swift`/`OrchestrationInstaller.swift`에서 Codex/Grok 전용 코드(`installCodex`,`installGrok`,`ensureGrokLSPEnabled`,`codexAgentTOML`,`grokAgentMarkdown`, Grok LSP 헬퍼 `ensureGrokLSPFeatureFlag`/`ensureGrokLSPServers`), `OrchestrationHomes`, 그리고 Claude 전용이었던 `ensureLSPPluginsEnabled`/`ensureLSPPlugins`(§7에서 설명하듯 새 프로젝트 경로는 LSP settings.json을 건드리지 않으므로 이 역시 죽은 코드)까지 전부 제거한다. `OrchestrationInstallerTests.swift`의 3-backend 관련 테스트 케이스(`install_writesClaudeCodexGrokLayouts`, `install_claudeSettingsJson_*`, `install_grokConfig_*`, `ensureLSPPlugins_*`, `ensureGrokLSPFeatureFlag_*`, `ensureGrokLSPServers_*`, `codexAndGrokFormatHelpers_matchExistingShapes`)도 함께 제거한다.
`replaceMarkedBlock`/`markedRange`/`collapseTrailingWhitespace` 같은 범용 마커-블록 IO 헬퍼는 새 프로젝트 경로가 쓰지 않으므로(결정 ②: CLAUDE.md는 통째 덮어쓰기) 이것들도 사용처가 없어져 함께 제거 대상이다 — 남겨두면 테스트로 검증되던 죽은 코드가 된다.
`OrchestrationBundle.swift`(4 skills + 5 subagents + `alwaysRulesMarkdown`, 전역용 구버전 콘텐츠) 파일 자체도 더 이상 어디서도 참조되지 않으므로 삭제 대상.

### ② `.claude/` 교체 방식 — **"zip 백업 후 통째로 삭제·재작성"으로 확정**
사용자가 애초 제시된 두 옵션(통째 덮어쓰기만 / 마커 블록만 병합)을 모두 기각하고, 세 번째 방식을 지정: **삭제·덮어쓰기 전에 기존 `.claude/` 전체를 zip으로 백업**한 뒤, 백업이 성공했을 때만 §2 옵션 A(통째 삭제 후 재작성)를 그대로 진행. 구체 설계는 §4.2a. 마커 블록 병합 방식은 채택하지 않으므로 `replaceMarkedBlock` 재사용은 없다(위 ①에서 이미 정리 대상으로 반영됨).

### ③ `/orchestration` 실행 권한 티어 — **현행 유지 확정**
`requiresAdministrator: false` 그대로 둔다. `SlashCommandSpec.swift` 변경 없음(설명 문구만 §4.8/§7에 따라 갱신).

---

## 7. 영향 범위 (파일 단위)

| 파일 | 변경 |
|---|---|
| `swift/Sources/DiscordAgentBridge/Orchestration/OrchestrationProjectBundle.swift` | **신규.** docs/sample 27개 파일 내용을 Swift 리터럴로 이식 (기존 `OrchestrationBundle.swift`와 동일한 손 이식 관례). |
| `swift/Sources/DiscordAgentBridge/Orchestration/OrchestrationInstaller.swift` | `installProject(root:)` + `backupExistingClaudeDir(root:fileManager:)`(private) 추가, `OrchestrationInstallReport.backupPath` 필드 추가. **결정 ①에 따라 삭제**: `installClaude`(구버전, project 전용으로 교체)/`installCodex`/`installGrok`/`OrchestrationHomes`/`ensureGrokLSPEnabled`/`ensureGrokLSPFeatureFlag`/`ensureGrokLSPServers`/`ensureLSPPlugins`/`ensureLSPPluginsEnabled`/`codexAgentTOML`/`grokAgentMarkdown`/`replaceMarkedBlock`/`markedRange`/`upsertMarkedBlock`/`writeRulesFile`(마커 병합 미채택, 결정 ②)/`patchEnabledPlugins`류 JSON 서지컬 패치 헬퍼 일체. |
| `swift/Sources/DiscordAgentBridge/Orchestration/OrchestrationBundle.swift` | **삭제 확정** (결정 ①) — 전역 3-백엔드 콘텐츠(4 skills+5 subagents+`alwaysRulesMarkdown`)는 더 이상 어디서도 참조되지 않음. |
| `swift/Sources/DiscordAgentBridge/Session/GuildChannels.swift` | `isControlPlaneChannel(...)` 순수 함수 추가 (기존 `shouldDeleteSessionChannelOnClose`와 같은 결의 함수). |
| `swift/Sources/DiscordAgentBridge/Session/SessionStore.swift` | `PersistedSession.projectSettingSourcesOnly: Bool` 추가 (Codable, decode 시 미존재→false). |
| `swift/Sources/DiscordAgentBridge/Session/SessionRegistry.swift` | `SessionConfig.projectSettingSourcesOnly: Bool` 추가. |
| `swift/Sources/DiscordAgentBridge/Session/BindingUpdate.swift` | `sessionConfig(from:)`에 필드 전달 한 줄 추가. |
| `swift/Sources/DiscordAgentBridge/Session/SessionLifecycle.swift` | `enableOrchestrationMode(...)` 신규 메서드 (`clearChannel` 시블링). |
| `swift/Sources/DiscordAgentBridge/Sidecar/Protocol.swift` | `SessionStartParams.projectSettingSourcesOnly` 추가 + `asParams()` 반영. |
| `swift/Sources/DiscordAgentBridge/Bridges/DabSessionBridge.swift` | ensure() 조립부(~line 398-406 인근)에서 `persisted?.projectSettingSourcesOnly` 채워 전달. |
| `swift/Sources/DiscordAgentBridge/Session/SlashCommandSpec.swift` | `orchestrationCommandSpec()` 설명 문구를 프로젝트 스코프로 갱신. |
| `swift/Sources/DiscordAgentBridge/I18n.swift` | 신규 키: `orchestration.wrongChannel`, `orchestration.project.backedUp`, 프로젝트 설치 결과 포맷 키 3~4개 (ko/en). **삭제 확정**(결정 ①): `orchestration.install.title/removedHeading/writtenHeading/errorHeading/noChanges/reinstallNote/claudePaths/codexPaths/grokPaths` 전체. |
| `swift/Sources/dab/DabMain.swift` | `case "orchestration":` 본문 교체 (§4.8). |
| `src/sidecar/claude/protocol.ts` | `SessionStartParams.projectSettingSourcesOnly?: boolean` 추가. |
| `src/core/contracts.ts` | `ModeContext.projectSettingSourcesOnly?: boolean` 추가. |
| `src/sidecar/claude/sessionBridge.ts` | `buildContext()`에서 필드 전달. |
| `src/modes/claude/session.ts` | `settingSources` 조건부화 (line 161 인근). |
| `swift/Tests/DiscordAgentBridgeTests/OrchestrationInstallerTests.swift` | `installProject` 케이스 추가(최초 실행/재실행 멱등성, 백업 zip 생성 확인, 백업 실패 시 삭제·재작성 중단 확인). **삭제 확정**(결정 ①): `install_writesClaudeCodexGrokLayouts`, `install_claudeSettingsJson_*`, `install_grokConfig_*`, `ensureLSPPlugins_*`, `ensureGrokLSPFeatureFlag_*`, `ensureGrokLSPServers_*`, `codexAndGrokFormatHelpers_matchExistingShapes`, `replaceMarkedBlock_removesThenAppendsAtEnd`, `install_removesThenRecreatesSkillsAndAgents`(구 3-backend 버전 — `installProject`용 신규 케이스로 대체). |
| `swift/Tests/DiscordAgentBridgeTests/SlashCommandSpecTests.swift` | 설명 문구 갱신 반영 (필요 시). |
| `swift/Tests/DiscordAgentBridgeTests/SessionLifecycleTests.swift` | `enableOrchestrationMode` 테스트 추가. |
| `swift/Tests/DiscordAgentBridgeTests/DabSessionBridgeTests.swift` | `projectSettingSourcesOnly` 전달 검증 추가. |
| `src/modes/claude/session.test.ts` | `settingSources` 분기 테스트 추가. |

---

## 8. 마이그레이션 단계

결정 ①②③ 확정 완료 — 아래 순서로 착수 가능.

1. `OrchestrationProjectBundle.swift` 신규 작성 (docs/sample 27개 파일 손 이식) — 순수 데이터 추가라 리스크 없음, 먼저 진행 가능.
2. Swift 상태 계층 확장: `PersistedSession`→`SessionConfig`→`sessionConfig(from:)`→`SessionStartParams` 순으로 필드 배선 (하위 호환: 기존 저장된 `swift-state.json`에 키가 없으면 false로 디코드 — `archived` 필드가 이미 쓰는 것과 동일한 안전장치).
3. TS 쪽 동일 필드 배선 (`protocol.ts`→`sessionBridge.ts`→`contracts.ts`→`session.ts`).
4. `GuildChannels.isControlPlaneChannel` + `SessionLifecycle.enableOrchestrationMode` 구현.
5. `OrchestrationInstaller`에 `backupExistingClaudeDir`(§4.2a) + `installProject`(백업 호출 → 실패 시 중단 → CLAUDE.md/agents/skills 삭제-재작성) 구현. `OrchestrationInstallReport.backupPath` 필드 추가.
6. `DabMain.swift`의 `case "orchestration"` 교체(§4.8, 백업 실패 분기 포함), `SlashCommandSpec`/`I18n` 문구 갱신(`orchestration.wrongChannel`/`orchestration.project.backedUp` 등 신규 키 추가).
7. **별도 커밋으로 분리**: 구 3-backend 코드 제거 — `OrchestrationBundle.swift` 삭제, `OrchestrationInstaller.swift`에서 결정 ① 목록의 Codex/Grok/마커-병합/LSP-패치 헬퍼 전체 삭제, `OrchestrationInstallerTests.swift`의 대응 테스트 삭제, `I18n.swift`의 `orchestration.install.*` 구 키 삭제. 리버트 용이성 확보를 위해 단계 1~6과 분리.
8. 전 구간 테스트(Swift `swift test`, TS `npm test`/해당 러너) 통과 확인 후 사람 테스트 요청 — 특히 백업 zip 생성/실패-중단 시나리오를 수동으로도 1회 확인.

---

## 9. 롤백 플랜

- 이번 변경은 기존 `PersistedSession`/`SessionConfig`/`SessionStartParams`에 **필드를 추가만** 하고 기존 필드의 의미를 바꾸지 않으므로, Swift/TS 양쪽 커밋을 되돌리면 `swift-state.json`의 새 필드는 단순히 무시되고(구버전 디코더가 모르는 키) 즉시 이전 동작으로 복귀 가능.
- 구 3-backend `OrchestrationInstaller`/`OrchestrationBundle` 코드 삭제는 별도 커밋(마이그레이션 단계 7)으로 분리해 두었으므로, 필요하면 그 커밋만 revert해 전역 설치 기능을 원복할 수 있다.
- `.claude/` 백업 zip은 실행마다 새 타임스탬프 파일로 누적되므로(덮어쓰지 않음), 통째 삭제-재작성이 잘못되었더라도 `<root>/.claude-backups/`의 최신 zip을 그 프로젝트의 `.claude/` 자리에 풀어주는 것만으로 사람이 수동 복구 가능 — 이 복구 경로 자체는 코드가 아니라 zip 존재 여부에만 의존하므로 봇 코드를 되돌릴 필요조차 없다.

---

## 10. 체크리스트

- [ ] `OrchestrationProjectBundle.swift` 작성 (docs/sample 27개 파일 1:1 이식, 드리프트 방지를 위해 각 파일 상단에 "source: docs/sample/..." 주석 남기기 권장)
- [ ] `PersistedSession`/`SessionConfig`/`BindingUpdate`/`SessionStartParams` 필드 배선 (Swift)
- [ ] TS `protocol.ts`/`contracts.ts`/`sessionBridge.ts`/`session.ts` 필드 배선
- [ ] `GuildChannels.isControlPlaneChannel` 구현 + 단위 테스트
- [ ] `SessionLifecycle.enableOrchestrationMode` 구현 + 단위 테스트
- [ ] `OrchestrationInstaller.backupExistingClaudeDir` 구현 + 단위 테스트(존재/부재 분기, zip 성공/실패)
- [ ] `OrchestrationInstaller.installProject` 구현 + 멱등성 테스트(최초 실행/재호출 2회 시나리오, 백업 실패 시 삭제-재작성이 실행되지 않는지)
- [ ] `DabMain.swift` `case "orchestration"` 교체 + 채널별 거절 메시지 + 백업 실패 메시지 수동 검증
- [ ] 구 3-backend 코드/테스트/`OrchestrationBundle.swift`/`orchestration.install.*` i18n 키 제거 — **별도 커밋**
- [ ] (선택) `.claude-backups/`를 프로젝트 `.gitignore`에 추가하는 절차 필요 여부 재검토 — 이번 범위에는 미포함
- [ ] `swift test` / TS 테스트 스위트 통과
- [ ] 사람 최종 테스트: 세션 채널에서 실행 → `.claude/`가 이미 있던 경우 백업 zip 생성 확인 → 파일 삭제-재생성 확인 → 다음 메시지가 새 컨텍스트로 온다는 것 확인 → 재호출 시 다시 백업 후 삭제-재생성됨을 확인 → session-generator/agent-status/redmine-report에서 거절되는지 확인
