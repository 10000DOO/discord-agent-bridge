import Foundation

/// Embedded orchestration assets (always-rules + skills + subagents).
/// Bodies are drawn from docs/orchestration-slim-guide.md and
/// docs/orchestration-skill-subagent-specs.md (original rsup-ai role MDs, DAB-slimmed).
public enum OrchestrationBundle {
    public static let markerBegin = "<!-- dab-orchestration BEGIN -->"
    public static let markerEnd = "<!-- dab-orchestration END -->"

    /// Claude plugin keys forced on in `~/.claude/settings.json` `enabledPlugins` (DAB R1).
    public static let claudeLSPPluginKeys: [String] = [
        "swift-lsp@claude-plugins-official",
        "clangd-lsp@claude-plugins-official",
    ]

    /// One Grok `~/.grok/lsp.json` top-level language-server entry (DAB R1, Grok).
    public struct GrokLSPServerEntry: Sendable, Equatable {
        public let key: String
        /// Pre-formatted JSON object literal (starts at column 0, 2-space nested indent).
        public let jsonLiteral: String
    }

    /// Grok LSP server entries forced into `~/.grok/lsp.json` (DAB R1, Grok).
    public static let grokLSPServerEntries: [GrokLSPServerEntry] = [
        GrokLSPServerEntry(key: "swift", jsonLiteral: """
        {
          "command": "sourcekit-lsp",
          "args": [],
          "extensionToLanguage": { ".swift": "swift" }
        }
        """),
        GrokLSPServerEntry(key: "objective-c", jsonLiteral: """
        {
          "command": "clangd",
          "args": ["--background-index"],
          "extensionToLanguage": { ".m": "objective-c", ".h": "objective-c", ".mm": "objective-cpp" }
        }
        """),
    ]

    /// Always-on block for CLAUDE.md / AGENTS.md (same substance).
    public static let alwaysRulesMarkdown = """
    ## 이슈 오케스트레이션 (항상)

    1. 순서: 이슈 분석 → 설계 협업 → **영향도 분석** → 설계 확정 → 사람 최종 승인 → 구현 → 확인 → 완료. 승인 전 구현 금지.
    2. 기본적으로 이 절차를 축약하지 말고, 아래 **스킬·서브에이전트를 단계에 맞게 적극 사용**해 진행한다.
    3. **경미·축약 가능**해 보여도(단계·스킬·서브·긴 산출물 생략) **스스로 생략하지 말고**, 무엇을 줄일지·왜 경미한지·어떻게 짧게 갈지 사람에게 먼저 묻고 **동의를 받은 뒤에만** 간단 경로로 진행한다. 동의 없으면 정식 절차를 따른다.
    4. 스킬: `issue-orchestration`(전체 진행) · `issue-analysis`(이슈 분석·영향도 분석) · `issue-artifacts`(산출물) · `issue-implementation`(구현). 해당 단계에 들어가면 그 스킬을 읽고 따른다.
    5. 서브에이전트: 이슈 분석→`issue-analyzer` · 영향도 분석→`impact-analyzer` · 구현 분업→`module-implementer` · 공통 이관→`common-handoff` · 설계 점검→`design-critic`. 생략·메인 직행은 **3번 사람 동의 후**만; 동의한 생략 항목은 한 줄로 남긴다.
    6. 설계 중 미결·선택·불확실이 있으면 파일에 묻지 말고 Discord에 **번호 질문 + 항목별 권장안**을 바로 제시한다. DESIGN에는 결정된 내용만 쓴다.
    7. **영향도 분석** 결과는 `docs/issues/{번호}/IMPACT.md`(또는 DESIGN의 `## 영향도 분석`)에 남긴다. 사람 동의 없이 분석 생략·구현 금지. 리스트 밖 수정 시 멈추고 분석·설계를 갱신한다.
    8. 산출물: `docs/issues/{이슈번호}/` — STATUS, DESIGN, IMPACT, REPORT(완료 시), NOTES(선택). 축약 시에도 동의한 최소 산출물만 생략한다.
    9. 커밋: `{type}(#{이슈}): {제목}`. AI 출처 문구 금지. 공개 API 변경 시 README/가이드를 같이 갱신한다.

    (설치: discord-agent-bridge `/orchestration` · 근거: rsup-ai ORCHESTRATOR/AGENT 규약 슬림)
    """

