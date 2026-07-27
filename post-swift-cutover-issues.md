# TS→Swift 전환 직후 이슈 3건 + 유저 기반 권한 커맨드 — 이슈 분석

> 상태: `검증중` · 갱신: 2026-07-26 · 브랜치: `plan/swift-port` · 다음 액션: 7-2 사람 검증(사용자).
> 상태 단계(고정): `분석중` → `원인확정` → `설계확정` → `구현중` → `검증중` → `완료`
> ⚠️ 본문의 file:line은 드리프트할 수 있음 — 실행 전 반드시 심볼명으로 재확인할 것

---

## 0. 문서 규칙

이슈가 3건 + 신규 기능 1건이라 각각을 하위 절(A/B/C/D)로 나눠 담는다. 다른 규칙은 FEATURE/ISSUE 템플릿 공통 원칙(증거 필수, 임의 결정 금지, 검증 이원화, 1회 1WO)을 그대로 따른다.

---

# Part A — 분석·설계 (사람 확인용)

## A. 이슈1 — 메시지 경로 `isAdministrator` 고정값 (OK-2)

### 재현
서버 관리자(Discord Administrator 권한 보유)가 **일반 메시지**로 봇에 명령하면 "권한이 없습니다: No authorized role for this actor (fail-secure)"로 거부됨. **슬래시 커맨드(`/agent` 등)는 정상 동작**(확인됨).

### 원인 (확정)
- `swift/Sources/dab/DabMain.swift:1706-1711` — 메시지 경로만 `AuthInput(..., isAdministrator: false)`로 고정. 주석: "(Q2) — the gateway message event does not carry member.permissions".
- 슬래시/인터랙션 경로 4곳(`DabMain.swift:266,747,892,1960`)은 `payload.member?.permissions?.contains(.administrator) ?? false`로 **실제 계산**함 — 인터랙션 페이로드에는 Discord가 계산된 permissions 필드를 실어주기 때문.
- TS(`src/discord/messageRouter.ts:155,243-246`)는 `memberIsAdministrator()`가 discord.js의 role 캐시 기반 편의 API로 실제 계산 — TS는 메시지 경로도 실제 admin 여부를 안다.
- `SWIFT_TS_PARITY_GAPS.md:25` (OK-2)에 "게이트웨이 권한 부재로 fail-secure" 로 의도적 OK-DIFF로 기록돼 있으나, **실제로는 고칠 수 있는 문제**임을 아래에서 확인.
- `Authorizer.swift:132-134` — `isAdministrator: true`면 역할 설정과 무관하게 무조건 admin. 즉 이 플래그만 정확히 계산되면 즉시 해결됨.

### 실현 가능성 확인 (완료)
DiscordBM의 `Gateway.GuildCreate`(`swift/.build/checkouts/DiscordBM/Sources/DiscordModels/Types/Gateway.swift:775-792`)는 `owner_id: UserSnowflake`와 `roles: [Role]`을 실어온다. `Role`(`.../Permission.swift:96,106`)은 `id: RoleSnowflake` + `permissions: StringBitField<Permission>`을 갖는다. 즉 **길드 참가/부팅 시 받는 GuildCreate 페이로드만으로 각 역할의 권한 비트를 전부 캐싱할 수 있고**, 이후 메시지 경로에서 `message.member.roles`(역할ID 목록)를 이 캐시와 대조해 Administrator 비트 보유 여부 + guild owner 여부를 직접 계산할 수 있다. 디스코드 권한 모델상 Administrator 비트는 채널 오버라이트를 무시하고 항상 전체 권한을 주므로, 오버라이트 계산 없이 "역할 permission 비트 OR" + "owner 여부"만으로 충분하다.

DiscordBM 라이브러리 자체도 이 계산을 이미 제공한다(`+Permissions.swift:203-236` `memberHasGuildPermission` — owner_id 비교 후 `role.permissions.contains(.administrator) && memberHasRole(...)`). 다만 이 함수는 `Guild.Member`(전체 멤버 목록, `self.members`에서 룩업)를 인자로 받는데, 메시지 이벤트의 `member`는 `Guild.PartialMember`(`Gateway.swift:1239` `MessageCreate.member: Guild.PartialMember?`)라 **타입이 달라 이 라이브러리 함수를 직접 재사용할 수는 없다** — 대신 캐시(`ownerId` + `adminRoleIds: Set<RoleSnowflake>`)만 들고 `ownerId == actorId || !Set(partialMember.roles).isDisjoint(with: adminRoleIds)`로 동일한 로직을 5줄 내외로 직접 계산하면 된다(라이브러리 함수보다 오히려 더 단순 — `self.members` 전체 룩업이 필요 없음). `GatewayEventHandler` 프로토콜에는 `onGuildRoleCreate/Update/Delete`가 이미 기본 no-op으로 존재해(`DiscordGateway/GatewayEventHandler.swift:76-78,180-182`) role 변경 시 캐시 갱신을 얹을 여지도 이미 있다(현재 미구현, 9장 Q1-b 참고).

### 수정 방향 (설계확정)

**방향**: 길드별 `roleId → permission 비트필드` 캐시 + `guildId → ownerId`를 신설(actor, `BotGatewayIdentity`와 유사한 패턴 — 같은 `GuildChannelProvisionerAdapter.swift:113-119`에 나란히 두는 것이 응집도상 자연스러움. 이미 `botCanManageChannels`가 같은 GuildCreate payload로 `guild.userHasGuildPermission(...)`을 호출하는 선례가 같은 파일에 있음, `GuildChannelProvisionerAdapter.swift:123-134`)하고, `onGuildCreate`에서 채워 넣는다. 메시지 경로의 `AuthInput` 생성 시 `isAdministrator: false` 고정값을, "이 캐시로 계산한 실제 값"으로 교체한다.

- **경계 영향**: 프로세스 간 통신 없음(Swift 단일 프로세스 내부) · 공통 모듈 영향 있음(`DabMain.swift`, 신규 actor 1개) · 공유 데이터 모델 영향 없음(파일 저장 없이 인메모리 캐시).
- **폐기 대안**: 메시지마다 REST API로 멤버 권한을 실시간 조회 — 매 메시지 API 호출은 레이트리밋·레이턴시 부담이 커서 폐기. GuildCreate 캐시 방식이 TS의 discord.js 캐시 방식과 동일한 아이디어라 정합성도 좋음.
- **role 변경 실시간 반영 포함 확정(9장 Q1-b)**: `onGuildRoleCreate`/`onGuildRoleUpdate`/`onGuildRoleDelete`(현재 `GatewayEventHandler`에 기본 no-op으로 존재, `DiscordGateway/GatewayEventHandler.swift:76-78,180-182`)를 구현해, 역할이 생성/수정/삭제될 때마다 캐시를 즉시 갱신한다. 재부팅 없이 반영됨.
- 캐시를 신규 actor로 만들지 `BotGatewayIdentity`를 확장할지는 실제 구현 시 DEV가 결정 — 위에서 신규 actor를 같은 파일에 나란히 두는 쪽을 제안했으므로 사용자 승인 필요한 수준은 아님, Part B WO에서 확정.

**단, D절(신규 기능)과의 관계**: 유저ID 기반 권한 커맨드가 생기면 사용자는 자신을 `adminUserIds`에 직접 등록해 이 문제 자체를 우회할 수 있다. 따라서 이 이슈1 수정은 "일반적으로 옳은 근본 수정"이지만, D절 기능이 있으면 **이 사용자 입장에서는 시급성이 낮아진다** — 9장 Q1로 우선순위 확인.

---

## B. 이슈2 — 슬래시 커맨드가 두 번씩 보임

