# W15 — 3-계층 config/state TS 파리티 (Swift)

**Status**: design · awaiting approval  
**Branch**: `plan/swift-port`  
**Plan refs**: `SWIFT_PORT_PLAN.md` W15 / W15-a / W15-b  
**Scope**: design only (no app code in this doc’s authoring)

---

## 1. Goal

TS `ConfigStore` + `configSchema` + `ConfigResolver` + (W15-b) state migration / `archived` / `normalizeModeId` 를 Swift에 **최소 표면**으로 이식한다.

- 3-계층 resolve: **global → server → binding** (present 값만 이김)
- 파일: `$DAB_HOME` 또는 `~/.discord-agent-bridge/` 아래, **atomic write + 0600**
- W13 `AuthConfigStore` stopgap 을 전체 `ConfigStore` 로 흡수하되 **Authorizer fail-secure 동작·공개 API 깨지지 않게**
- `/config` UI 는 **W16-b** — 본 WO 범위 밖

---

## 2. As-is / To-be

### As-is (Swift, 현재)

| 영역 | 상태 | 근거 |
|------|------|------|
| Global config | `AuthConfigStore` 가 `config.json` 의 **auth 블록만** 읽음. fail-secure empty, never throws | `AuthConfigStore.swift:1–68` |
| Server config | 없음 | Authorizer 주석 D2/Q1=A (`Authorizer.swift:10–12`) |
| Binding layer (config resolve) | 없음. 세션은 `SessionRegistry`/`SessionStore` (`swift-state.json` v1, key=`channelId`) | `SessionStore.swift:42–72` |
| 3-layer merge | 없음 | — |
| normalizeModeId | 없음 (`Backend.grok` 단일) | `SessionRegistry.swift:4–8` |
| archived soft-delete | 없음 (`remove` hard-delete) | `SessionStore.swift:91–93` |
| state migrations | 없음 (고정 `version: 1`) | `SessionStore.swift:99` |

### To-be

| 영역 | W15-a | W15-b |
|------|-------|-------|
| `ConfigSchema` + defaults + 검증 | ✅ | — |
| `ConfigStore` global/server load·save, 0600, atomic, corrupt server → null | ✅ | — |
| `ConfigResolver` pure merge + resolve | ✅ | — |
| Authorizer: global+**server** auth layer (TS `effectiveAuth`) | ✅ | — |
| `AuthConfigStore` → facade 또는 삭제 (아래 §6) | ✅ | — |
| `normalizeModeId` on load | 권장 포함(소량) 또는 b | ✅ 필수 |
| state migration 훅 (ordered version steps) | 스텁 가능 | ✅ |
| `archived` soft-delete | — | ✅ |
| Session binding 필드 확장(profile/projectAuth/createdAt/key) | 최소 BindingView | ✅ 스키마 정렬 |
| `/config` 패널·Save UI | ❌ W16-b | ❌ |

---

## 3. Layer model (TS 그대로)

근거: `src/core/configResolver.ts:6–14`, `77–148`, `src/core/auth.ts:91–109`.

### 3.1 Resolved “defaults/limits” 스택 (ConfigResolver)

```
Level 1 GLOBAL   config.json          → defaults.*, limits.*
Level 2 SERVER   servers/<guildId>.json → defaults?.* , limits?  (optional fields only)
Level 3 BINDING  channel binding      → mode, permissionMode, permissionProfile only
```

**Merge rules** (`configResolver.ts:39–68`, `deepMerge`):

1. `undefined` in overlay = **absent** (fall through). Do not treat JSON `null` the same as absent for object leaves that use null as a real value (`permissionProfile: null` is a leaf — wholesale replace).
2. Plain objects recurse.
3. Arrays / non-objects / null: **replace wholesale** (not element-merge).
4. Server may set: mode, claudeModel, codexModel, permissionMode, permissionProfile, codexHome, claudeEffort, codexEffort, limits (partial).  
   **Not** from server in resolver: codexCliCommand / codexCliVersion (global only — see merge block `configResolver.ts:122–134`).
5. Binding may set only: `mode`, `permissionMode`←`permMode`, `permissionProfile`←`profile` (`configResolver.ts:137–145`).  
   Binding does **not** override models/effort/limits via ConfigResolver (session-local model/effort live on the binding for resume, but resolve() doesn’t layer them — matches TS).