    public struct Skill: Sendable, Equatable {
        public let id: String
        public let skillMarkdown: String
    }

    public struct Subagent: Sendable, Equatable {
        public let id: String
        /// Claude agent file body (.md + YAML frontmatter) — matches ~/.claude/agents/*.md
        public let claudeMarkdownBody: String
        /// Codex agent description (short).
        public let codexDescription: String
        /// Codex `developer_instructions` (no outer quotes) — matches ~/.codex/agents/*.toml
        public let codexInstructions: String
        /// Grok `permission_mode` (architect uses plan; developer uses default).
        public let grokPermissionMode: String
    }

    public static let skills: [Skill] = [
        Skill(id: "issue-orchestration", skillMarkdown: skillIssueOrchestration),
        Skill(id: "issue-analysis", skillMarkdown: skillIssueAnalysis),
        Skill(id: "issue-artifacts", skillMarkdown: skillIssueArtifacts),
        Skill(id: "issue-implementation", skillMarkdown: skillIssueImplementation),
    ]

    public static let subagents: [Subagent] = [
        Subagent(
            id: "issue-analyzer",
            claudeMarkdownBody: agentIssueAnalyzer,
            codexDescription: "이슈 요구/오류 분석. 관련 코드 위치·범위·경미/복잡 보고. 읽기 전용.",
            codexInstructions: agentIssueAnalyzerBodyOnly,
            grokPermissionMode: "plan"
        ),
        Subagent(
            id: "impact-analyzer",
            claudeMarkdownBody: agentImpactAnalyzer,
            codexDescription: "설계 기준 영향도 분석·수정 리스트. 읽기 전용. 빌드 금지.",
            codexInstructions: agentImpactAnalyzerBodyOnly,
            grokPermissionMode: "plan"
        ),
        Subagent(
            id: "module-implementer",
            claudeMarkdownBody: agentModuleImplementer,
            codexDescription: "승인 설계·영향 범위 내 구현. 범위 밖 수정·명세 외 기능 추가 금지.",
            codexInstructions: agentModuleImplementerBodyOnly,
            grokPermissionMode: "default"
        ),
        Subagent(
            id: "common-handoff",
            claudeMarkdownBody: agentCommonHandoff,
            codexDescription: "공통/범위 밖 수정 개발 요청서 작성. 대상 소스 수정 금지.",
            codexInstructions: agentCommonHandoffBodyOnly,
            grokPermissionMode: "plan"
        ),
        Subagent(
            id: "design-critic",
            claudeMarkdownBody: agentDesignCritic,
            codexDescription: "DESIGN·영향도 분석 검토. 구멍·모순·테스트 누락. 읽기 전용.",
            codexInstructions: agentDesignCriticBodyOnly,
            grokPermissionMode: "plan"
        ),
    ]
}

// MARK: - Skills (from orchestration-skill-subagent-specs.md / original O·A·DM)