### 원인 (확정)
- TS(`src/discord/client.ts`)는 **처음부터 길드 스코프 전용**으로만 커맨드를 등록해왔다 — `git log --all -S "applicationGuildCommands"`가 최초 커밋 1건만 반환, 전역 등록 코드는 TS 역사상 존재한 적 없음.
- 레거시 로그 `~/.discord-agent-bridge/agent.out.log:2036`(2026-07-25)에 `"slash commands registered {"guildId":"1522127888240087110","count":10}"` 확인 — 이 길드에 길드-스코프 커맨드 10개가 실제로 등록된 이력 실증.
- TS 프로세스는 이미 종료됨(오늘 Swift로 교체하며 PID 2601 종료 확인).
- Swift(`DabMain.swift:142-155` `registerAgentCommand`)는 `DAB_DEV_GUILD_ID` 미설정 시 **전역**(`bulkSetApplicationCommands`)으로만 등록 — 길드 스코프를 지우는 코드는 없음.
- **결론**: "죽은 TS가 남긴 길드 전용 커맨드 10개" + "오늘 Swift가 새로 등록한 전역 커맨드"가 별개 스코프로 공존해 사용자 눈에는 중복으로 보임. 두 봇이 동시에 응답하는 문제 아님(TS는 죽어있음) — 순수하게 등록 잔재 문제.

### 수정 방향 (설계확정)
**방향**: Swift가 전역 등록을 마친 뒤, 알고 있는 길드들에 대해 **빈 배열로 `bulkSetGuildApplicationCommands`를 1회 호출**해 길드 스코프 커맨드를 정리한다.

- **적용 위치**: `registerAgentCommand()`(`DabMain.swift:142-155`) — 전역 등록 분기 뒤에 추가.
- **대상 길드 범위**: 봇이 현재 속한 모든 길드(`onGuildCreate`가 호출되는 길드 전부, 이미 `runAutoProvisionGuild` 등에서 순회하는 패턴 재사용 가능) — 특정 길드ID 하드코딩 금지.
- **빈도**: 매 부팅마다 호출해도 안전한가 검토 — 길드 스코프 커맨드가 이미 비어있으면 빈 배열로 덮어쓰는 API 호출은 사실상 no-op이지만 API 호출 자체는 발생(레이트리밋 소모). "매 부팅 1회, 길드당 1콜"은 과설계가 아니라 **TS→Swift 전환처럼 향후 누구든 겪을 수 있는 시나리오의 안전망**으로 볼 수 있음 — 다만 이것도 "최초 1회만 하고 이후 스킵"할지 "매 부팅 정리"할지는 9장 Q2로 확인.
- **폐기 대안**: 사용자가 디스코드 개발자 포털에서 수동 삭제 — 길드별 커맨드 삭제 UI가 애초에 없어 불가능(확인됨). 이 세션 환경에서 직접 Discord API를 호출해 즉시 정리 — Bash 툴의 네트워크가 막혀있어(403, discord.com 포함 외부 전체) 불가능(확인됨). 따라서 코드 추가 + 재배포가 유일한 실행 가능한 경로.

---

## C. 이슈3 — 하드코딩된 값 전수 감사 (완료 — 버그 없음)

사용자 우려: "모델/추론(effort)/권한 종류가 실시간으로 안 오고 하드코딩됐을 수 있다."

### 조사 결과 (원인확정 — 조치 불필요)

| 항목 | Swift 실제 동작 | TS 실제 동작 | 판정 |
|---|---|---|---|
| Claude 모델/권한모드/effort | `ClaudeSidecarClient.swift:445-448` → 사이드카 `claude.catalog` RPC로 매 오픈마다 실시간 프로브(`DabSessionBridge.swift:136-143`) | `providerCatalog.ts:220-248`가 SDK `supportedModels()` 15초 프로브 | **정당 — 완전 동적, 하드코딩 없음** |
| Codex 모델 목록 | `CodexCatalog.swift:74-213` `CodexConfigSource` actor, mtime 게이트로 실시간 재읽기 | `configSource.ts:79-102,193-216` 동일 방식 | **정당 — 동적** |
| Codex 샌드박스 목록 | `codex --help` 실제 spawn + identity 캐시(`CliHelp.swift:90-148`) | `permissionSource.ts:58-91` 동일 | **정당 — 동적**(`SWIFT_PORT_PLAN.md` 옛 기록엔 "미포팅"이라 돼 있으나 2026-07-25 커밋 `76045c6`로 이미 구현 완료된 낡은 기록임을 확인) |
| Grok 모델/effort/권한모드 | `GrokCatalog.swift` + `CliHelp.swift` — 파일 mtime 게이트 재읽기 + `grok --help` 실제 spawn | `configSource.ts`/`permissionSource.ts` 동일 | **정당 — 동적** |
| PermissionMode enum(`default`/`acceptEdits`/`plan`/`bypassPermissions`) | `ClaudeCatalog.swift:50-69`(폴백만 static) | `contracts.ts`, `providerCatalog.ts:34-41` 도 static 상수 | **정당한 고정값**(프로토콜 자체가 고정 vocab, TS도 동일) |
| RoleTier/AuthAction(admin/execute/read-only) | `Authorizer.swift:14-38` | `core/auth.ts:14,17,20,25-29` | **정당한 고정값**(앱 내부 RBAC 개념, 외부에서 실시간으로 받아올 대상이 아님) |

각 항목에 남아있는 static 배열은 전부 "프로브 실패 시에만 쓰는 열화 폴백"이며 TS 원본에도 대칭으로 존재함(포팅 중 게을러서 생긴 하드코딩이 아님). **결론: 이슈3은 조치 불필요, 문서상 종결.**

---

## D. 신규 기능 — 유저 ID 기반 권한 부여 슬래시 커맨드

### 배경
사용자가 디스코드 서버 역할·채널 권한 관리가 어렵다고 느껴, 역할(role) 대신 **유저 단위로 직접 admin/execute/read-only 티어를 지정**하고 싶어함. 조사 결과 TS·Swift 어디에도 이런 기능(전역/서버 단위 유저ID 기반 티어 부여)은 없었음 — 있는 건 역할ID 기반 티어(`adminRoleIds` 등)와 채널 하나로 좁히는 `ProjectAuth.allowedUserIds`뿐. **완전 신규 기능.**

### 설계 방향

**데이터 모델**: `config.json`(전역)·`servers/<guildId>.json`(서버별)의 `auth` 객체에 기존 `adminRoleIds`/`executeRoleIds`/`readOnlyRoleIds` 옆에 **`adminUserIds`/`executeUserIds`/`readOnlyUserIds`**(문자열 배열)를 대칭으로 추가한다.
- 실제 타입 정의 위치(확인 완료): `GlobalAuth`는 `swift/Sources/DiscordAgentBridge/Config/ConfigSchema.swift:30-50`, `ServerAuthPartial`(서버별 오버라이드)은 같은 파일 `286-295`. `ConfigStore.swift:277-290` 근처의 merge 로직(`auth.adminRoleIds ?? []` 패턴)에도 동일하게 3필드를 추가해야 한다. TS 쪽도 동일 스키마로 병행 추가할지는 9장 Q3(TS는 legacy라 스킵 가능성 높음).

**권한 판정**: `Authorizer.swift:160-167` `resolveTier()`를 역할ID 매칭뿐 아니라 유저ID 매칭도 같이 보도록 확장(역할 OR 유저 — 하나라도 만족하면 그 티어, 예: `if has(auth.adminRoleIds) || auth.adminUserIds.contains(input.userId) { return .admin }`). `effectiveAuth()`(`Authorizer.swift:117-125`)도 서버 레이어가 유저ID 배열까지 함께 오버라이드하도록 확장.

**UI (확정)**: 신규 `/access` 커맨드가 아니라 **기존 `/config` 패널의 새 서브패널로 확장**한다.