**ResolvedConfig shape** (TS `configResolver.ts:17–37`):

```
mode, claudeModel, codexModel, permissionMode, permissionProfile,
codexHome, codexCliCommand, codexCliVersion,
claudeEffort?, codexEffort?,
limits: { maxSessionsPerUser, permissionTimeoutSec, codexTimeoutMs }
```

**resolveModeConfig** (`configResolver.ts:88–99`): narrow to mode-facing view  
`model(=claudeModel), codexModel, codexHome, codexCliCommand, codexCliVersion?, permissionTimeoutSec, codexTimeoutMs`.

### 3.2 Auth stack (Authorizer — separate from ConfigResolver)

근거: `auth.ts:91–109`.

| Layer | Rule |
|-------|------|
| Global `auth.*` | base |
| Server `auth.adminRoleIds` 등 **present 시 해당 티어 리스트 통째 교체** (widen OK) | per-tier replace |
| `dmPolicy` | **global only** (server has no dmPolicy field in schema) |
| Binding `projectAuth` | **intersect / narrow only** (already W13 call-arg hook) |

W15-a must restore server auth layer; W13 intentionally omitted it.

### 3.3 Global load defaults (applyDefaults)

근거: `config.ts:39–74`, `configSchema.ts:219–279`.

- Missing nested sections filled from `CONFIG_DEFAULTS`.
- `mergeNested`: missing → default; plain object → `{...def, ...raw}`; malformed array/primitive → pass-through so validation fails loudly (`config.ts:45–49`).
- Secrets `discord.token` / `clientId`: **no default**; missing → load fails.
- `CONFIG_VERSION = 2` (`configSchema.ts:217`). Config has **no ordered migration table** — forward-compat is defaults-only. W15-b “config migration hooks” = optional version-step table ready for future bumps (can be empty map today).

### 3.4 Server load fail-safe

근거: `config.ts:152–170`, `config.test.ts:211–234`.

- Missing file → `null` (no override).
- Bad JSON / schema fail → **warn + `null`**, never throw (authorize/resolve path safety).

### 3.5 Global load strictness

근거: `config.ts:101–114`, `config.test.ts:178–188`.

- Missing `config.json` → **throw** (setup required).
- Invalid object / validation fail → **throw**.

**Authorizer path exception (W13 keep):** never brick a request. Use fail-secure empty GlobalAuth when full load fails (see §6).

---

## 4. File locations / permissions

| Path | Role | Write | Perms |
|------|------|-------|-------|
| `<base>/config.json` | Global AppConfig | atomic tmp+rename | **0600** (non-Windows; Swift macOS always) |
| `<base>/servers/<guildId>.json` | ServerConfig | atomic | **0600** |
| `<base>/swift-state.json` | Swift session/bindings (existing) | atomic (already) | **0600** (already `SessionStore.swift:110–123`) |
| `<base>/state.json` | **TS Node only — do not write from Swift in W15** | — | — |

**base dir resolution** (match TS + existing Swift):

1. ctor-injected URL/path (tests)
2. else `DAB_HOME` if non-empty
3. else `~/ .discord-agent-bridge/`

TS: `config.ts:27–31`. Swift already: `AuthConfigStore.swift:43–52`, `SessionStore.swift:62–71`.

**Atomic write recipe** (match both TS `writeSecure` and SessionStore):

1. `mkdir -p` parent  
2. encode pretty JSON + trailing `\n` if cheap (TS always `\n`; SessionStore pretty+sortedKeys — **prefer prettyPrinted + sortedKeys** for stable diffs, trailing newline optional)  
3. write sibling `*.tmp`  
4. `chmod 0600` on tmp  
5. `replaceItemAt` / rename over target  
6. `chmod 0600` on final path  

Reuse pattern from `SessionStore.writeFile`; **do not** invent a grand FileStore framework. Small shared `func writeSecureJSON(to:value:)` free function is OK if it avoids third copy; otherwise duplicate ~15 lines (ponytail: no unrequested abstraction).

---

## 5. W15-a vs W15-b (plan 해석)

