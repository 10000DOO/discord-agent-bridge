# 설계 문서 공유·뷰어 — 요구사항·분석·구현 핸드오프

> 상태: `요구사항·설계` · 작성: 2026-07-22  
> 목적: 이 문서만 읽고 Claude Code(또는 다른 구현 에이전트)가 **현재 레포(`discord-agent-bridge`)에 이어서 구현**할 수 있게 한다.  
> 범위 결정: **1차 구현은 현재 프로젝트(봇)만**. Vencord/BetterDiscord 플러그인은 **후속·별도** (같은 monorepo 폴더 가능, 실행/배포는 분리).

---

## 0. 독자·작업 규칙 (구현 에이전트 필독)

1. **Explore first**: 기존 스레드·첨부·표/mermaid 렌더·`chunkMessage`·`deliverAnswer` 패턴을 먼저 읽고 미러링할 것.
2. **Minimal change**: 요청 범위만. 권한 모드·effort·idle watchdog 등과 무관한 리팩터 금지.
3. **코드 변경**: 프로젝트 AGENTS.md 규칙을 따를 것 (architect/developer 서브에이전트 등).
4. **검증**: `npm test` / `npm run build` / 관련 단위 테스트 추가.
5. **이 문서의 1차 In 범위만 구현**. Out·후속은 구현하지 말 것 (스코프 크리프 방지).
6. `file:line` 은 드리프트 가능 — 심볼명으로 재확인할 것.

---

## 1. 배경·문제

### 1.1 사용자가 겪는 문제

1. AI 에이전트(Claude / Grok Build / Codex)에게 **설계 문서·마크다운 문서 작성**을 시킨다.
2. 에이전트가 `A.md` 등을 워크스페이스에 쓰고, 채팅에 **「A.md 작성 완료」** 식으로 답한다.
3. Discord 기본 UI는 **GFM 표·mermaid·긴 문서**를 제대로 보여주지 못한다.
4. 채널에 긴 md를 그대로 올리면 **가독성·스크롤·2000자 제한** 문제가 있다.
5. 사용자는 “문서 뷰어 플러그인”(BetterDiscord / Vencord 스타일) 또는 **최소한 스레드에 문서 내용을 올려 읽기**를 원한다.
6. AI로 “요약해서 설명해 달라”가 아니라, **문서 파일을 읽어서 렌더/표시**하는 것이 목표다.

### 1.2 관련 기존 기능 (이미 레포에 있음)

| 기능 | 위치·메모 |
|------|-----------|
| 최종 답변 표·mermaid → PNG | `design_table_mermaid_image_render.md`, `src/discord/render/*`, `answerDelivery` |
| 스레드 (Work log 등) | `TurnThreadRegistry`, `MessageChannel.startThread` |
| 메시지 청크 분할 | `chunkMessage` (`src/discord/format.ts`), Discord 2000자 |
| 파일 첨부/전송 | attach gateway, `OutgoingFile`, 세션 워크스페이스 경로 |
| 컨텍스트 `/clear` (세션 재시작) | Discord 슬래시 `/clear` (v1.0.6) — **문서 뷰어와 별개** |

### 1.3 의도적으로 하지 않은 오해 정리

| 오해 | 실제 |
|------|------|
| 채널에 `/clear` 텍스트 = Grok/Codex 컨텍스트 비움 | 일반 메시지. 진짜 리셋은 Discord 슬래시 `/clear` |
| Vencord 플러그인 = 서버에 설치 | **클라이언트 로컬** 모드. 팀 전원 공유 아님 |
| 플러그인만으로 에이전트 파일·스레드 생성 | 불가. 파일·스레드는 **봇/에이전트** 영역 |

---

## 2. 사용자 요구사항 (확정·수집분)

### 2.1 핵심 시나리오 (사용자 원문 요지)

> 에이전트한테 「설계 문서 만들어줘」  
> → 답변: 「A.md 설계문서 작성 완료했습니다.」  
> → **스레드 하나 생기고**  
> → **A.md를 렌더링해서 보여준다.**

### 2.2 기능 요구 (EARS 형식)