- 근거: `ConfigPanelView`(`swift/Sources/DiscordAgentBridge/Session/ConfigPanel.swift:194-213`) 주석에 "roleRows ... ≤5 rows"라고 명시돼 있고, 실제로 admin/execute/readOnly `roleSelect` 3행 + Save/Notifications/Image-render 버튼 행 + locale 행으로 **이미 Discord의 메시지당 액션로우 5개 한도를 다 쓰고 있다**(`render()`, 같은 파일 308-338행대). 3개의 `userSelect`를 같은 뷰에 추가할 자리가 없다.
- 이 프로젝트에는 정확히 이 상황(주 패널이 꽉 참)을 위한 기존 패턴이 이미 있다 — "🔔 Notifications"/"🖼 Image render" 버튼이 `config.notif.open`/`config.render.open`으로 **새 서브패널(`ConfigPanelSubView`, 자체 5행 예산)을 여는 구조**(`ConfigPanel.swift:151-166`의 `ConfigPanelResult.notifPanel`/`renderPanel`, `ConfigPanel.swift:283-298`의 `handle()` 분기). 동일한 방식으로 새 "👤 Access (user IDs)" 버튼(`config.access.open`)을 추가해 서브패널을 연다.
- 서브패널 안에 `userSelect` 3행(admin/execute/readOnly) — `ConfigPanelComponent`(`ConfigPanel.swift:170-187`)에 기존 `.roleSelect(customId:placeholder:defaultRoleIds:minValues:maxValues:)`와 동일한 시그니처로 `.userSelect` case를 추가하고, `SlashSupport.swift:401-414`의 `configPanelActionRow`에 매핑 분기를 추가한다. DiscordBM은 `Interaction.ActionRow.Component.userSelect(SelectMenu)`를 `.roleSelect(SelectMenu)`와 **완전히 동일한 타입**으로 이미 제공하므로(`.build/checkouts/DiscordBM/Sources/DiscordModels/Types/Interaction.swift:1337-1338`) 매핑 코드는 `RoleSnowflake` → `UserSnowflake`로 바꾸는 것 외에 로직 변경이 거의 없다.
- 값 추출(`comp.values`)과 admin 게이트(`handleConfigComponent`, `DabMain.swift:872-895`)는 select 종류에 무관하게 이미 제네릭하므로 라우팅 쪽 변경은 불필요. Save 방식도 기존 role 탭과 동일하게 "pending → Save 버튼 클릭 시 커밋"으로 통일(신규 `PendingUsers` 구조체를 기존 `PendingRoles`, `ConfigPanel.swift:217-225` 옆에 미러링).
- **폐기 이유(신규 `/access` 커맨드를 쓰지 않는 이유)**: 기존 `/config` 패널이 이미 admin 게이트·pending/Save 트랜잭션·embed 렌더링을 다 갖추고 있고, 정확히 "패널이 꽉 찼을 때"를 위한 서브패널 확장 패턴이 이미 존재해 재사용이 더 작은 diff이고 기존 아키텍처와 일관적이다.

### 최초 관리자 자동 부트스트랩 (확정)

사용자 요청: "처음 봇을 연결한 유저가 관리자가 되는 것" — 디스코드 역할 설정을 전혀 몰라도 봇을 처음 셋업하는 사람이 자동으로 관리자가 되어야 한다.

**문제**: `/setup`은 현재도 `.admin` 액션으로 게이트돼 있다(`DabMain.swift:255-256`). 이 게이트는 인터랙션 경로라 실제 디스코드 Administrator 비트를 정확히 읽어오므로(확인됨, A절 참고) **디스코드 서버 소유자/관리자라면 이미 지금도 셋업이 된다.** 다만 사용자가 "역할 관리가 어렵다"고 느끼는 근본 이유는 이 디스코드 권한 체계 자체이므로, 유저ID 기반 시스템은 **디스코드 권한과 완전히 무관하게** 최초 1인을 부트스트랩할 수 있어야 진짜 의미가 있다.

**설계**: `/setup` 처리 직전 인가 검사(`DabMain.swift:255-269` 부근)에 특수 분기 추가 — 해당 길드(또는 글로벌, 서버 설정이 아직 없으면)의 `adminRoleIds`와 `adminUserIds`가 **둘 다 비어있으면**(한 번도 부트스트랩된 적 없는 "완전 초기 상태") 일반 `authorize()` 판정을 건너뛰고 무조건 통과시킨다. `/setup` 처리가 성공적으로 끝나면 그 길드의 `adminUserIds`에 실행자 유저ID를 자동으로 추가한다. 이후로는 `adminUserIds`가 비어있지 않으므로 이 특수 분기는 다시 발동하지 않는다(1회성 부트스트랩, 이미 관리자가 있는데 아무나 다시 뺏을 수 없음).

- **경계 영향**: `DabMain.swift`의 `/setup` 핸들러만 수정, 다른 명령에는 영향 없음.
- **폐기 대안**: 최초 설치 시 CLI/env로 관리자 유저ID를 미리 지정 — 사용자가 유저ID를 알아내는 것 자체가 진입장벽이라 폐기(사용자 경험상 "그냥 셋업한 사람이 관리자"가 훨씬 직관적).

**이슈1과의 관계**: 이 기능이 생기면 사용자가 자신을 `adminUserIds`에 등록하는 것만으로 메시지·슬래시 양쪽 다 무조건 admin이 되어, 이슈1(게이트웨이 권한 비트 문제)의 실질 시급성이 사라진다. 다만 이슈1 자체의 근본 수정(캐싱 기반 실제 계산)은 다른 사용자/서버에도 유효한 개선이므로 별도로 구현한다(아래 확정).

### E. `execute`(일반) 등급의 범위 — 확정

기존 `AuthAction` 매핑(`DabMain.swift:255-256` — `stop-all`/`setup`/`config`/`update`만 admin, 나머지 전부 `.drive`→execute)은 **변경하지 않는다**(사용자 결정: B안). 즉 "일반" 등급도 `/agent close`·모델/모드/effort 변경·`/stop`·`/clear`는 계속 가능하고, 서버 전체 설정(`/setup`,`/config`,`/stop-all`,`/update`)만 관리자 전용으로 남는다. **이 항목은 코드 변경 없음** — D절의 유저ID 기반 티어 부여만 새로 추가되고, 어떤 명령이 어떤 등급을 요구하는지는 그대로다.

---

---

# Part B — 작업 지시 (AI 실행용)

## 6. 작업 지시서 (Work Orders)

### WO-1: 메시지 경로 실제 관리자 계산 + 역할 변경 실시간 캐시 갱신 (이슈1, Q1+Q1-b)
- 상태: [x] 완료
- 의존: 없음
- 대상: `swift/Sources/dab/DabMain.swift`(`onGuildCreate`, 메시지 경로 `AuthInput` 생성부 `:1706-1711`, `GatewayEventHandler` 구현부), 신규 캐시(파일 위치는 아래 참고)
- 변경:
  1. 길드별 `ownerId: UserSnowflake` + `adminRoleIds: Set<RoleSnowflake>`(Administrator 비트를 가진 역할 ID만 추림)를 들고 있는 신규 actor를 만든다. `BotGatewayIdentity`와 비슷한 성격이니 그 파일 옆(같은 디렉토리)에 두거나 확장한다 — 어느 쪽이든 무방, 기존 `BotGatewayIdentity` 파일 위치를 먼저 확인하고 정한다.
  2. `onGuildCreate`(`DabMain.swift:113-120`)에서 `payload.roles`를 순회해 `permissions.contains(.administrator)`인 역할만 추려 캐시에 저장하고, `payload.owner_id`도 저장한다.
  3. `onGuildRoleCreate`/`onGuildRoleUpdate`/`onGuildRoleDelete`(현재 `GatewayEventHandler` 기본 no-op, `DiscordGateway/GatewayEventHandler.swift:76-78,180-182` 참고)를 구현해 역할이 추가/변경/삭제될 때마다 해당 길드 캐시의 admin role 목록을 갱신한다.
  4. 메시지 경로(`DabMain.swift:1706-1711`)의 `isAdministrator: false`를, `ownerId == actorId || !Set(message.member.roles).isDisjoint(with: cachedAdminRoleIds)`로 계산한 실제 값으로 교체한다.