| | **W15-a** (레이어링 config) | **W15-b** (version / soft-delete / alias) |
|--|------------------------------|------------------------------------------|
| Deliverable | ConfigSchema, ConfigStore, ConfigResolver, Authorizer server auth, tests | normalizeModeId, state migration hooks, archived, binding schema alignment |
| Done when | resolve global/server/binding matches TS tests; server corrupt → null; 0600; Authorizer sees server role lists | load rewrites grok/grok-agent; markArchived; SessionStore version steps; migration tests |
| Depends | W13-a done | W15-a done (store exists) |
| Unblocks | W16-b `/config` | resume-on-boot filters, soft close parity |

**normalizeModeId** (`config.ts:22–25`):

```ts
if (mode === 'grok' || mode === 'grok-agent') return 'grok-build';
return mode;
```

Applied on: global `defaults.mode` load, server `defaults.mode` load, every state channel binding mode (`state/store.ts:83–85`).  
Swift today uses `Backend.grok` rawValue `"grok"` — **open decision** §10. If Backend stays `.grok`, normalizeModeId maps file strings → `"grok"` or introduce `.grokBuild` raw `"grok-build"`. Prefer: **store/normalize to `grok-build` string in config files; map to `Backend.grok` at boundary** until W16-f custom expands Backend enum. Minimal: pure `normalizeModeId(_:)` + apply on config loads in W15-a or b.

---

## 6. Replace AuthConfigStore without breaking W13

### Constraints

- Authorizer public method shape stays usable: `authorize(_:projectAuth:)` (`Authorizer.swift:97`).
- Fail-secure: missing/corrupt config → empty allowlists + `dmPolicy=deny` (`AuthConfigStore.swift:5–6`, tests).
- Comment contract: “W15-a folds this into a full ConfigStore **WITHOUT changing Authorizer’s signature**” (`AuthConfigStore.swift:4`, `Authorizer.swift:11–12`).

### Recommended approach (minimal)

1. **Add `ConfigStore` actor** (full schema). Injected `baseDir` / URLs for tests.  
2. **AuthConfigStore becomes a thin facade** over the same `config.json` path **or** over `ConfigStore`:
   - Keep `actor AuthConfigStore` + `load() -> GlobalAuth` for existing `Authorizer(config:)` and tests.
   - Internally: decode full file when possible; on failure → `.empty`.
   - **Extend** facade with `loadServerAuth(guildId:) -> ServerAuthPartial?` OR give Authorizer a second dependency.

**Preferred wiring (TS-shaped, still small):**

```text
Authorizer
  ├─ configStore: ConfigStore     // load() for global auth + loadServerConfig
  └─ (projectAuth still call-arg)

AuthConfigStore
  └─ deprecated typealias / wrapper used only if we want zero Authorizer signature churn
```

**Signature choice (pick one in implementation; default B):**

| Option | Change | Notes |
|--------|--------|-------|
| **A** | Keep `Authorizer(config: AuthConfigStore)` | Expand AuthConfigStore to also load server files; ConfigStore is separate for resolver/UI |
| **B (Recommended)** | `Authorizer(config: ConfigStore)` | TS 1:1; update AuthorizerTests fixtures to write full-enough config; delete or shrink AuthConfigStore to test helper |
| **C** | Protocol `AuthConfigReading` | Overengineering for one consumer — **reject** |

**effectiveAuth** port (`auth.ts:101–109`):

```swift
adminRoleIds    = server?.auth?.adminRoleIds    ?? global.adminRoleIds
executeRoleIds  = server?.auth?.executeRoleIds  ?? global.executeRoleIds
readOnlyRoleIds = server?.auth?.readOnlyRoleIds ?? global.readOnlyRoleIds
dmPolicy        = global.dmPolicy  // never server
```

**Dual load semantics on ConfigStore:**

| API | Behavior |
|-----|----------|
| `load() throws -> AppConfig` | TS strict (missing/invalid throws) |
| `loadAuth() -> GlobalAuth` | try load map auth; on any failure → `.empty` (W13) |

Authorizer uses `loadAuth()` + `loadServerConfig` (null-safe).

DabMain today: `Authorizer(config: AuthConfigStore.shared)` pattern (if wired) — switch to `ConfigStore.shared` under option B; greppable one-line.

**Do not break:** existing AuthorizerTests auth decisions, Administrator bypass, projectAuth intersect, dmPolicy.

---

## 7. Minimal Swift module layout