| # | 요구 | 완료 기준 (acceptance) |
|---|------|------------------------|
| R1 | WHEN 에이전트가 세션 cwd 안에 마크다운 문서를 새로 쓰거나 공유 대상으로 지정하면, 시스템은 해당 채널에 **문서용 스레드**를 만들 수 있어야 한다 | 스레드 이름이 문서 경로/제목을 식별 가능하게 포함 (예: `📄 A.md` 또는 `📄 docs/design-foo.md`) |
| R2 | WHEN 문서 스레드가 생성되면, 시스템은 문서 **원문**을 스레드에 전달해야 한다 | 첨부 `.md` 및/또는 청크된 본문. 전원(채널 멤버)이 공식 Discord로 읽을 수 있음 |
| R3 | WHEN 문서에 GFM 표 또는 mermaid 펜스가 있고 이미지 렌더 분기가 켜져 있으면, 시스템은 **기존 표/mermaid PNG 경로를 재사용**할 수 있어야 한다 | 새 렌더 엔진 발명 금지. `renderImage` / segment 파이프라인 정렬 |
| R4 | WHEN 문서가 Discord 메시지 한도를 넘으면, 시스템은 **순서 보존 청크**로 보내야 한다 | `chunkMessage` / `deliverAnswer` 패턴 미러 |
| R5 | 문서 표시는 **AI 재해석/요약이 아니라** 파일 내용 기반이어야 한다 | 모델에게 “다시 써 달라”가 아니라 fs read → post |
| R6 | 1차 구현은 **현재 봇 프로젝트만**으로 팀 공유 가능해야 한다 | Vencord 없이도 스레드+첨부로 읽기 가능 |
| R7 | (후속) 클라이언트 플러그인이 있으면 첨부를 **더 예쁘게** 렌더할 수 있다 | 봇이 안정적인 첨부·선택적 마커를 남기면 됨. 플러그인 본체는 Out |

### 2.3 비목표 (1차 Out)

- Vencord/BetterDiscord 플러그인 본 구현·배포 (후속 문서/레포)
- Discord Activity (iframe 문서 앱) 전체 구축
- PDF/DOCX 전용 뷰어, 양방향 편집
- 모든 파일 형식 자동 감지 (1차: **`.md` / `.markdown` 우선**, 확장 여부는 설정)
- 스트리밍 중 실시간 문서 프리뷰
- 컨텍스트 사용량 패널·`/clear` 동작 변경
- 서버(길드)별 복잡한 권한 매트릭스 (기존 drive 티어·세션 채널 권한 재사용)

### 2.4 성공 UX (사용자 관점)

1. 세션 채널에서 설계 요청.
2. 에이전트가 `docs/foo.md` 작성.
3. 채널(또는 스레드 부모 메시지)에 완료 한 줄.
4. **스레드** `📄 docs/foo.md` 생성.
5. 스레드 안: 파일 첨부 + (옵션) 본문 청크 + (옵션) 표/mermaid 이미지.
6. 멤버는 Discord만으로 문서 열람. (플러그인 있으면 더 예쁨 — 후속)

---

## 3. 플랫폼·방식 분석 (조사 결과)

### 3.1 BetterDiscord / Vencord 플러그인

- **정체**: 비공식 **Discord 클라이언트 모드**. 각 사용자 PC에 설치.
- **능력**: 메시지 DOM 패치, 첨부 fetch, 로컬 markdown→HTML 렌더, 모달/패널 UI.  
  유사 예: Vencord `ShikiCodeblocks`, `CopyFileContents`; BD `ZipPreview`, `LaTeX Renderer`, `enhancecodeblocks`.
- **가능**: AI 없이 `.md` 첨부 렌더 미리보기 — **기술적으로 가능**.
- **한계**:
  - 설치한 사람 **화면만** 예쁨. 팀 공유 UI 아님.
  - ToS/비공식 클라이언트 리스크.
  - 에이전트 워크스페이스 파일·봇 스레드 API와 **직접 연동 불가** (채널에 올라온 첨부/메시지만 봄).
- **결론**: “플러그인 방식”은 **가독성 레이어**. 사용자 시나리오의 **스레드 생성·파일 게시**는 플러그인만으로 불가.

### 3.2 공식 봇 (현재 프로젝트)

- **능력**: 스레드 생성, 메시지/임베드/첨부, 기존 PNG 렌더, 세션 cwd 파일 읽기(경로 가둠).
- **한계**: Discord 네이티브 md는 표/mermaid 약함 → 이미지/첨부 보완.
- **결론**: 사용자 시나리오 **1차 전부 봇으로 충족 가능**.