- 금지: 인터랙션 경로(`DabMain.swift:266,747,892,1960`)의 기존 계산 로직은 건드리지 않는다. `Authorizer.swift`의 판정 로직 자체는 변경하지 않는다(입력값만 정확해지면 됨).
- 완료 판정: `swift build --package-path swift` 성공 + 신규 유닛 테스트(캐시 채우기/역할 변경 반영/메시지 경로 계산 결과) 작성 및 통과.

### WO-2: 부팅마다 길드-스코프 잔존 슬래시 커맨드 정리 (이슈2, Q2)
- 상태: [x] 완료
- 의존: 없음
- 대상: `swift/Sources/dab/DabMain.swift` `registerAgentCommand()`(`:142-155`)
- 변경: 전역 등록(`bulkSetApplicationCommands`) 완료 뒤, 봇이 속한 길드 각각에 대해 빈 배열로 `bulkSetGuildApplicationCommands`를 호출한다. 길드 목록은 `onGuildCreate`가 호출되는 길드들(이미 어딘가에 순회/추적하는 구조가 있으면 재사용, 없으면 `BotGatewayIdentity` 유사 패턴으로 간단히 집합만 추적).
- 금지: `DAB_DEV_GUILD_ID`가 설정된 경우(길드 스코프로 일부러 등록하는 개발 모드)에는 방금 등록한 그 길드까지 지우면 안 된다 — 이 정리는 "전역 등록 모드일 때만" 수행.
- 완료 판정: `swift build --package-path swift` 성공 + 실제 재배포 후 로그로 정리 호출이 각 길드에 1회씩 나가는지 확인(유닛 테스트로 API 호출 여부를 mock 검증).

### WO-3: 유저ID 기반 권한 데이터 모델 + 판정 로직 (D절 기반, 의존: 없음)
- 상태: [x] 완료
- 의존: 없음
- 대상: `swift/Sources/DiscordAgentBridge/Config/ConfigSchema.swift`(`GlobalAuth:30-50`, `ServerAuthPartial:286-295`), `swift/Sources/DiscordAgentBridge/Config/ConfigStore.swift`(merge 로직 `:277-290` 부근), `swift/Sources/DiscordAgentBridge/Session/Authorizer.swift`(`resolveTier:160-167`, `effectiveAuth:117-125`)
- 변경:
  1. `GlobalAuth`/`ServerAuthPartial`에 `adminUserIds`/`executeUserIds`/`readOnlyUserIds`(문자열 배열, 기본값 빈 배열) 추가.
  2. `ConfigStore`의 병합 로직에 3필드를 기존 RoleIds와 동일한 패턴으로 병행 추가.
  3. `Authorizer.resolveTier()`를 역할ID OR 유저ID로 확장: `if has(auth.adminRoleIds) || auth.adminUserIds.contains(roleIds_호출자아님_userId) { return .admin }` 식(정확한 파라미터명은 기존 함수 시그니처 확인 후 맞춘다 — `resolveTier`가 현재 `roleIds`만 받으므로 `userId`도 인자로 추가 필요, 호출부 `decide()`도 함께 수정).
  4. `effectiveAuth()`도 서버 레이어가 유저ID 3필드까지 함께 오버라이드하도록 확장.
- 금지: 기존 역할ID 기반 판정 로직·필드명 변경 금지(순수 추가만).
- 완료 판정: `swift build --package-path swift` 성공 + 유닛 테스트(역할 없이 유저ID만으로 admin/execute/readOnly 판정되는 케이스, 서버 레이어 오버라이드 케이스) 통과.

### WO-4: `/config` 서브패널 "Access(유저 권한)" UI (D절, 의존: WO-3)
- 상태: [x] 완료
- 의존: WO-3
- 대상: `swift/Sources/DiscordAgentBridge/Session/ConfigPanel.swift`(`ConfigPanelResult`, `ConfigPanelComponent`, `PendingRoles` 근처 `:151-225`), `swift/Sources/DiscordAgentBridge/Session/SlashSupport.swift`(`configPanelActionRow:401-414`), `DabMain.swift`(`handleConfigComponent:872-895` 근처 라우팅)
- 변경:
  1. "👤 Access" 버튼(`config.access.open`) 추가 — 기존 `config.notif.open`/`config.render.open`과 동일 패턴으로 서브패널을 연다.
  2. 서브패널에 `userSelect` 3행(admin/execute/readOnly) 추가 — `ConfigPanelComponent`에 기존 `.roleSelect`와 동일 시그니처의 `.userSelect` case 신설, `SlashSupport.swift`에 매핑 분기 추가(DiscordBM `Interaction.ActionRow.Component.userSelect`가 `.roleSelect`와 동일 타입이므로 `RoleSnowflake`→`UserSnowflake`만 바꾸면 됨).
  3. `PendingRoles`를 미러링한 `PendingUsers` 구조체 신설, 기존 role 탭과 동일하게 pending→Save 트랜잭션으로 커밋.
- 금지: 기존 role 서브패널/notif/render 서브패널의 동작 변경 금지.
- 완료 판정: `swift build --package-path swift` 성공 + 유닛 테스트(패널 렌더링에 Access 버튼 존재, userSelect 값이 pending에 반영, Save 시 config에 커밋) 통과.

### WO-5: 최초 관리자 자동 부트스트랩 (D절, 의존: WO-3)
- 상태: [x] 완료
- 의존: WO-3
- 대상: `DabMain.swift`의 `/setup` 인가 검사 부근(`:255-269`), `/setup` 핸들러 완료 지점
- 변경: 해당 길드(서버 설정 없으면 글로벌)의 `adminRoleIds`+`adminUserIds`가 모두 비어있을 때만 `authorize()` 판정을 건너뛰고 통과시키는 특수 분기 추가. `/setup` 처리가 성공하면 실행자 유저ID를 그 길드의 `adminUserIds`에 자동 추가(WO-3의 config 쓰기 API 재사용).
- 금지: 이미 `adminRoleIds`나 `adminUserIds` 중 하나라도 값이 있으면 이 분기가 절대 발동하면 안 된다(기존 관리자를 무단으로 늘리는 구멍이 되면 안 됨).
- 완료 판정: `swift build --package-path swift` 성공 + 유닛 테스트(빈 상태에서 아무 권한 없는 유저가 `/setup` 실행 → 통과 + adminUserIds에 등록됨, 이미 관리자가 있는 상태에서 다른 유저가 시도 → 기존처럼 거부됨) 통과.

## 7. 검증 계획

### 7-1. 에이전트 검증
- [x] 빌드: `swift build --package-path swift` 성공 — 결과: WO-1~5 전체 반영 후 최종 빌드 통과(`dab` 타깃 별도 빌드도 통과).
- [x] 관련 유닛 테스트 필터 실행(WO별로 새로 작성한 테스트만) 통과 — 결과: `GuildAdminCacheTests` 8/8, `SlashCommandSweepTests` 3/3, `AuthorizerUserIdTests` 5/5, `ConfigPanelAccessTests` 8/8, `AuthorizerSetupBootstrapTests` 10/10 — 전부 통과. 회귀 확인용 `AuthorizerTests`/`ConfigPanelTests`/`ConfigStoreTests` 등 기존 스위트도 무깨짐.
- [x] 전체 `swift test`/`bash verify.sh`는 이 환경의 `.build` 인덱서 락 이슈로 생략 — 사용자가 별도로 실행