```text
swift/Sources/DiscordAgentBridge/Config/
  ConfigSchema.swift     // AppConfig, ServerConfig, Preset, defaults, version, leaf enums
  ConfigStore.swift      // actor: load/save global+server, writeSecure, helpers
  ConfigResolver.swift   // pure deepMerge + resolve(+ optional resolveModeConfig)
  NormalizeModeId.swift  // one function (or free func in ConfigSchema) — W15-a/b

// existing, lightly touched:
  Session/Authorizer.swift       // server auth layer
  Session/AuthConfigStore.swift  // facade or delete
  Session/SessionStore.swift     // W15-b: version migrate, archived
  Session/SessionRegistry.swift  // optional profile field later

swift/Tests/DiscordAgentBridgeTests/
  ConfigStoreTests.swift
  ConfigResolverTests.swift
  // AuthorizerTests.swift — add server-override cases
  // SessionStoreTests.swift — W15-b migration/archived
```

### Types (Codable, Sendable) — mirror TS, no Zod

Validation strategy (minimal, match project style):

- `Codable` structs with **optional** fields where schema is partial.
- After decode: `applyDefaults` pure function (port `config.ts:56–74`).
- Explicit validate: `discord.token/clientId` non-empty; `dmPolicy ∈ {deny,allow}`; `logLevel` enum; `permissionMode` allow-list for global/server Claude set; binding SessionPermMode wider set (Codex sandbox) like `state/schema.ts:12–22`.
- Unknown JSON keys: ignore on decode (Swift `Codable` default).
- Do **not** add a Zod-like validation library.

### ConfigStore surface (W15-a must)

```text
init(baseDir: URL? = nil)
var configPath / serverConfigPath(guildId)
exists() -> Bool
load() throws -> AppConfig
save(AppConfig) throws
loadServerConfig(guildId) -> ServerConfig?     // fail-safe
saveServerConfig(ServerConfig) throws
loadAuth() -> GlobalAuth                       // fail-secure for Authorizer
// Nice-to-have same PR if cheap (unblocks W16 without redesign):
addAutoAllowClaudeTool(name) -> Bool
setRenderEnabled / setChromiumDecision
addServerPreset / removeServerPreset           // can defer to W16-b if time-boxed
```

### ConfigResolver surface

```text
init(configStore: ConfigStore, bindingSource: ConfigBindingSource)
resolve(guildId:channelId:) async -> ResolvedConfig
resolveModeConfig(...) async -> ModeConfigView   // optional in a if unused

// Pure (test without disk):
static func merge(global:server:binding:) -> ResolvedConfig
```

**ConfigBindingSource** (avoid forcing full ChannelRegistry port):

```swift
public protocol ConfigBindingSource: Sendable {
  func configBinding(guildId: String, channelId: String) async -> ConfigBindingLayer?
}
public struct ConfigBindingLayer: Sendable {
  public var mode: String
  public var permissionMode: String
  public var permissionProfile: String?
}
```

Adapters:

- W15-a tests: in-memory fake.
- Production later: SessionStore / SessionRegistry adapter mapping `backend.rawValue` → mode, `permMode`, profile(nil until stored).

Do **not** rewrite SessionOrchestrator/ChannelRegistry wholesale in W15.

### SessionStore (W15-b only — design constraints)

Evolve toward TS binding fields **without** renaming file to `state.json` (avoid clobbering Node):

| Field | TS `channelBindingSchema` | Swift today | W15-b |
|-------|---------------------------|-------------|-------|
| key | `guildId:channelId` | `channelId` | migrate to composite key **or** keep channelId if guildId always on record (open §10) |
| mode | string | `backend` enum | keep backend; normalize aliases on load |
| sessionId | nullable | `backendSessionId` | rename optional later; not required for config |
| archived | bool | missing | add + `markArchived` |
| permissionProfile | nullable | missing | add optional |
| projectAuth | optional | missing | add optional (Authorizer hook can then read store) |
| createdAt | string | missing | add on first write |
| version | STATE_VERSION=2 | 1 | ordered migrations map |

Migration hook shape (port `state/store.ts:25–54`):

```text
migrations: [Int: (Raw) -> Raw]  // fromVersion → next
while version < CURRENT { apply; require version advanced }
```

v1→v2 (if composite keys adopted): rekey bare channelId using binding.guildId (`state/store.ts:26–35`).

---

## 8. Migration hooks scope (W15-b)

**In scope**