private let skillIssueOrchestration = """
---
name: issue-orchestration
description: >-
  Redmine/Discord 이슈를 분석→설계 협업→영향도 분석→승인→구현→확인→완료로 진행한다.
  휴먼 게이트·대화 우선·스킬/서브 호출 시점을 총괄한다. Use for issue orchestration workflow.
---

# 이슈 오케스트레이션

근거: rsup-ai `ORCHESTRATOR_CONSTRAINTS.md` (O) §0·3·4·6·7·10·11 · DAB 슬림.

## 역할 [원본 O §0]
- 제품(프로젝트) 단위 개발 총괄. 판단·설계·취합·게이트를 담당한다.
- 휴먼과의 업무 통신(게이트·보고·알림)은 이 세션 창구를 경유한다.
- 상태는 파일·산출물에 영속화한다. 승인 대기를 세션 상주로 구현하지 않는다.

## 작업 모델 [원본 O §3]
- Redmine 이슈 1개 = 워크스페이스 1개. 기능/오류 동일 프로세스.
- HOTFIX 개념 없음. 버전은 개발 단계에서 결정하지 않는다.

## 필수 순서 [원본 O §4 + DAB]
이슈 분석 → 설계 협업 → 영향도 분석 → 설계 확정 → 사람 최종 승인 → 구현 → 확인 → 완료.

| 단계 | 원본 | 할 일 |
|------|------|--------|
| 이슈 분석 | P0~P1 전단 | 요구 파악, 경미/복잡 판단 |
| 설계 협업 | P1 + §7-4 | 초안, 열린 결정은 대화로 확정 |
| 영향도 분석 | P1 리스트 + P2 코드 영향도 | IMPACT 작성 |
| 설계 확정 | P1 TECHNICAL_DESIGN | DESIGN에 결정만 |
| 최종 승인 | §7-2 ② | 승인 전 구현 금지 |
| 구현 | P3 | issue-implementation / module-implementer |
| 확인 | P4 | 휴먼 테스트 요청 |
| 완료 | P5 | REPORT |

### 경미 경로 [원본 O P0·§7-1 + DAB]
축약 가능해 보여도 **스스로 생략하지 말고**, 무엇을 줄일지·왜 경미한지·간단 경로를 사람에게 묻고 **동의 후에만** 간단 진행.

## 설계 협업 · 대화 우선 [원본 O P1, §7-4 MANDATORY]
- 미결을 설계서에 남기지 말고 대화로 확정한다.
- 번호 매긴 질문 + 항목별 권장안을 제시하고 휴먼 답변을 기다린다.
- 확정 DESIGN에는 **결정된 내용만** (미결 섹션 금지).
- 파일에만 적고 조용히 멈추지 않는다.
- 규약상 결정적 사안(예: 공통모듈 정합 위치)은 우회 선택지를 만들지 않는다.

## 고정 휴먼 게이트 [원본 O §7-2]
1. 이슈 착수 확인  2. 설계+영향도 분석 리뷰  3. 휴먼 테스트  (4. release — 제품 범위 시)

## 스킬·서브 사용 [DAB]
| 단계 | 스킬 | 서브 |
|------|------|------|
| 이슈 분석 | issue-analysis | issue-analyzer |
| 영향도 분석 | issue-analysis | impact-analyzer |
| 산출물 | issue-artifacts | — |
| 구현 | issue-implementation | module-implementer |
| 이관 | — | common-handoff |
| 설계 점검 | — | design-critic |

## 정합 위치 · 이관 [원본 O P1]
- 올바른 위치에 설계. 프로젝트 모드에서 공통모듈 우회 금지 → handoff.
- `COMMON_MODULE_HANDOFF` 취지 + `docs/issues/{이슈}/handoff/{id}.md`

## 산출물 경로 [DAB]
`docs/issues/{이슈번호}/` — STATUS, DESIGN, IMPACT, REPORT, NOTES(선택), handoff/(선택).

## 범위 [원본 O §10]
- 보고·산출 없이 완료 추측 금지. AI 출처 표식 금지.
"""