### 7-2. 사람 검증 (사용자 확인 후 기입)
- [ ] 일반 메시지로 명령 시 더 이상 권한 오류가 안 뜨는지(디스코드 역할 변경 없이)
- [ ] 길드에 슬래시 커맨드가 하나로만 보이는지(재배포 후)
- [ ] `/config` → Access 패널에서 유저를 골라 admin/일반/뷰어로 지정하고 저장, 해당 유저가 실제로 그 등급대로 동작하는지
- [ ] (해당하면) 새 서버에서 처음 `/setup` 실행한 사람이 자동으로 관리자가 되는지

## 8. 주의사항

- WO-1/WO-2는 서로 독립적이라 병렬 진행 가능. WO-4/WO-5는 WO-3 완료 후 시작.
- 매 WO 완료 후 재배포(release 빌드 + launchd 재기동)가 필요한 항목은 사용자에게 재배포 여부를 확인한다(오늘 이미 여러 번 재배포했으므로 매 WO마다 즉시 재배포할지, 전부 끝나고 한 번에 재배포할지는 사용자 선택 — 9장에 없으면 기본은 "전부 끝나고 한 번에").

---

## 9. 미결 사항 — 사용자 결정 완료

| # | 질문 | 결정 (2026-07-26) |
|---|---|---|
| Q1 | 이슈1을 D절과 별도로 지금 구현할지 | **지금 구현한다** |
| Q1-b | 이슈1에 `onGuildRoleCreate/Update/Delete` 실시간 캐시 갱신을 포함할지 | **포함한다** — 역할 권한이 바뀌면 재부팅 없이 즉시 캐시 갱신 |
| Q2 | 이슈2 정리를 매 부팅마다 할지 | **매 부팅마다 정리한다** |
| Q3 | D절 신규 기능을 TS에도 포팅할지 | **Swift만** — TS는 손대지 않는다 |
| Q4 | D절 UI를 `/config` 서브패널로 갈지 | 명시적 반대 없어 **채택안(서브패널) 그대로 진행** |
| (신규) | `execute`(일반) 등급이 세션 조작(close/모델변경/stop)까지 계속 가능하게 둘지, 채팅만으로 좁힐지 | **B안 — 지금처럼 유지**(E절 참고), 코드 변경 없음 |

## 10. 작업 로그

### 2026-07-26 — ARCH 조사(다중 세션, 오케스트레이터가 최종 통합)
- 한 일: 이슈1 원인 확정(오케스트레이터 직접 조사, file:line 확보) + 실현가능성 확인(DiscordBM `GuildCreate.roles`/`Role.permissions` 존재 확인). 이슈2 원인 확정(architect 서브에이전트, git log + 레거시 로그 증거). 이슈3 전수 감사 완료(서브에이전트 2회 분업 — Claude/Codex, Grok/권한enum — 전부 "하드코딩 버그 없음"으로 종결). D절 신규 기능 설계 방향 수립.
- 알아낸 것: 조사 과정에서 서브에이전트 체인의 SendMessage 피어 이름 해석 실패로 여러 차례 진행이 지연됨(중첩 에이전트가 부모를 "architect"라는 이름으로 착각해 보고 실패) — 최종적으로 오케스트레이터가 모든 서브에이전트의 원시 결과를 직접 취합해 이 문서를 작성함.
- 바뀐 결정: 없음(전부 조사 단계, 코드 변경 없음).

### 2026-07-26 — ARCH 보강 세션
- 한 일: A절(이슈1)에 DiscordBM `+Permissions.swift:203-236` 함수와 메시지 이벤트의 `Guild.PartialMember` 타입 불일치(`Gateway.swift:1239`)를 직접 확인해 "라이브러리 함수를 그대로 재사용할 수 없고 자체 계산 로직이 필요하다"는 세부를 보강. D절(신규 기능) UI를 막던 `[미확인]` 마커를 실제 코드 확인으로 해소 — `/config` 패널이 이미 Discord 액션로우 5개 한도를 다 쓰고 있음(`ConfigPanel.swift:194-213,308-338`)을 확인하고, 기존 notif/render 서브패널 패턴(`ConfigPanel.swift:151-166,283-298`)을 재사용하는 것으로 UI 설계를 확정. `GlobalAuth`/`ServerAuthPartial` 정확한 위치(`ConfigSchema.swift:30-50,286-295`)도 확정.
- 알아낸 것: DiscordBM의 `Interaction.ActionRow.Component.userSelect(SelectMenu)`가 `.roleSelect(SelectMenu)`와 완전히 동일한 타입이라(`Interaction.swift:1337-1338`) 신규 UI 매핑 코드가 매우 작은 diff로 충분함.
- 바뀐 결정: D절 UI를 "구현 시 결정"에서 "`/config` 서브패널 확장으로 확정, 별도 `/access` 커맨드는 폐기안"으로 변경(9장 Q4로 최종 확인만 남김).

### 2026-07-26 — DEV: WO-3 구현 완료
- 한 일: 3안 제시(`resolveTier` 시그니처 확장 방식) 후 오케스트레이터가 옵션1(지시서 그대로 `userId` 파라미터 추가)로 확정, 그대로 구현.
  - `ConfigSchema.swift`: `GlobalAuth`(30행대)에 `adminUserIds`/`executeUserIds`/`readOnlyUserIds`(`[String]`, 기본값 `[]`) 추가, `ServerAuthPartial`(286행대)에 동일 3필드(`[String]?`, 기본값 `nil`) 추가, `configDefaultsDict()`의 `"auth"` 딕셔너리에도 3키 추가.
  - `ConfigStore.swift`: `loadAuthPartial`/`AuthBlock`(270행대, corrupt-config 부분 디코드 폴백 경로)에 동일 3필드 병행 추가.
  - `Authorizer.swift`: `effectiveAuth()`(117행대)가 서버 레이어의 유저ID 3필드도 함께 오버라이드하도록 확장. `resolveTier(_:_:)`를 `resolveTier(_:_:_:)`로 넓혀 `userId` 파라미터 추가, 각 티어의 `has(_:)` 헬퍼를 "역할셋 OR 유저ID셋"으로 확장(admin→execute→readOnly 우선순위 유지). 유일한 호출부 `decide()`도 함께 수정.
  - 기존 역할ID 기반 판정 로직·필드명·시맨틱은 변경 없음(순수 추가). `AuthInput`/`decide()`의 나머지 로직(Discord Administrator 바이패스, dmPolicy, projectAuth 나머지 로직)은 무변경.
  - 신규 테스트 `swift/Tests/DiscordAgentBridgeTests/AuthorizerUserIdTests.swift` 작성(역할 없이 유저ID만으로 admin/execute/readOnly 판정 3케이스, 미등록 유저 fail-secure 거부 1케이스, 서버 레이어 `adminUserIds` 오버라이드가 해당 길드에만 적용되는 1케이스, 총 5개).
- 검증: `swift build --package-path swift` 성공. `swift test --package-path swift --filter AuthorizerUserIdTests` 5/5 통과. 회귀 확인용으로 `swift test --package-path swift --filter AuthorizerTests`도 24/24 통과(기존 역할 기반 로직 무깨짐). 전체 `swift test`/`bash verify.sh`는 사용자 지시대로 생략(`.build` 인덱서 락 이슈).
- 바뀐 결정: 없음(지시서 그대로 구현, 옵션2/3은 채택 안 함).