1. `normalizeModeId` on config global/server defaults.mode + state binding modes.  
2. `StateStore`/`SessionStore` ordered migrations to `STATE_VERSION`.  
3. `archived` flag + `markArchived(channelId)` (or guild+channel) soft-delete; hard `remove` remains for explicit purge.  
4. Empty **config** migration table + version stamp on save (`CONFIG_VERSION=2`) — defaults remain the compatibility mechanism.  
5. Unit tests: v1 fixture → v2; grok/grok-agent → grok-build; corrupt server still null.

**Out of scope (W15-b)**

- Importing / dual-writing TS `state.json`.  
- Resume-on-boot policy changes beyond skipping `archived == true`.  
- `/agent close` UX wiring to markArchived (call site can be one-liner later; API enough).  
- presetDrafts / autoUpdate / scheduledCommands full TS AppState (add only if a consumer in-tree needs them; otherwise leave SessionStore channels-focused).

---

## 9. What NOT to build

| Item | Owner |
|------|--------|
| `/config` Discord panel, role selects, Save, notification/image subpanels | **W16-b** |
| `/setup` channel provisioning | W16-c |
| `/doc`, always-allow UI, custom backend, toolThread/diff/statusEmbed, auto-update UI | W16-d…h |
| Chromium provisioner stack | S3 defer |
| Full `ChannelRegistry` class + event bus | later; BindingSource enough |
| Generic DI container / Config protocol hierarchy | no |
| Writing `state.json` for Node interop | no (unless user decides §10) |
| Live Discord integration tests | unit + fake FS only |
| Changing default Claude permMode bypass→default | W13-b deferred |

---

## 10. Open questions (user decision)

| # | Question | Recommendation |
|---|----------|----------------|
| Q1 | Authorizer dependency: keep AuthConfigStore facade (A) vs ConfigStore (B)? | **B** — fewer types long-term; update tests |
| Q2 | Session file: stay `swift-state.json` vs adopt `state.json`? | **stay swift-state.json** until single-runtime |
| Q3 | Binding map key: bare `channelId` vs `guildId:channelId`? | **B composite in W15-b** if multi-guild same channel id is possible; else keep bare + guildId field (current) |
| Q4 | `Backend.grok` rawValue vs file `grok-build`? | normalize on disk/string edges; keep enum `.grok` until product renames |
| Q5 | Ship `normalizeModeId` in W15-a or only b? | **a** (5 lines, prevents bad defaults early) |
| Q6 | Include preset helpers in a? | **defer to W16-b** unless DEV has slack — not needed for resolver/auth |

If no reply: implement **Q1=B, Q2=swift-state, Q3=keep channelId key + guildId field (no rekey), Q4=edge normalize, Q5=a, Q6=defer**.

---

## 11. Test plan (unit only, fake FS)

Pattern: `SessionStoreTests` temp dir + UUID (`SessionStoreTests.swift:5–8`); mirror TS cases in `config.test.ts` / `configResolver.test.ts` / `state/store.test.ts`.

### ConfigStoreTests

- save → load round-trip full config  
- applyDefaults for minimal `{discord:{token,clientId}}`  
- nested merge: `limits.maxSessionsPerUser` override, siblings default  
- missing file → throws on `load()`  
- malformed nested (auth as array) → throws  
- `loadAuth()` missing/corrupt → empty (never throws)  
- corrupt server JSON → null + no throw  
- server schema-fail → null  
- server round-trip  
- 0600 on saved config.json / server file  
- normalizeModeId on defaults.mode (if in a)

### ConfigResolverTests (pure merge + optional disk)

Port cases from `configResolver.test.ts:73–173`:

1. global-only  
2. server overrides; unset falls through  
3. other guild unaffected  
4. binding overrides server+global (mode/perm/profile)  
5. deep-merge limits siblings  
6. missing project → server; missing server → global  
7. effort server over global; unset → nil  

Use in-memory `ConfigBindingSource` fake; no Discord.

### AuthorizerTests (delta)

- server `executeRoleIds` replace global (widen case from TS `auth.test.ts`)  
- absent server field falls through  
- dmPolicy still global; corrupt global → deny  

### SessionStoreTests (W15-b)

- migration step advances version  
- archived round-trip + markArchived  
- normalizeModeId on load for mode strings if stored as string  
- still: corrupt → empty, 0600, load-merge-save  

No network, no DiscordBM in these tests.