private let skillIssueAnalysis = """
---
name: issue-analysis
description: >-
  이슈 분석과 설계 이후 영향도 분석(수정 모듈/파일 리스트·연쇄 영향)을 수행한다.
  이 단계에서는 기능 코드를 수정하지 않는다. Use for issue analysis and impact analysis.
---

# 이슈·영향도 분석

근거: O P0/P1, DM §3-2, A §3-1 · DAB 경로.

## 공통
- 분석 목적 소스 **읽기 허용**. 이 스킬 구간 **기능 코드 수정·커밋 금지**.
- 설계 원칙 파일(SOLID 등)이 있으면 로드·준수. [원본 O P1, DM §3-2, A §3-1]

## 0. 참고문서 캐시 (착수 전) [DAB R2]
- 대상 프로젝트 루트 `.dab-index/PROJECT_INDEX.md` + `.dab-index/fingerprint` 확인.
- 지문(정렬된 소스 파일 경로 목록의 해시) 재계산 후 저장값과 비교: 일치 → 캐시 읽고 배경지식으로 사용, LSP 전수 스캔 생략. 없음/불일치 → 재생성.
- 재생성: LSP 도구(documentSymbol/workspaceSymbol/incomingCalls/outgoingCalls, 언어 미지원 시 grep+디렉터리 트리 대체)로 모듈/파일 구조·공개 API 목록·주요 호출관계 요약 작성 → `.dab-index/` 두 파일 갱신, `.gitignore`에 `.dab-index/` 없으면 추가.
- 이 캐시는 참고용 개요일 뿐 단일 진실이 아니다. 이슈별 정밀 조회(특정 심볼 최신 참조 등)는 캐시로 대체하지 말고 그때그때 LSP 직접 호출.

## 1. 이슈 분석 [원본 O P0, §8]
- 요구/오류 현상 정리, 경미 vs 복잡 판단.
- 오류면 원인 판단 우선 가능 (진단 트랙).
- 규모 크면 서브 `issue-analyzer`.

## 2. 영향도 분석 [원본 O P1, DM §3-2, A §3-1]
설계 초안 후 (구현 전):
1. 정합성·구조 측면 영향도 분석
2. 수정 모듈 리스트 (목표 버전 산출 금지)
3. 코드 영향도 (기존 코드 수정 시; 신규 모듈은 A §3-1-1 생략 가능 — 근거 남김)
4. 신규/변경 API → 계약 (시그니처·타입·스레드 규약)
5. 문제 → "문제 보고" 섹션. 빌드·컴파일 검증 금지 (정적 분석 전용)
6. 정합 위치가 공통/범위 밖이면 이관 후보 (우회 제안 금지)

## 3. 산출 [DAB]
`docs/issues/{이슈}/IMPACT.md` 또는 DESIGN `## 영향도 분석`

## 4. 이후 [원본 O P1·P2]
문제 시 구현 금지 → 설계 수정·휴먼 협의. 정상이면 확정 설계·승인.

## 5. 서브
영향도 분석 → `impact-analyzer` (생략은 사람 동의 후에만).
"""

private let skillIssueArtifacts = """
---
name: issue-artifacts
description: >-
  docs/issues 아래 STATUS·DESIGN·IMPACT·REPORT 등 산출물 경로와 섹션을 작성한다.
  Use when writing issue work documents.
---

# 이슈 산출물 작성

근거: O P1·§6, 설계서 5-6-1 WORK_REPORT, A handoff · DAB 경로.

## 경로 [DAB]
`docs/issues/{이슈번호}/`

## single-writer [원본 5-6-1]
이슈 본문 산출물은 오케스트레이션 측 작성. 휴먼 리뷰 파일은 휴먼만 (Discord 리뷰 시 파일 생략 가능).

## STATUS.md
원본 state 필드 취지: issue, phase, gate, status, updated_at, note.

## DESIGN.md [원본 O P1 TECHNICAL_DESIGN]
- 목적/범위 · 모듈 구조 · API 계약 · (또는 IMPACT로 분리한) 코드 영향도
- **결정된 내용만** — 미결 섹션 금지. 열린 결정 있으면 확정본 쓰지 말고 대화 질문.

## IMPACT.md [원본 O P1 + A §3-1]
수정 대상 · 연쇄 영향 · API 변화 · 테스트 포인트 · 문제 보고 · 이관 후보.

## REPORT.md [원본 WORK_REPORT 5-6-1]
1. 이슈 요약 2. 설계·영향도 분석·API 3. 적용 모듈·commit 4. 코드 작업 5. 테스트 6. 체크리스트  
P5 완료 시. 재료=기존 산출물 조립. 비차단 사후 리뷰.

## handoff/{대상}.md [원본 A §3-2]
무엇을·왜 · 제안 인터페이스 · 영향 범위. 경로: `docs/issues/{이슈}/handoff/{id}.md`
"""