### 2026-07-26 — DEV: WO-1 구현 완료
- 한 일: 3안 제시(① 라이브러리 순수 캐시 actor + `dab` 얇은 어댑터 / ② `BotGatewayIdentity` 옆 DiscordBM 타입 그대로 캐시 / ③ DiscordBM `memberHasGuildPermission` 재사용 + 길드 전체 스냅샷 보관) 후 오케스트레이터가 옵션1(테스트 가능성 + 기존 `SessionRegistry`/`routeDecision` 패턴 일치가 결정적 근거)로 확정, 그대로 구현.
  - 신규 `swift/Sources/DiscordAgentBridge/Session/GuildAdminCache.swift`: `public actor GuildAdminCache`(`.shared` 싱글턴). 길드별 `ownerId: String` + `adminRoleIds: Set<String>`을 보관. `setGuild(guildId:ownerId:adminRoleIds:)`(GuildCreate 전체 교체), `setRoleIsAdmin(guildId:roleId:isAdmin:)`(역할 생성/수정 반영, 미등록 길드는 no-op), `removeRole(guildId:roleId:)`(역할 삭제), `isAdministrator(guildId:userId:roleIds:) -> Bool`(owner 비교 OR admin role 교집합) 4개 메서드. DiscordBM 비의존 순수 Swift라 `DiscordAgentBridgeTests`에서 바로 테스트 가능(라이브러리는 애초에 DiscordBM 의존성이 없음, `Package.swift` 확인).
  - `swift/Sources/dab/DabMain.swift`:
    - `onGuildCreate`(113행대)에 `payload.roles`를 `permissions.contains(.administrator)`로 필터링해 role id 집합을 만들고 `payload.owner_id.rawValue`와 함께 `GuildAdminCache.shared.setGuild(...)` 호출 추가.
    - `EventHandler`(`GatewayEventHandler` 채택)에 `onGuildRoleCreate`/`onGuildRoleUpdate`/`onGuildRoleDelete` 3개 신규 override 추가 — role 생성/수정 시 `setRoleIsAdmin(...)`, 삭제 시 `removeRole(...)` 호출. 기존 기본 no-op(`DiscordGateway/GatewayEventHandler.swift:76-78,180-182`)을 대체.
    - 메시지 경로(`runAndReply`, 옛 `:1706-1711`)의 `isAdministrator: false` 고정값을 `GuildAdminCache.shared.isAdministrator(guildId:userId:roleIds:)` 실제 계산값으로 교체(DM은 `guild_id`가 없어 여전히 false — dmPolicy가 그대로 유효). 더 이상 사실과 다른 "Q2 — isAdministrator stays false" 주석은 실제 계산을 설명하는 내용으로 갱신.
  - 인터랙션 경로(`DabMain.swift:266,747,892,1960`)와 `Authorizer.swift`의 판정 로직 자체는 무변경(입력값만 정확해짐, 지시서 엄수사항 준수). WO-3(`ConfigSchema.swift`/`ConfigStore.swift`) 파일은 건드리지 않음.
  - 신규 테스트 `swift/Tests/DiscordAgentBridgeTests/GuildAdminCacheTests.swift` 작성 — 매번 `GuildAdminCache()` 새 인스턴스 사용(케이스 간 오염 방지, `SessionRegistry` 테스트 관례와 동일). owner 무역할 admin 판정, admin role 보유/미보유 판정, 미등록 길드 fail-safe false, `setRoleIsAdmin`으로 역할에 admin 권한 부여/회수 시 실시간 반영, `removeRole`로 역할 삭제 시 반영, GuildCreate 이전에 역할 이벤트가 와도 phantom 상태를 만들지 않음(no-op) — 총 8케이스.
- 검증: `swift build --package-path swift` 성공(라이브러리 전체) + `swift build --package-path swift --target dab` 성공(어댑터 코드 별도 확인). `swift test --package-path swift --filter GuildAdminCacheTests` 8/8 통과. 전체 `swift test`/`bash verify.sh`는 지시대로 생략(`.build` 인덱서 락 이슈).
- 바뀐 결정: 없음(오케스트레이터가 지정한 옵션1 그대로 구현).

### 2026-07-26 — DEV: WO-2 구현 완료
- 한 일: 3안 제시(① `Ready.guilds` 배치 + 라이브러리 순수 함수 closure 주입 / ② `onGuildCreate` 직접 훅 / ③ 별도 `KnownGuildsTracker` actor 신설) 후 오케스트레이터가 옵션1(기존 "라이브러리=로직/dab=번역" 컨벤션과 테스트 요건에 가장 부합)로 확정, 그대로 구현.
  - `SlashCommandSpec.swift`(`allSlashCommandSpecs()` 뒤): 신규 `public func sweepStaleGuildCommands(knownGuildIds:devGuildId:clear:)` — `devGuildId`가 `nil`이 아니면 즉시 반환(전역 등록 모드가 아니면 아무 것도 안 함), 아니면 `knownGuildIds`를 순회하며 주입된 `clear` closure를 1회씩 호출. DiscordBM 비의존 순수 함수라 `DiscordAgentBridgeTests`에서 바로 테스트 가능.
  - `DabMain.swift`: `registerAgentCommand(appId:)` → `registerAgentCommand(appId:guildIds:)`로 시그니처 확장(`onReady`의 `payload.guilds.map(\.id.rawValue)`를 전달 — Ready가 실어오는 "봇이 속한 길드 전체" stub 목록, 길드ID 하드코딩 없음). 함수 내부에서 `DAB_DEV_GUILD_ID` 값을 한 번만 정규화(`""` → `nil`)해 기존 dev/global 분기와 `sweepStaleGuildCommands` 호출에 동일하게 사용. 전역/dev 등록 do-catch 이후, `sweepStaleGuildCommands`를 호출해 길드마다 `client.bulkSetGuildApplicationCommands(appId:guildId:payload: [])`(빈 배열)을 실행 — 실패는 개별 길드 단위로 print만 하고 계속 진행(기존 등록 실패 처리와 동일한 best-effort 패턴).
  - `DAB_DEV_GUILD_ID` 설정 시(`devGuildId != nil`)에는 `sweepStaleGuildCommands`가 가드절에서 즉시 반환하므로, 방금 그 길드에 등록한 dev 커맨드는 전혀 건드리지 않음(엄수사항 준수) — 별도 예외 처리 없이 가드 하나로 자연히 충족.
  - `registerAgentCommand()`의 기존 dev/global 등록 로직, 인터랙션 경로, WO-1의 `GuildAdminCache`/`onGuildCreate`/역할 캐시 로직은 무변경.
  - 신규 테스트 `swift/Tests/DiscordAgentBridgeTests/SlashCommandSweepTests.swift` 작성 — ① `devGuildId: nil`일 때 알려진 길드 전부에 순서대로 정리 콜이 나가는지, ② `devGuildId`가 설정되면(그 길드가 known 목록에 있어도) 전혀 호출되지 않는지, ③ 빈 길드 목록에서 no-op인지, 총 3케이스.
- 검증: `swift build --package-path swift` 성공. `swift test --package-path swift --filter SlashCommandSweepTests` 3/3 통과. 전체 `swift test`/`bash verify.sh`는 사용자 지시대로 생략(`.build` 인덱서 락 이슈).
- 바뀐 결정: 없음(오케스트레이터가 지정한 옵션1 그대로 구현).