### 3.3 Discord Activity

- 서버 설치형 “미니 웹앱”에 가장 가까움. 개발·호스팅·인증 비용 큼 → **1차 Out**.

### 3.4 하이브리드 (최종 권장 아키텍처)

```
[에이전트 세션 cwd]
    write A.md
         │
         ▼
[discord-agent-bridge 봇]  ← 1차 구현 전부
    감지 또는 share_doc 도구
    → startThread("📄 …")
    → attach A.md + chunk body (+ optional PNG segments)
         │
         ▼
[Discord 전원] 스레드에서 읽기
         │
         ▼ (후속, 선택)
[Vencord 플러그인] 첨부 .md 클릭 시 로컬 풀 렌더
```

---

## 4. 1차 구현 설계 (봇 전용)

### 4.1 트리거 방식 (권장: 명시 도구 + 선택적 자동)

구현 에이전트는 **아래 중 권장안 A를 기본**으로 하고, B는 설정 플래그로 후속 가능하면 문서에만 남긴다.

#### 권장 A — 명시적 도구 / 커맨드 (안전·예측 가능)

1. **에이전트 도구** (모드별 또는 공통 MCP/내장 도구):  
   `share_document` / `post_document`  
   - 인자: `path` (세션 cwd 상대 또는 절대, **반드시 cwd 가둠**)  
   - 동작: 파일 읽기 → 스레드 생성 → 게시 → 도구 결과에 thread URL/id 반환  
2. 시스템/에이전트 규칙(AGENTS.md 또는 세션 intro)에:  
   「설계·스펙 md를 쓰면 완료 시 `share_document` 호출」 권장 문구 추가 가능 (최소 변경이면 도구만).

#### 대안 B — 휴리스틱 자동 (오탐 위험)

- 턴 종료 시 새로 생성된/수정된 `*.md` 감지 후 자동 스레드.  
- **1차에서는 비권장** (노이즈: README 터치, 임시 파일). 할 거면 allowlist glob + 사용자 config.

#### 대안 C — Discord 슬래시

- `/doc path:docs/a.md`  
- 수동 공유용. 도구 A와 **병행 가능**.

**1차 필수**: A (도구).  
**1차 권장 추가**: C (슬래시 `/doc`) — 에이전트 없이도 운영자가 공유 가능.  
**1차 제외**: B 자동 전체 스캔 (명시적으로 Out 또는 phase 2).

### 4.2 경로 보안 (필수)

- 기존 파일 다운로드/첨부와 동일: **realpath confinement to session cwd**.
- 심볼릭 링크 탈출 금지.
- 디렉터리·바이너리·과대 파일: 거부 메시지 (상한 예: 512KiB 텍스트 또는 config).

### 4.3 스레드·메시지 포맷

1. **부모 채널** (옵션, 짧게):  
   `📄 문서 공유: docs/design-foo.md` + 스레드 링크 성격의 안내  
   또는 도구만 스레드 생성하고 채널 본문은 에이전트 답변에 맡김.
2. **스레드 이름**: Discord 한도(`THREAD_NAME_LIMIT`) 내로 truncate. 예: `📄 design-foo.md`.
3. **스레드 첫 메시지(들)**:
   - 메타 임베드 또는 텍스트: 경로, 크기, 시각, (가능하면) 상대 경로
   - **파일 첨부** `design-foo.md` (원본 다운로드용) — 필수에 가깝게
   - 본문: plain/markdown 청크 순차 전송  
     - 전체 본문 전송이 너무 크면: 첨부만 + “전문은 첨부 파일”  
     - 권장 기본: **첨부 필수 + 본문은 상한 내 전문 또는 앞 N자 프리뷰** (구현 시 config: `full | preview | attachment_only`)
4. **표/mermaid**: 본문 경로에 `deliverAnswer` + `renderImage` 주입 가능할 때만 세그먼트 렌더. 없거나 실패 시 원문 유지.

### 4.4 모듈 배치 (기존 구조 정렬)

제안 위치 (구현 시 이름 조정 가능, 계층만 유지):