---

## 12. Parallelizable DEV work packages

| ID | Package | Depends | Files (approx) | Parallel? |
|----|---------|---------|----------------|-----------|
| **P1** | ConfigSchema + defaults + validate + NormalizeModeId | — | `Config/ConfigSchema.swift` | yes |
| **P2** | ConfigStore load/save/server/0600 + ConfigStoreTests | P1 | `Config/ConfigStore.swift`, tests | after P1 |
| **P3** | ConfigResolver merge + tests | P1 (P2 for integration cases) | `Config/ConfigResolver.swift`, tests | P3 pure can start with P1 only |
| **P4** | Authorizer server auth + AuthConfigStore fold + test delta | P2 | `Authorizer.swift`, `AuthConfigStore.swift`, tests | after P2 |
| **P5** | DabMain / wiring inject ConfigStore.shared | P4 | `DabMain.swift` | after P4 |
| **P6** | W15-b SessionStore migrations + archived + tests | P2 optional | `SessionStore.swift`, tests | **parallel to P3/P4** after schema freeze |

Suggested sequence: **P1 → (P2 ∥ P3) → P4 → P5**; **P6** as W15-b PR.

Checklist for “W15-a done”:

- [ ] `ConfigStore` + `ConfigResolver` + schema in tree  
- [ ] Unit tests green (store + resolver + authorizer server cases)  
- [ ] Auth path fail-secure preserved  
- [ ] No `/config` UI  
- [ ] `swift test` full suite pass  

W15-b done:

- [ ] `normalizeModeId` covered  
- [ ] migration hooks + at least one step or empty-table with version bump path tested  
- [ ] `archived` + markArchived  
- [ ] tests green  

---

## 13. Impact analysis

| Touch | Risk | Mitigation |
|-------|------|------------|
| Authorizer init type | test/DabMain compile break | single PR; update call sites |
| AuthConfigStore delete | external? none (lib-internal) | keep empty facade 1 release if desired |
| Config.json stricter parse | Authorizer was partial-decode tolerant | `loadAuth()` stays partial-tolerant; only `load()` strict |
| Disk layout `servers/` | new dir | created on first saveServerConfig |
| SessionStore schema (b) | old swift-state.json | migration or optional fields with defaults |

**Rollback:** revert PR; AuthConfigStore-only path remains on previous commit. No DB. Config files written by new code remain valid JSON for partial AuthConfigStore readers (auth block unchanged).

---

## 14. Migration steps (implementation order for DEV)

1. Land P1 types (no wiring).  
2. Land P2 ConfigStore with temp-dir tests; do not switch Authorizer yet.  
3. Land P3 resolver pure tests.  
4. Switch Authorizer → ConfigStore + server effectiveAuth; keep fail-secure.  
5. Delete or facade AuthConfigStore; fix tests.  
6. Optional: DabMain uses resolved defaults for `/agent start` when options omitted (nice; not required for a exit).  
7. W15-b: SessionStore version + archived + normalizeModeId on state.  

---

## 15. TS citation index (primary)

| Topic | Location |
|-------|----------|
| normalizeModeId | `src/core/config.ts:22–25` |
| baseDir / paths | `config.ts:27–31, 87–93` |
| applyDefaults / mergeNested | `config.ts:39–74` |
| load/save global | `config.ts:101–121` |
| loadServer fail-safe | `config.ts:152–170` |
| writeSecure 0600 | `config.ts:231–241` |
| schema + defaults | `src/core/configSchema.ts` (esp. 30–117, 139–214, 216–279) |
| deepMerge + resolve | `src/core/configResolver.ts:43–148` |
| resolver tests | `src/core/configResolver.test.ts` |
| store tests | `src/core/config.test.ts` |
| state schema / archived | `src/core/state/schema.ts:26–55, 80–104` |
| state migrate v1→v2 | `src/core/state/store.ts:25–54, 71–99` |
| ChannelRegistry markArchived | `src/core/channelRegistry.ts:151–161` |
| Authorizer effectiveAuth | `src/core/auth.ts:91–109` |
| Swift Auth stopgap | `swift/.../AuthConfigStore.swift` |
| Swift atomic 0600 pattern | `swift/.../SessionStore.swift:110–123` |

---

## 16. Approval

Approve (or answer §10) before DEV implements. On feedback, this file is updated in place.