### 2026-07-26 — DEV: WO-5 구현 완료
- 한 일: 3안 제시(① `Authorizer`에 판정 메서드 + `ConfigStore`에 쓰기 메서드, `addServerPreset`과 동일한 재시도+검증 패턴 / ② 동일 분리, 단 쓰기는 `addAutoAllowClaudeTool`처럼 재시도 없는 단순 1회 / ③ `DabMain.swift`에만 인라인 구현, 라이브러리 변경 없음) 후 오케스트레이터가 옵션1(관리자 권한 부여라는 민감 경로라 검증까지 있는 쪽이 맞다는 판단)로 확정, 그대로 구현.
  - 조사 과정에서 확인한 제약: `swift/Package.swift`의 `DiscordAgentBridgeTests`는 `DiscordAgentBridge` 라이브러리에만 의존하고 `dab`(실행 파일 타깃, `DabMain.swift`)에는 테스트 타깃이 없음 — WO-1/WO-2와 동일하게 판정·쓰기 로직은 전부 라이브러리에 둬야 완료 판정이 요구하는 유닛 테스트를 실제로 작성할 수 있음(옵션3 탈락 근거).
  - `Authorizer.swift`: `effectiveAuth(global:server:)` 바로 뒤에 `public func isSetupBootstrapEligible(guildId:) async -> Bool` 추가 — 서버 레이어 오버라이드까지 반영한 유효 auth의 `adminRoleIds`+`adminUserIds`가 둘 다 비었는지만 판정(기존 `effectiveAuth`를 그대로 재사용, 새 판정 로직 없음).
  - `ConfigStore.swift`: `addServerPreset` 패턴을 그대로 미러링한 `public func addServerAdminUserId(guildId:userId:) throws` 추가(`addAutoAllowClaudeTool` 근처, "Nice-to-have" 섹션 바로 위) — 기존 `auth.adminUserIds`에 이미 있으면 no-op, 없으면 추가 후 `ServerConfig`의 다른 모든 필드(`defaults`/`limits`/`locale`/`auditChannelId`/`favorites`/`presets`/`channels`/`notifications`/`capabilities`)를 전부 보존해 재구성, `saveServerConfig` 후 read-after-write로 최대 3회 재시도 검증(`addServerPreset`과 동일 구조; `capabilities` 필드는 기존 `addServerPreset`/`removeServerPreset`가 누락하고 있던 필드인데 이번 신규 함수에서는 빠뜨리지 않고 포함시킴 — 기존 함수 수정은 WO-5 범위 밖이라 손대지 않음).
  - `DabMain.swift`: 인가 판정부(옛 `:255-269`, 현재 `:286` 부근)에서 `cmd.name == "setup"`이고 길드 컨텍스트일 때만 `Authorizer(config: .shared).isSetupBootstrapEligible(guildId:)`를 먼저 확인해 `setupBootstrap` 플래그를 세우고, 참이면 `authorize()` 호출 자체를 건너뛰고 `AuthResult(allowed: true, tier: .admin)`로 대체. `case "setup":`의 두 성공 경로(기존에 이미 채널이 세팅된 "alreadyDone" 분기, `ensureGuildChannels` 신규 성공 분기) 각각에서 `setupBootstrap`이 참이면 신규 private 헬퍼 `registerSetupBootstrapAdmin(guildId:userId:)`를 호출 — 내부에서 `ConfigStore.shared.addServerAdminUserId(...)`를 호출하고 실패 시 `/setup` 자체의 성공 응답은 막지 않은 채 print만 함(WO-2의 "실패는 개별적으로 print, 계속 진행" 컨벤션과 동일한 best-effort).
  - 엄수사항 준수 확인: `isSetupBootstrapEligible`이 `adminRoleIds`나 `adminUserIds` 중 하나라도 비어있지 않으면 무조건 `false`를 반환하므로, 이미 관리자가 하나라도 있는 길드에서는 이 특수 분기가 절대 발동하지 않고 기존 `authorize()` 경로 그대로 거부됨. 인터랙션 경로의 다른 커맨드(`stop-all`/`config`/`update`)와 `Authorizer.decide()`/`resolveTier()` 자체는 무변경.
  - 신규 테스트 `swift/Tests/DiscordAgentBridgeTests/AuthorizerSetupBootstrapTests.swift` 작성(10케이스): `isSetupBootstrapEligible`이 config.json이 아예 없는/있지만 auth가 빈 경우 true, 글로벌 adminRoleIds·adminUserIds 중 하나라도 있으면 false, 서버 레이어에만 admin이 있으면 그 길드만 false(다른 길드는 여전히 true)로 판정하는 5케이스; `addServerAdminUserId`가 서버 설정이 없을 때 새로 생성/이미 등록된 유저 재호출 시 멱등/다른 필드 보존하는 3케이스; 그리고 지시서가 명시한 완료 판정 시나리오 그대로 — "관리자 전혀 없는 상태에서 권한 없는 유저가 /setup 실행 → 정상 `authorize()`로는 거부되지만 부트스트랩 체크는 통과 → 성공 후 등록 → 이후 동일 유저는 특례 없이도 일반 경로로 admin" 1케이스, "이미 admin 1명 등록된 후 다른 유저가 시도 → 부트스트랩 미발동 + 기존처럼 fail-secure 거부" 1케이스. `dab` 타깃은 테스트 타깃이 없어 end-to-end 케이스는 `DabMain.swift`가 실제로 호출하는 것과 동일한 시퀀스(`isSetupBootstrapEligible` → 성공 시 `addServerAdminUserId`)를 라이브러리 API로 직접 재현.
- 검증: `swift build --package-path swift` 성공(라이브러리+`dab` 둘 다). `swift test --package-path swift --filter AuthorizerSetupBootstrapTests` 10/10 통과. 회귀 확인용 `swift test --package-path swift --filter "AuthorizerTests|AuthorizerUserIdTests|ConfigStoreTests"` 49/49 통과(기존 역할·유저ID 기반 판정, 프리셋/오토얼라우 쓰기 로직 무깨짐). 전체 `swift test`/`bash verify.sh`는 사용자 지시대로 생략(`.build` 인덱서 락 이슈).
- 바뀐 결정: 없음(오케스트레이터가 지정한 옵션1 그대로 구현).