| 모듈 | 책임 |
|------|------|
| `src/discord/documentShare.ts` (신규) | path resolve, read, thread name, post plan (순수에 가깝게, MessageChannel 포트) |
| `src/discord/ports.ts` | 기존 `startThread` / `send` / files — 확장 최소화 |
| `src/discord/wiring.ts` 또는 mode MCP | 도구 → documentShare 연결 |
| Claude MCP 파일 도구 옆 또는 shared tool | `share_document` 노출 (모드별 등록 방식은 기존 MCP/file tool 패턴 따름) |
| `interactionRouter` + `client.ts` | 선택: `/doc` 슬래시 |
| `i18n.ts` | ko/en 문자열 |

**금지**: `providerCatalog` / permissionSource 와 순환 import. core는 Discord 미의존 유지.

### 4.5 i18n 키 (초안)

```
doc.thread.name          → 📄 {name}
doc.shared               → 문서를 스레드에 공유했어요: `{path}`
doc.error.notFound       → 파일을 찾을 수 없어요: `{path}`
doc.error.escape         → 세션 폴더 밖 경로는 공유할 수 없어요.
doc.error.tooLarge       → 파일이 너무 커요 (최대 {max}).
doc.error.notMarkdown    → 마크다운(.md)만 공유할 수 있어요.  (1차 정책이면)
cmd.doc.description      → Share a markdown document into a thread
```

영문 catalog도 동일 키로 추가.

### 4.6 권한

- 슬래시 `/doc`: 세션 채널 + `drive` 티어 (기존 `/clear`·메시지와 동일 계열).
- 도구 `share_document`: 세션 소유 에이전트 실행 맥락 — 추가 Discord 권한 불필요. 경로 가둠만.

### 4.7 설정 (최소)

`config.json` 또는 기존 render 설정 근처 (과도한 스키마 확장 금지):

```json
"documentShare": {
  "enabled": true,
  "maxBytes": 524288,
  "bodyMode": "preview",
  "previewMaxChars": 8000,
  "extensions": [".md", ".markdown"]
}
```

기본값으로도 동작. 필드 없으면 코드 DEFAULT.

---

## 5. 후속: Vencord 플러그인 (구현 금지, 명세만)

> Claude Code **이번 작업에서 구현하지 말 것.** 핸드오프용 메모.

### 5.1 목표

- 메시지 첨부 `.md` 에 「미리보기」 버튼 또는 자동 패널.
- fetch → markdown-it/marked → HTML. 표 CSS. (mermaid 선택)
- 봇이 남긴 HTML 주석 마커 예: `<!-- dab-doc path="docs/a.md" -->` 로 자동 펼침 (선택).

### 5.2 배치

- 옵션 1: 별도 레포  
- 옵션 2: monorepo `clients/vencord-markdown-preview/`  
- **discord-agent-bridge `src/` 봇 트리에 섞지 말 것.**

### 5.3 봇과의 계약

- 스레드에 **항상 원본 `.md` 첨부** (플러그인 입력).
- (선택) 첫 메시지 content에 안정적 마커 한 줄.

---

## 6. 구현 Work Orders (Claude Code용)

> 1회 1WO 권장. 완료 시 이 문서 6장 체크.

### WO-1: `documentShare` 코어 + 단위 테스트

- [ ] 신규 모듈: path confine, read utf-8, size limit, extension check  
- [ ] `shareToChannel({ channel, path, cwd, options })` → thread + attach + body strategy  
- [ ] fake `MessageChannel` 테스트 (startThread/send 호출 순서·escape 거부)

### WO-2: 에이전트 도구 `share_document` 연결

- [ ] 기존 파일 도구/MCP 등록 패턴 조사 후 동일 계층에 추가  
- [ ] Claude / Grok / Codex 중 **공통으로 노출 가능한 경로** 우선 (불가 시 Claude+Grok 먼저, Codex 동일 포트)  
- [ ] 도구 성공 시 에이전트가 볼 수 있는 결과 문자열 (thread 이름, path)

### WO-3: (권장) Discord `/doc` 슬래시

- [ ] `buildSlashCommands` + `ACTION_TIER` + `interactionRouter`  
- [ ] 활성 세션 cwd 기준 상대 경로  
- [ ] i18n ko/en  
- [ ] client/interactionRouter 테스트

### WO-4: 표/mermaid 연동 (조건부)