private let skillIssueImplementation = """
---
name: issue-implementation
description: >-
  사람 승인·영향도 분석 이후 구현·빌드·테스트·문서 갱신·커밋 규약.
  Use when implementing an approved issue design.
---

# 이슈 구현 규칙

근거: A §3-1-1·§3-2·§4·§5 · O 게이트 · DAB 최종 승인.

## 진입 조건
- 확정 DESIGN + 영향도 분석 결과 (수정 작업; 신규는 A 예외 가능)
- **사람 최종 승인** 후. 승인 전·설계 협업 중 구현 금지. 축약은 사람 동의 후만.

## 순서 [원본 A §3-1-1]
1. 설계 검토  2. 영향 리스트 대조  3. 불가면 강행 금지·문제 보고 (IMPL_BLOCKED 취지)  4. 승인 설계대로 구현 — 명세 외 기능 추가 금지

## P3 [원본 A §3-2]
- 프로젝트 관례·팀 코딩 규칙 준수
- 공개 API·사용법 변경 시 README/INTEGRATION_GUIDE 등 **같은 작업에서** 갱신 (없으면 완료 보고 금지)
- 계약 이행 불가 시 즉시 문제 보고

## 공통모듈 이관 [원본 A §3-2]
프로젝트 범위에서 공통 직접 수정 금지 → handoff + `COMMON_MODULE_HANDOFF: {id}`. 우회 선택지 금지.

## git [원본 A §4]
`{유형}(#{이슈}): {제목}` · AI 출처 문구 금지 (Co-Authored-By, Generated with 등).

## 범위 [원본 A §5·§6]
담당 범위 밖 수정 금지. 모호하면 추측 진행 금지·보고. 프로젝트 관례 우선.

## 서브
분업 → `module-implementer` · 이관 → `common-handoff`
"""

// MARK: - Subagents

private let agentIssueAnalyzerBodyOnly = """
# 이슈 분석 서브에이전트

## 권한
소스·이슈 본문 읽기 전용. 기능 코드 수정·커밋 금지. [원본 O 분석 읽기]

## 임무 [원본 O P0, §8, §8-2]
- 요구/오류 한 줄 정의, 관련 코드 위치·후보 모듈, 범위 in/out
- 경미 vs 정식 설계 판단 재료, 오류면 1차 원인 가설(근거 없으면 불명)
- 정합 위치·공통 이관 힌트

## 반환
## 문제/요구 한 줄
## 관련 코드 위치
## 범위 in / out
## 경미 vs 정식 설계 (근거)
## 설계·다음 단계 힌트
## 막힌 점 / 사람 확인 필요
"""

private let agentIssueAnalyzer = """
---
name: issue-analyzer
description: "이슈 요구/오류 분석. 관련 코드 위치·범위·경미/복잡 보고. 읽기 전용."
---

\(agentIssueAnalyzerBodyOnly)
"""

private let agentImpactAnalyzerBodyOnly = """
# 영향도 분석 서브에이전트

## 권한
읽기 전용. 기능 코드 수정·커밋·빌드 금지. [원본 O P2, A §3-1 정적 분석]

## 참고문서 캐시 [DAB R2]
분석 시작 전 대상 프로젝트 `.dab-index/PROJECT_INDEX.md` 확인. 지문(정렬된 소스 파일 경로 목록 해시) 재계산해 저장값과 비교: 일치 시 그대로 사용, LSP 전수 스캔 생략. 없거나 불일치면 LSP(documentSymbol/workspaceSymbol/incomingCalls/outgoingCalls, 미지원 언어는 grep 대체)로 재생성 후 `.dab-index/`에 두 파일 갱신(`.gitignore`에도 반영). 캐시는 참고용 개요 — 특정 심볼 정밀 확인은 캐시 대신 직접 LSP 호출.

## 임무 [원본 O P1, DM §3-2, A §3-1]
설계 초안 기준:
1. 정합성·구조 영향도 분석
2. 수정 모듈 리스트 (목표 버전 금지)
3. 코드 영향도 (기존 수정 시)
4. API 계약 (신규/변경 시)
5. 문제 보고 섹션
6. 이관 후보 (우회 제안 금지)
7. 회귀·테스트 포인트

API 부재: 계약에 있으면 구현 예정 정상 / 계약에도 없으면 오류. [원본 A §3-1]

## 반환 (= IMPACT 초안)
## 수정 대상
## 연쇄 영향
## API·동작 변화
## 회귀·테스트 포인트
## 문제 보고
## 설계 수정 권고
## 이관 후보
"""