### 2026-07-26 — DEV: WO-4 구현 완료 (마지막 WO)
- 한 일: 재량 지점(Access 서브패널 Save 버튼이 저장 시 `/config` 세션 전체를 끝낼지 여부)에 대해 3안 제시(① role Save를 그대로 재사용 — 신규 result case 없이 `.saved` 재사용, 세션 종료 / ② 전용 `.accessSaved` case 신설 — 세션 유지, 메인 패널·다른 서브패널 안 깨짐 / ③ pending/Save 자체를 폐기하고 notif/render처럼 즉시 자동저장 — 지시서의 "PendingUsers 구조체 신설, pending→Save 트랜잭션으로 커밋" 문구를 정면 위반해 사실상 배제) 후 오케스트레이터가 옵션1(지시서 문구 그대로, diff 최소, 기존 유일한 "Save=세션 종료" 규칙과 일관)로 확정, 그대로 구현.
  - `ConfigPanel.swift`: `ConfigPanelIds`에 `accessOpen`/`accessAdmin`/`accessExecute`/`accessReadOnly`/`accessSave` 5개 id 추가. `ConfigPanelComponent`에 `.userSelect(customId:placeholder:defaultUserIds:minValues:maxValues:)` case 신설(`.roleSelect`와 완전히 동일 시그니처). `ConfigPanelResult`에 `.accessPanel(ConfigPanelSubView)` case 추가(👤 버튼 클릭 시 새 ephemeral 서브패널 — `.notifPanel`/`.renderPanel`과 동일 패턴). `ConfigPanelDefaults`에 `adminUserIds`/`executeUserIds`/`readOnlyUserIds`(기본값 `[]`) 추가, `configPanelDefaults()`가 `Authorizer.effectiveAuth`(WO-3)의 유저ID 3필드로 채우도록 확장. `PendingRoles` 옆에 `PendingUsers` 구조체 신설(`ConfigPanel` 인스턴스에 `pendingUsers` 프로퍼티로 보관), `accessTier(for:)`/`setUserTier(_:userIds:)`로 role 탭과 동일한 pending 라우팅. 메인 `render()`의 4번째 버튼 행(`[save, notif, renderBtn]`)에 `accessBtn`("👤 Access")을 추가만 하고 — 액션로우 하나가 버튼 5개까지 허용되므로 **행 개수(5행) 불변** — role/notif/render 서브패널 로직은 전혀 손대지 않음. `renderAccess()`(서브패널 렌더 — userSelect 3행 + Save 1행), `saveAccess()`(pending 커밋 → `ServerAuthPartial`의 유저ID 3필드만 갱신하고 나머지(역할ID 등)는 `existing?.auth`에서 보존 → `.saved(summary:)` 반환, role Save와 완전히 동일한 세션-종료 시맨틱), `formatUserList(_:)`(`<@id>` 멘션 포맷, role의 `<@&id>`와 구분) 추가.
  - `SlashSupport.swift`의 `configPanelActionRow`에 `.userSelect` 매핑 분기 추가 — DiscordBM `Interaction.ActionRow.Component.userSelect(SelectMenu)`가 `.roleSelect`와 동일 타입이라 `RoleSnowflake`→`UserSnowflake`만 다름.
  - `DabMain.swift`의 `handleConfigComponent`에 `.accessPanel` 분기 1개만 추가(`.notifPanel`/`.renderPanel`과 동일한 새 ephemeral 메시지 응답). 값 추출(`comp.values`)과 admin 게이트는 select 종류 무관하게 이미 제네릭이라 그 외 라우팅 변경 없음. `.saved` 케이스는 기존 그대로 재사용(신규 분기 불필요).
  - 신규 테스트 `swift/Tests/DiscordAgentBridgeTests/ConfigPanelAccessTests.swift` 작성(8케이스): id 인식, 메인 패널 렌더에 Access 버튼이 기존 save/notif/render 버튼 옆에 나란히 추가되고 행 개수는 불변인지, accessOpen이 userSelect 3행+Save 1행을 반환하는지, userSelect 선택이 Save 전까지 파일에 안 쓰이고(pending) 서브패널을 다시 열면 반영되는지, 값 누락 시 ignored, Save가 실제로 `servers/<guildId>.json`의 `auth.adminUserIds`/`executeUserIds`/`readOnlyUserIds`에 반영되는지, Access Save가 기존에 저장돼 있던 역할ID 필드를 보존하는지, 그리고 "관리자가 아닌 사람은 이 패널 자체를 못 여는지"는 `/config` 오픈과 `handleConfigComponent`(Access 버튼 포함)가 공유하는 동일한 `Authorizer.authorize(action: .admin)` 게이트로 검증(`dab` 타깃엔 테스트 타깃이 없어 WO-1/WO-5와 동일하게 라이브러리 레벨 게이트로 검증) — 비관리자 거부 + WO-3의 유저ID 기반 admin은 역할 없이도 통과하는 케이스 포함.
- 검증: `swift build --package-path swift` 성공(라이브러리) + `swift build --package-path swift --target dab` 성공(어댑터 코드 별도 확인). `swift test --package-path swift --filter ConfigPanelAccessTests` 8/8 통과. 회귀 확인용 `swift test --package-path swift --filter ConfigPanelTests`(기존 role/notif/render 탭) 22/22 통과 — 엄수사항(기존 서브패널 동작 무변경) 확인됨. 전체 `swift test`/`bash verify.sh`는 사용자 지시대로 생략(`.build` 인덱서 락 이슈).
- 바뀐 결정: 없음(오케스트레이터가 지정한 옵션1 그대로 구현).
- 마지막 WO 완료 — 문서 헤더 상태를 `검증중`으로 갱신, 7-1 에이전트 검증 체크박스 완료 처리. 남은 것은 7-2 사람 검증(사용자 몫)뿐.

### 2026-07-26 — RV: WO-1~5 통합 코드 리뷰
- 한 일: DEV의 5개 WO 산출물(위 로그)을 코드 기준으로 직접 재검증. `Authorizer.swift`(`isSetupBootstrapEligible:134-139`, `decide:143-171`, `resolveTier:174-183`), `GuildAdminCache.swift`(전체), `ConfigSchema.swift`(`GlobalAuth:30-60`, `ServerAuthPartial:296-318`), `ConfigStore.swift`(`addServerAdminUserId:216-254`, `loadAuthPartial:314-329`), `ConfigPanel.swift`(전체), `SlashSupport.swift`(`configPanelActionRow:401-425`), `SlashCommandSpec.swift`(`sweepStaleGuildCommands:237-246`), `DabMain.swift`(`onGuildCreate/onGuildRoleCreate/Update/Delete:113-146`, `/setup` 인가 분기 `296-333,608-641`, `registerSetupBootstrapAdmin:787-793`, `registerAgentCommand:169-192`, `runAndReply` isAdmin 계산 `1786-1798`, `handleConfigComponent` `.accessPanel` 라우팅 `937-1034`)을 읽고 대조.
- 검증 결과:
  - `swift build --package-path swift` 성공(27초). `swift build --package-path swift --target dab` 성공(2초).
  - `swift test --package-path swift --filter "GuildAdminCacheTests|AuthorizerUserIdTests|SlashCommandSweepTests|AuthorizerSetupBootstrapTests|ConfigPanelAccessTests|AuthorizerTests|ConfigPanelTests|ConfigStoreTests"` → 9 스위트 100/100 통과(8.5초).
  - `rg -n "adminUserIds|executeUserIds|readOnlyUserIds" swift/Sources | wc -l` → 67건(스키마/스토어/판정/패널/슬래시매핑 전반에 일관 사용, sanity 통과).
- 핵심 보안 게이트(WO-5) 판정: **뚫리지 않음.** `isSetupBootstrapEligible`이 서버-레이어까지 반영한 effective auth의 `adminRoleIds`+`adminUserIds`가 **둘 다** 비어있을 때만 true를 반환하고(`Authorizer.swift:134-139`), `DabMain.swift:300-306`은 `cmd.name == "setup"`이고 길드 컨텍스트일 때만 이 값을 확인해 `authorize()` 자체를 건너뛴다. 이미 admin이 하나라도(역할이든 유저ID든, 글로벌이든 서버든) 있으면 항상 false → 기존 `authorize()` 경로로 fail-secure 거부. 재확인 사항이 매 `/setup` 호출마다 `ConfigStore`에서 새로 읽어오므로(캐시 오염 없음), 한 번 admin이 생기면 이후 이 특례 분기는 재발동하지 않음을 코드로 확인.
  - 다만 **Medium 급 TOCTOU 레이스**를 발견(아래 리포트 참고): 관리자가 전혀 없는 길드에서 서로 다른 두 유저가 `/setup`을 거의 동시에 호출하면, 두 요청 모두 write 완료 전에 `isSetupBootstrapEligible`을 읽어 둘 다 true를 받을 수 있어 "최초 1인만" 원칙이 깨지고 두 유저 다 admin으로 등록될 수 있음. 기존 admin을 뺏거나 무단 승격시키는 구멍은 아니고(이미 admin이 있는 상태에서는 게이트가 정상 작동), 부트스트랩 창 안에서만 발생하는 좁은 레이스임 — 심각도 판단은 오케스트레이터/사용자 몫으로 남김.
  - WO-1(`GuildAdminCache`)/WO-2(`sweepStaleGuildCommands`)/WO-3(`resolveTier` OR 결합)/WO-4(Access 서브패널) 모두 설계문서·WO 지시서와 실제 구현이 일치함을 확인. 각 WO 세션이 로그에 적은 "3안 제시 → 옵션1 확정"과 실제 코드가 어긋나는 지점 없음.
- 발견한 이슈: 본문 하단 RV 리포트 참고(Medium 1건, Low 2건 — 코드는 수정하지 않음, 오케스트레이터 보고 대기).
- 바뀐 결정: 없음. 문서 상태 `검증중` 유지, 7-2 체크박스는 건드리지 않음.