- [ ] `renderImage` 가능 시에만 body를 `deliverAnswer` 경로로  
- [ ] 실패 시 텍스트 폴백 (기존 정책)

### WO-5: 문서·설정·수동 검증

- [ ] README 또는 짧은 사용법 (한국어 가능)  
- [ ] `npm test` / `npm run build`  
- [ ] 수동: 세션에서 md 작성 → share → 스레드 확인

### WO-6: (후속, 이 핸드오프 밖) Vencord 플러그인 스캐폴드

- 별도 지시 없이 착수 금지.

---

## 7. 수용 테스트 시나리오 (사람·에이전트)

| # | 시나리오 | 기대 |
|---|----------|------|
| T1 | cwd 안 `docs/x.md` 공유 | 스레드 생성, 첨부 존재, 본문 또는 프리뷰 |
| T2 | cwd 밖 `/etc/passwd` | 거부, 스레드 없음 |
| T3 | 없는 파일 | notFound |
| T4 | 거대 파일 | tooLarge |
| T5 | 표 포함 md + 렌더 on | 이미지 또는 원문 폴백, 크래시 없음 |
| T6 | 세션 없는 채널에서 `/doc` | noSession |
| T7 | 동일 파일 두 번 공유 | 스레드 2개 허용 또는 정책 문서화 (권장: 매번 새 스레드, 단순) |

---

## 8. 기존 코드 진입점 (탐색 힌트)

구현 전 `rg` / 읽기 권장 심볼:

- `TurnThreadRegistry`, `startThread` — `src/discord/renderers/turnThread.ts`, `ports.ts`
- `chunkMessage`, `MSG_LIMIT` — `src/discord/format.ts`
- `deliverAnswer`, `splitAnswerSegments` — `src/discord/renderers/answerDelivery.ts`, `render/blockParser.ts`
- `confineWithin` / 파일 다운로드 가둠 — `messageRouter` attachment, file download
- 슬래시 등록 — `buildSlashCommands` in `client.ts`, `ACTION_TIER` / `handleSlash` in `interactionRouter.ts`
- 모드 도구 등록 — `modes/claude/mcpFileTool.ts`, Grok ACP mcpServers, Codex dynamic tools

---

## 9. 결정 로그 (제품)

| 결정 | 내용 |
|------|------|
| D1 | 1차 = **봇 only** in this repo |
| D2 | 플러그인 = 후속, 시나리오 완성 조건 아님 |
| D3 | 트리거 1차 = **명시 `share_document` (+ 선택 `/doc`)** , 전역 자동 스캔 비권장 |
| D4 | 표시 = **파일 원문 기반**, AI 재작성 금지 |
| D5 | 보안 = **cwd confinement** 필수 |
| D6 | 렌더 엔진 신규 금지, 표/mermaid는 기존 PNG 경로만 |

---

## 10. 사용자에게 전달할 한 줄 사용법 (구현 후)

1. 에이전트: 설계 md 작성 후 `share_document` (또는 규칙에 따라 자동 호출).  
2. Discord: `📄 …` 스레드에서 첨부/본문 확인.  
3. (나중) Vencord 쓰면 같은 첨부를 로컬에서 더 예쁘게.

운영자 수동: `/doc path:docs/foo.md` (WO-3 구현 시).

---

## 11. 관련 대화에서 나온 맥락 (참고, 구현 범위 아님)

아래는 같은 제품 라인의 배경 지식. **이번 문서 기능과 직접 구현 대상은 아님.**

- Grok/Codex effort·permission 동적 로드, idle 3분 알림, 답변 하단 재게시, `/clear` 세션 리셋 등은 **이미 별도 커밋/버전**으로 다룸.
- Grok 컨텍스트 %는 `_meta.totalTokens/window` 추정; Claude는 `getContextUsage()`. 채널 텍스트 `/clear` ≠ 세션 리셋.

---

## 12. 구현 에이전트 체크리스트 (시작 전)

- [ ] 이 문서 0·2·3·4·6장 읽음  
- [ ] Out(플러그인 본구현) 건드리지 않음  
- [ ] 기존 confine / thread / chunk 패턴 검색함  
- [ ] WO-1부터 순서대로  
- [ ] 테스트·빌드 통과 후 완료 보고 (사용자에게 커밋/버전은 요청 시에만)

---

*문서 끝.*