private let agentImpactAnalyzer = """
---
name: impact-analyzer
description: "설계 기준 영향도 분석·수정 리스트. 읽기 전용. 빌드 금지."
---

\(agentImpactAnalyzerBodyOnly)
"""

private let agentModuleImplementerBodyOnly = """
# 모듈 구현 서브에이전트

## 권한
메인이 지정한 경로만 쓰기. [원본 A §5]

## 순서 [원본 A §3-1-1]
설계 검토 → 영향 리스트 대조 → 불가 시 중단·문제 보고 → 승인 설계대로 구현. 명세 외 추가 금지.

## 문서 [원본 A §3-2]
공개 API 변경 시 README/가이드 동시 갱신. 보고에 문서 갱신 섹션 또는 "해당 없음: 사유".

## 커밋 [원본 A §4] (허용 시)
`{유형}(#{이슈}): {제목}` · AI 출처 금지.

## 반환
## 결과: 성공 | 막힘
## 변경 파일
## 한 일
## 커밋
## 문서 갱신
## 확인 방법
## 막힘 사유
"""

private let agentModuleImplementer = """
---
name: module-implementer
description: "승인 설계·영향 범위 내 구현. 범위 밖 수정·명세 외 기능 추가 금지."
---

\(agentModuleImplementerBodyOnly)
"""

private let agentCommonHandoffBodyOnly = """
# 공통모듈 이관 요청 서브에이전트

## 권한 [원본 A §3-2 읽기 전용]
대상 소스 읽기만. 소스 수정·커밋 금지. handoff 경로 요청서만 작성.
DAB 경로: `docs/issues/{이슈}/handoff/{모듈id}.md`

## 임무 [원본 A §3-2]
1. 정합상 이 모듈 소속인지 소스 근거 판별
2. 수정 개발 요청서: 무엇을·왜 · 제안 인터페이스 · 영향 범위
3. 보고 마지막: `COMMON_MODULE_HANDOFF: {모듈id}`
4. 구현하지 않음. 우회 선택지 금지.

## 요청서 섹션
## 대상 모듈
## 무엇을 왜
## 제안 인터페이스
## 영향 범위
## 참고 파일
"""

private let agentCommonHandoff = """
---
name: common-handoff
description: "공통/범위 밖 수정 개발 요청서 작성. 대상 소스 수정 금지."
---

\(agentCommonHandoffBodyOnly)
"""

private let agentDesignCriticBodyOnly = """
# 설계 검토 서브에이전트

## 권한
읽기 전용. 재작성·구현 금지. 1차 설계 재작성은 메인 몫. [원본 A §3-1-1]

## 임무
DESIGN과 영향도 분석 결과 대조: 실현 가능성·계약 모순·리스트 불일치·테스트 누락·설계서 미결 잔존.

## 반환
## 치명
## 권장
## 테스트 빠짐
## 총평: 사람 승인 올려도 됨 | 수정 후 재검토
"""

private let agentDesignCritic = """
---
name: design-critic
description: "DESIGN·영향도 분석 검토. 구멍·모순·테스트 누락. 읽기 전용."
---

\(agentDesignCriticBodyOnly)
"""
