import Foundation

/// Embedded project-scoped orchestration content for `/dab-orchestration` (design
/// design_orchestration_project_scoped_command.md §4.3). Hand-ported verbatim from
/// `docs/sample/` (1 CLAUDE.md + 6 agents + 20 skills) — same manual hand-porting
/// convention already used by `OrchestrationBundle` for the (now removed) global
/// 3-backend installer. Unlike that type, this bundle is Claude-only (no per-backend
/// field split needed) — every file's content is installed as-is under `<project>/.claude/`.
public enum OrchestrationProjectBundle {
    public struct Skill: Sendable, Equatable {
        public let id: String
        public let markdown: String
    }

    public struct Subagent: Sendable, Equatable {
        public let id: String
        public let markdown: String
    }

    /// docs/sample/CLAUDE.md — installed verbatim as `<project>/.claude/CLAUDE.md`.
    public static let claudeMdBody: String = claudeMdRaw

    /// docs/sample/skills/*/SKILL.md (20), installed as `<project>/.claude/skills/{id}/SKILL.md`.
    public static let skills: [Skill] = [
        Skill(id: "arc-retain-cycle-hunt", markdown: skillArcRetainCycleHunt),
        Skill(id: "cocoa-patterns", markdown: skillCocoaPatterns),
        Skill(id: "cocoa-thread-safety", markdown: skillCocoaThreadSafety),
        Skill(id: "dry-run", markdown: skillDryRun),
        Skill(id: "error-handling-review", markdown: skillErrorHandlingReview),
        Skill(id: "interface-first-design", markdown: skillInterfaceFirstDesign),
        Skill(id: "issue-analysis", markdown: skillIssueAnalysis),
        Skill(id: "issue-artifacts", markdown: skillIssueArtifacts),
        Skill(id: "issue-implementation", markdown: skillIssueImplementation),
        Skill(id: "issue-manager", markdown: skillIssueManager),
        Skill(id: "issue-orchestration", markdown: skillIssueOrchestration),
        Skill(id: "macos-zero-trace", markdown: skillMacosZeroTrace),
        Skill(id: "release-pipeline", markdown: skillReleasePipeline),
        Skill(id: "root-cause-loop", markdown: skillRootCauseLoop),
        Skill(id: "sdk-build-sync", markdown: skillSdkBuildSync),
        Skill(id: "sdk-development-process", markdown: skillSdkDevelopmentProcess),
        Skill(id: "sdk-dylib-deploy", markdown: skillSdkDylibDeploy),
        Skill(id: "sdk-library-conventions", markdown: skillSdkLibraryConventions),
        Skill(id: "solid-objc-design", markdown: skillSolidObjcDesign),
        Skill(id: "xcode-build-verify", markdown: skillXcodeBuildVerify),
    ]

    /// docs/sample/agents/*.md (6), installed as `<project>/.claude/agents/{id}.md`.
    public static let subagents: [Subagent] = [
        Subagent(id: "common-handoff", markdown: agentCommonHandoff),
        Subagent(id: "design-critic", markdown: agentDesignCritic),
        Subagent(id: "impact-analyzer", markdown: agentImpactAnalyzer),
        Subagent(id: "issue-analyzer", markdown: agentIssueAnalyzer),
        Subagent(id: "log-prober", markdown: agentLogProber),
        Subagent(id: "module-implementer", markdown: agentModuleImplementer),
    ]
}

// Every literal below uses the extended `#"""..."""#` delimiter (not plain `"""`): several
// source files contain backslashes (regex patterns, shell line-continuations) that a plain
// triple-quoted literal would misparse as Swift escapes/interpolation. Extended delimiters
// disable all escape processing, so content is copied byte-for-byte. Each literal carries a
// trailing blank line before its closing delimiter to preserve the source file's own trailing
// newline (verified: all 27 source files end with one).

// MARK: - CLAUDE.md

// source: docs/sample/CLAUDE.md
private let claudeMdRaw = #"""
# CLAUDE.md — 오케스트레이션 모드

이 프로젝트에서 세션이 시작하자마자 항상 적용되는 최우선 규칙입니다. 스킬이 켜지기 전부터 유효합니다.

## 기본 규칙

- 모든 응답은 한국어로 한다.
- 파괴적 작업(force-push, 대량 삭제, DB 초기화, 강제 브랜치 삭제 등)은 항상 사용자에게 명시적으로 확인받은 후에만 진행한다.
- 요청받은 것만 고친다. 요청하지 않은 리팩토링·스타일 통일·범위 확장을 하지 않는다.

## 경로 해석 규칙

- 상대 경로는 항상 현재 프로젝트 폴더(CWD) 기준으로 해석한다.
- 프로젝트 폴더 바깥(상위 디렉토리, 홈 디렉토리, 다른 프로젝트 등)으로 검색 범위를 확장하지 않는다.
- 파일을 찾지 못하면 임의로 상위 경로를 추측해서 뒤지지 말고, "CWD 내에서 찾을 수 없습니다"라고 보고한 뒤 사용자 지시를 기다린다.
- **예외**: 사용자가 프로젝트 밖의 특정 경로를 직접 지정한 경우(예: "저 프로젝트 참고해서 패턴 맞춰줘"), 그 경로는 읽어도 된다.

## 이슈 오케스트레이션 (항상)

1. 순서: 최소 이슈 분석 → 설계 협업 → 사용자 최종 설계 승인 → 전체 영향도 분석 → 사용자 구현 승인 → 구현 → 확인 → 완료. 설계 승인 전 영향도 분석·구현 승인 전 구현 금지.
2. 이 절차를 임의로 축약하지 않는다. 경미해 보여도 스스로 생략하지 말고, 무엇을 줄일지·왜 경미한지 사람에게 먼저 묻고 동의 후에만 간단 경로로 진행한다.
3. 설계 중 미결·선택·불확실이 있으면 문서에 묻어두지 말고, 번호 매긴 질문 + 항목별 권장안을 대화로 즉시 제시하고 답을 기다린다. 확정 문서에는 결정된 내용만 남긴다.
4. 스킬: `issue-orchestration`(전체 진행 총괄) · `issue-analysis`(이슈·영향도 분석) · `issue-artifacts`(산출물) · `issue-implementation`(구현). 해당 단계에 들어가면 그 스킬을 따른다.
5. 서브에이전트: 이슈 분석→`issue-analyzer` · 영향도 분석→`impact-analyzer` · 구현→`module-implementer` · 공통 이관→`common-handoff` · 설계 점검→`design-critic` · 원인불명 진단→`log-prober`.
6. 산출물: `docs/issues/{이슈번호}/` — STATUS, DESIGN, IMPACT, REPORT(완료 시), NOTES(선택), review/(선택), handoff/(선택).
7. 커밋: `{유형}(#{이슈}): {제목}`. AI 출처 문구 금지.

## 스킬·서브에이전트 사용 가이드

**서브에이전트 (6개) — `.claude/agents/`**

| 이름 | 설명 | 호출 조건 |
|---|---|---|
| `issue-analyzer` | 요구·오류·후보 위치의 1차 조사 | 요구가 모호하거나 후보 모듈이 둘 이상일 때 |
| `impact-analyzer` | 확정 설계의 전체/증분 영향도 분석 | 사용자 최종 설계 승인 뒤; delta는 이전 IMPACT 검증 범위 증거가 있을 때만 |
| `module-implementer` | 승인된 설계의 구현 | 독립 파일 소유권을 분리해 병렬 구현할 수 있을 때 |
| `common-handoff` | 공통/범위 밖 수정 이관 요청 | 정합 위치가 현재 프로젝트 범위 밖일 때 |
| `design-critic` | 설계·영향도 재검토 | API·동시성·권한·저장·프로토콜 위험이 있을 때 |
| `log-prober` | 원인 불명 오류의 임시 로그 | 원인 불명 진단일 때 |

**스킬 (20개) — `.claude/skills/`**

이슈 처리 흐름 (8개)

| 이름 | 설명 |
|---|---|
| `issue-orchestration` | 이슈 흐름·휴먼 게이트·조건부 스킬/서브 호출 총괄 |
| `issue-analysis` | 설계 전 최소 조사와 `.dab-index` 후보 지도 확인 |
| `issue-artifacts` | STATUS·DESIGN·IMPACT·REPORT 산출물 형식 |
| `issue-implementation` | 승인 설계 구현 규칙 |
| `issue-manager` | 팀 이슈·배포 현황 보고 |
| `root-cause-loop` | 원인 불명 오류 진단 반복 |
| `dry-run` | 정식 이슈 밖 미리보기·시연 |
| `release-pipeline` | 비 SDK 프로젝트 배포 절차 |

SDK/라이브러리 개발 (2개)

| 이름 | 설명 |
|---|---|
| `sdk-library-conventions` | SDK 코드 규칙 |
| `sdk-development-process` | SDK 개발 절차 |

품질 점검 (10개, 상황 발생 시 자동 활성화 — 별도 호출 불필요)

| 이름 | 설명 |
|---|---|
| `solid-objc-design` | SOLID 설계 점검 |
| `cocoa-patterns` | Cocoa 위험 패턴 점검 |
| `cocoa-thread-safety` | 동시성 안전 점검 |
| `arc-retain-cycle-hunt` | 순환 참조 점검 |
| `interface-first-design` | 인터페이스 우선 설계 |
| `error-handling-review` | 오류 처리 점검 |
| `macos-zero-trace` | 민감 정보 누출 점검 |
| `xcode-build-verify` | Xcode 빌드 점검 |
| `sdk-dylib-deploy` | SDK 배포 절차 |
| `sdk-build-sync` | SDK 소비처 반영 절차 |

**단계별 매핑**

| 단계 | 스킬 | 서브에이전트 |
|---|---|---|
| 설계 전 조사 | `issue-analysis` | 조건부 `issue-analyzer` |
| 사용자 최종 설계 승인 후 영향도 | `issue-analysis` | `impact-analyzer` |
| 산출물 작성 | `issue-artifacts` | — |
| 구현 | `issue-implementation` | 조건부 `module-implementer` |
| 공통 모듈 이관 | — | `common-handoff` |
| 고위험 설계 점검 | — | 조건부 `design-critic` |
| 원인불명 진단 | `root-cause-loop` | `log-prober` |
| 정식 이슈 밖 시연/검토 | `dry-run` | — |

**선택 원칙**
- `.dab-index`는 후보 파일·심볼 지도다. 먼저 이 지도로 후보만 고르고, 캐시는 증거가 아니므로 변경 심볼·API·경계 통과는 직접 LSP 또는 grep으로 확인한다.
- 영향도 전체 분석은 사용자 최종 설계 승인 뒤 한 번 수행한다. 이후 설계 변경은 이전 IMPACT의 검증 범위 증거가 있을 때만 delta 분석하고, 그렇지 않으면 전체 분석으로 돌아간다.
- 서브에이전트는 위 호출 조건을 충족할 때만 사용한다. 범위를 벗어나면 `common-handoff`로 이관한다.

"""#

// MARK: - Agents (docs/sample/agents/*.md)

// source: docs/sample/agents/common-handoff.md
private let agentCommonHandoff = #"""
---
name: common-handoff
description: "공통/범위 밖 수정 개발 요청서 작성. 대상 소스 수정 금지."
---

# 공통모듈 이관 요청 서브에이전트

## 권한
대상 소스 읽기만 허용. 소스 수정·커밋 금지. handoff 경로에 요청서만 작성한다.
경로: `docs/issues/{이슈}/handoff/{모듈id}.md`

## 임무
1. 이 수정이 정합상 이 모듈(또는 프로젝트 범위 밖 모듈) 소속인지 소스 근거로 판별한다.
2. 수정 개발 요청서를 작성한다: 무엇을 왜 바꿔야 하는지, 제안 인터페이스, 영향 범위.
3. 보고 마지막에 정확히 한 줄 `COMMON_MODULE_HANDOFF: {모듈id}`를 남긴다.
4. 직접 구현하지 않는다. 우회로 해결하는 선택지를 제시하지 않는다 — 정합상 올바른 위치가 범위 밖이면 이관이 유일한 경로다.

## 요청서 섹션
## 대상 모듈
## 무엇을 왜
## 제안 인터페이스
## 영향 범위
## 참고 파일

"""#

// source: docs/sample/agents/design-critic.md
private let agentDesignCritic = #"""
---
name: design-critic
description: "DESIGN·영향도 분석 검토. 구멍·모순·테스트 누락. 읽기 전용."
---

# 설계 검토 서브에이전트

## 권한
읽기 전용. 재작성·구현 금지. 1차 설계를 다시 쓰는 것은 메인(오케스트레이션) 몫이다.

## 임무
DESIGN.md와 영향도 분석(IMPACT.md) 결과를 대조해 다음을 점검한다: 실현 가능성, 계약 모순, 수정 대상 리스트 불일치, 테스트 누락, 설계서에 미결 사항이 남아있는지.

## 반환
## 치명
## 권장
## 테스트 빠짐
## 총평: 사람 승인 올려도 됨 | 수정 후 재검토

"""#

// source: docs/sample/agents/impact-analyzer.md
private let agentImpactAnalyzer = #"""
---
name: impact-analyzer
description: "설계 기준 영향도 분석·수정 리스트. 읽기 전용. 빌드 금지."
---

# 영향도 분석 서브에이전트

## 권한
읽기 전용. 기능 코드 수정·커밋·빌드 금지. 정적 분석만 수행한다.

## 진입과 참고문서 캐시
사용자 최종 설계 승인 뒤 첫 영향도 분석은 항상 전체 분석이다. 분석 시작 전 `.dab-index/PROJECT_INDEX.md` + `.dab-index/fingerprint`를 확인하고 후보 파일·심볼 지도로 먼저 사용한다. 지문(정렬된 소스 파일 경로 목록의 해시)을 재계산해 저장값과 비교한다: 일치하면 그 지도로 후보만 고르고 지도에 없는 파일을 넓게 읽지 않는다. 캐시는 증거가 아니므로 변경 심볼·공개 API·모듈 경계 통과는 직접 LSP 또는 grep으로 확인한다. 없거나 불일치하면 LSP(documentSymbol/workspaceSymbol, 미지원 언어는 grep+디렉터리 트리)로 지도를 재생성해 두 파일을 갱신하고(`.dab-index/`는 `.gitignore`에 반영), 전체 분석으로 진행한다.

## 임무
최종 설계를 기준으로:
1. 정합성·구조 측면 영향도 분석
2. 수정 모듈 리스트 작성(목표 버전 산출은 하지 않는다)
3. 코드 영향도 분석(기존 코드 수정인 경우만 — 신규 모듈은 생략 가능, 생략 근거는 남긴다)
4. 신규/변경 API가 있으면 계약(시그니처·타입·스레드 규약) 작성
5. 문제를 발견하면 "문제 보고" 섹션에 명시한다. 빌드·컴파일 검증은 하지 않는다(정적 분석 전용).
6. 정합 위치가 공통 모듈/프로젝트 범위 밖이면 이관 후보로 표시한다(우회 방법을 제안하지 않는다).
7. 회귀·테스트 포인트를 정리한다.

API가 소스에 없어도 계약(설계 문서)에 있으면 구현 예정으로 정상 처리하고, 계약에도 없으면 진짜 오류로 보고한다.

## Delta 재분석
이전 IMPACT의 검증 범위에 baseline revision, 범위 내 모듈, 포괄 경계, 검증된 양방향 closure·tests와 읽은 파일·심볼, 캐시 결과, 직접 조회 증거가 모두 남아 있고 새 설계 delta가 그 범위 안일 때만 delta 분석을 한다. changed symbol마다 incomingCalls·outgoingCalls·references를 양방향으로 따라가며, 확인한 경계에서만 중단 사유를 남긴다. 공통/범위 밖 경계를 만나면 `common-handoff` 후보로 남긴다.

다음 중 하나면 delta를 중단하고 전체 분석으로 되돌린다: 공개 API, 모듈 경계, 프로토콜·직렬화, 동시성, 권한, 영속성, 설정, 빌드 계약 변경; 캐시 불일치; 해결되지 않은 동적 호출·심볼; 검증 범위 누락 또는 이전 revision 증거 부족.

## 반환 (= IMPACT.md 초안)
## Revision / Baseline revision
## 분석 모드: full | delta
## 설계 delta / changed symbols
## 검증 범위: baseline revision / 범위 내 모듈 / 포괄 경계 / 검증된 양방향 closure·tests
## 캐시 결과
## 읽은 파일·심볼 / 직접 LSP 조회 수 / grep 조회 수
## 확장·중단·전체 분석 폴백 사유
## 수정 대상
## 연쇄 영향
## API·동작 변화
## 회귀·테스트 포인트
## 문제 보고
## 설계 수정 권고
## 이관 후보

"""#

// source: docs/sample/agents/issue-analyzer.md
private let agentIssueAnalyzer = #"""
---
name: issue-analyzer
description: "이슈 요구/오류 분석. 관련 코드 위치·범위·경미/복잡 보고. 읽기 전용."
---

# 이슈 분석 서브에이전트

## 권한
소스·이슈 본문 읽기 전용. 기능 코드 수정·커밋 금지.

## 임무
- 요구/오류를 한 줄로 정의하고, 관련 코드 위치·후보 모듈을 찾는다.
- 작업 범위(할 것/안 할 것)를 가른다.
- 경미한 수정인지 정식 설계가 필요한지 판단 재료를 제공한다.
- 오류 이슈면 1차 원인 가설을 세운다(근거 없으면 "불명"이라고 명시).
- 정합상 올바른 위치가 프로젝트 범위 밖(공통 모듈 등)으로 보이면 그 힌트를 남긴다.

## 반환
## 문제/요구 한 줄
## 관련 코드 위치
## 범위 in / out
## 경미 vs 정식 설계 (근거)
## 설계·다음 단계 힌트
## 막힌 점 / 사람 확인 필요

"""#

// source: docs/sample/agents/log-prober.md
private let agentLogProber = #"""
---
name: log-prober
description: "원인 불명 오류 진단 시 임시 로그 삽입/제거 전담. 로직 수정 금지."
---

# 진단 로그 서브에이전트

## 권한
지정된 위치에 `[DEBUG-FIX]` 태그 로그만 삽입하거나, 기존 진단 로그를 일괄 제거한다. 실제 로직(비즈니스 코드)은 절대 수정하지 않는다.

## 임무
- **삽입**: 의심 지점에 함수명/실행 위치, 관련 변수의 상태 값, 실행 흐름(진입/분기/종료)을 확인할 수 있는 로그를 심는다. 프로젝트에 기존 로깅 패턴이 있으면 그 방식을 그대로 따르고, 없으면 언어 기본 로깅(예: `NSLog`, `console.log`, `print`)을 쓴다.
- **제거**: 원인 확정 후 지시를 받으면 `[DEBUG-FIX]` 태그가 붙은 로그를 전부 찾아 제거한다.
- 어느 경우든 삽입/제거는 **git commit에서 제외**한다(작업 트리에만 존재). 커밋 이력은 항상 깨끗하게 유지한다.
- 로직 자체를 고치지 않았음을 보고에 명시한다.

## 반환
## 작업: 삽입 | 제거
## 대상 파일 목록
## 삽입한 로그 내용(삽입 시) / 제거 확인(제거 시)
## 로직 미변경 확인

"""#

// source: docs/sample/agents/module-implementer.md
private let agentModuleImplementer = #"""
---
name: module-implementer
description: "승인 설계·영향 범위 내 구현. 범위 밖 수정·명세 외 기능 추가 금지."
---

# 모듈 구현 서브에이전트

## 권한
메인이 지정한 경로만 쓴다. 읽기는 IMPACT의 "수정 대상"·"읽은 파일·심볼" 범위에서 시작한다 — 코드베이스를 처음부터 다시 탐색하지 말고, 그 밖을 봐야 하면 넓게 뒤지기 전에 범위를 재확인한다.

## 순서
1. 설계 검토: 확정 DESIGN을 읽고 자기 담당 범위 소스와 대조해 실현 가능성·정합성을 확인한다.
2. 영향 리스트 대조: IMPACT.md와 대조해 어긋나는 점이 없는지 확인한다.
3. 문제 처리: 어긋나거나 구현이 불가능한 점을 발견하면 구현을 강행하지 말고 즉시 판단한다.
   - **경미**(사소한 불일치, 스스로 바로잡을 수 있는 수준)면 그대로 바로잡고 보고서에 무엇을 왜 바꿨는지 남긴 뒤 계속 진행한다.
   - **중대**(설계 자체를 다시 봐야 하는 수준)면 강행하지 말고 즉시 멈추고 사람 보고로 반환한다.
4. 승인된 설계대로 구현한다. 설계 명세 외 기능을 추가하지 않는다.

## 문서
공개 API·사용법이 바뀌면 README/INTEGRATION_GUIDE 등을 같은 작업에서 함께 갱신한다. 보고서에 문서 갱신 섹션을 반드시 남기거나 "해당 없음: {사유}"를 명시한다. 누락하면 완료로 보고하지 않는다.

## 반환
## 결과: 성공 | 막힘
## 변경 파일
## 한 일
## 커밋
## 문서 갱신
## 확인 방법
## 막힘 사유

"""#

// MARK: - Skills (docs/sample/skills/*/SKILL.md)

// source: docs/sample/skills/arc-retain-cycle-hunt/SKILL.md
private let skillArcRetainCycleHunt = #"""
---
name: arc-retain-cycle-hunt
description: "Activate when reviewing or writing Objective-C code in these situations: self capture inside Blocks (the `__weak`/`__strong` dance), ownership of delegate/dataSource properties (must be weak), balancing CoreFoundation objects (`CFCreate*`/`CGCreate*` paired with `CFRelease`/`CGRelease`), and NSTimer/KVO/NSNotificationCenter observer lifecycle (add/remove paired in dealloc)."
---

# ARC Retain-Cycle Hunt

## Procedure

### Phase 1: Block capture analysis
Search patterns:
```
\^{[^}]*\bself\b[^}]*}
\^([^)]*){[^}]*\bself\b
__weak typeof\(self\)
```
- [ ] `self.someBlock = ^{ [self method]; }` → requires `__weak typeof(self)`
- [ ] `dispatch_async(q, ^{ self.x = y; })` → `__weak` recommended
- [ ] If multiple methods are called inside the block, verify `__strong` recapture
- [ ] Animation/UIView completion blocks that reference `self` → `__weak`

### Phase 2: Delegate/DataSource ownership
Search patterns:
```
@property\s*\(.*strong.*\)\s*id<.*Delegate>
@property\s*\(.*retain.*\)\s*id<.*Delegate>
```
- [ ] Every `delegate` property → declared `weak`
- [ ] Every `dataSource` property → declared `weak`
- [ ] Never use `strong`/`retain` on delegate properties

### Phase 3: CoreFoundation balancing
Search patterns:
```
CFCreate|CTFont|CGImage|CGContext|CGColor|CGPath
CFRelease|CGImageRelease|CGContextRelease|CGColorRelease|CGPathRelease
```
- [ ] `CFStringCreate*` → `CFRelease()`
- [ ] `CGImageCreate*` → `CGImageRelease()`
- [ ] `CGContextCreate*` → `CGContextRelease()`
- [ ] `CGColorCreate*` → `CGColorRelease()`
- [ ] `CTFontCreate*` → `CFRelease()`
- [ ] `CGPathCreate*` → `CGPathRelease()`
- [ ] Every CF/CG creation must have a matching release on every code path

### Phase 4: Observer & timer cleanup
Search patterns:
```
\[NSTimer scheduledTimer
addObserver:selector:
addObserverForName:
```
- [ ] `NSTimer` → `invalidate` in `dealloc` or `viewDidDisappear`
- [ ] `NSNotificationCenter addObserver` → `removeObserver` in `dealloc`
- [ ] KVO `addObserver` → `removeObserver` in `dealloc`

## Checklist Summary
| Check | What to verify |
|-------|----------------|
| Block self capture | `__weak`/`__strong` dance applied |
| Delegate ownership | `weak` attribute on the property |
| CF object balancing | Create paired with Release |
| Timer/Observer | Cleaned up in dealloc/lifecycle |

## Output Format
| Issue type | Severity |
|------------|----------|
| Retain cycle (self captured by Block) | Critical |
| CF/CG object leak | High |
| NSTimer not invalidated | High |
| Observer not removed | Medium |

"""#

// source: docs/sample/skills/cocoa-patterns/SKILL.md
private let skillCocoaPatterns = #"""
---
name: cocoa-patterns
description: "Activate when using NSNotificationCenter, KVO, or NSError in Objective-C. Covers only the error-prone spots: pairing observer add/remove, KVO context pointers, and checking NSError return values."
---

# Cocoa Runtime Patterns

> If the project has an established approach, **follow it first**. The items below are checkpoints for commonly error-prone spots.

## NSNotificationCenter

- If you called `addObserver:`, pair it with `removeObserver:` at the end of the lifecycle (e.g., `dealloc`).
- Block-based `addObserverForName:...usingBlock:` returns an observer token — you must store it and remove it later. Otherwise you get zombie observers.
- Use typed constants for notification names (`extern NSNotificationName const ...`). Do not hardcode strings.

## KVO

- Use a file-scope static pointer for `context`:
  ```objc
  static void *FooContext = &FooContext;
  ```
  Calling `removeObserver:forKeyPath:` without `context` can remove a superclass's observation too and crash.
- If the observed target is deallocated before the observer, you get a dangling pointer. Guarantee the removal order.

## NSError

- For methods with an `NSError **` out-param, **check the return value first, then the error**:
  ```objc
  NSError *err = nil;
  if (![obj doSomething:&err]) { /* handle failure */ }
  ```
- Do not assume `*error` is set on the success path (Apple convention).
- Define error domains and codes as constants/enums.

## Type Safety

- Lightweight generics: `NSArray<NSString *> *`, `NSDictionary<NSString *, Foo *> *`.
- Public API should use `NS_ASSUME_NONNULL_BEGIN/END` + explicit `nullable`.

## Output Format

| Issue | Severity |
|-------|----------|
| Zombie callback from missing observer removal | Critical |
| KVO `removeObserver` without context | Critical |
| `NSError **` out-param ignored | High |
| Hardcoded notification name string | Medium |

"""#

// source: docs/sample/skills/cocoa-thread-safety/SKILL.md
private let skillCocoaThreadSafety = #"""
---
name: cocoa-thread-safety
description: "Activate when Objective-C code uses GCD dispatch, shared mutable state (NSMutableArray/Dictionary, singletons) is accessed from multiple threads, UI updates occur next to background queues, or `@synchronized`/locks are added. Audits main-thread UI, shared-state protection, deadlocks, and atomic-property use."
---

# Cocoa Thread-Safety Verification

## Procedure

### Phase 1: Main-thread UI audit
Search patterns:
```
dispatch_async.*global.*\{[^}]*\.(text|hidden|frame|bounds|alpha|backgroundColor)
\[.*label.*setText
\[.*tableView.*reload
\[.*view.*setNeedsDisplay
```
- [ ] All `NSTextField`/`NSLabel` updates → main thread
- [ ] All `reloadData` calls → main thread
- [ ] All `setNeedsDisplay`/`setNeedsLayout` → main thread
- [ ] All `NSWindow` manipulation → main thread
- [ ] When reflecting background work on the UI, dispatch to `dispatch_get_main_queue()`

### Phase 2: Shared-state protection
Search patterns:
```
@property.*NSMutableArray
@property.*NSMutableDictionary
_sharedInstance
```
Verify one of the following protections is in place:
- [ ] `@synchronized(obj)` wrapping access
- [ ] GCD serial queue for all mutations
- [ ] `dispatch_barrier_async` on a concurrent queue for read/write
- [ ] No unprotected mutation of shared mutable collections

### Phase 3: Deadlock detection
Search patterns:
```
dispatch_sync.*main
@synchronized
```
- [ ] No `dispatch_sync(main_queue)` called from the main thread
- [ ] Nested `@synchronized` → consistent lock order on every path
- [ ] `dispatch_sync` does not target the queue it is currently running on

### Phase 4: atomic property appropriateness
Search patterns:
```
@property\s*\(nonatomic
@property\s*\(atomic
```
- [ ] Use `nonatomic` for single-thread-access properties
- [ ] Use `atomic` only where multi-thread access is actually required
- [ ] Note: `atomic` does **not** protect mutations inside collections

## Output Format
| Issue type | Severity |
|------------|----------|
| UI update off the main thread | Critical |
| Deadlock (`dispatch_sync` onto the current queue) | Critical |
| Unprotected shared mutable state | High |
| Inconsistent nested lock order | High |
| `atomic` misused on collections | Medium |

"""#

// source: docs/sample/skills/dry-run/SKILL.md
private let skillDryRun = #"""
---
name: dry-run
description: >-
  정식 이슈로 등록하지 않고 사전 검토(읽기 전용)나 시연(구현 후 원복)을 할 때 사용한다.
  "미리 봐줘", "일단 만들어보고 나중에 지울 거야", "테스트로 해보고 싶어" 같은 요청에 활성화.
---

# 사전 검토 · 시연 모드

## 진입 — 모드가 애매하면 되묻는다
요청이 "정식으로 진행할 것"인지 "미리보기/시연"인지 불명확하면 스스로 판단하지 말고 사람에게 확인한다: "정식 이슈로 진행할까요, 아니면 미리보기/시연(dry-run)으로 할까요?"

## 모드 1 — 미리보기 (읽기 전용, 무흔적)
개발 착수 전에 "이 기능이 어디에 개발될지·정합 위치는 어디인지"를 미리 파악하는 순수 분석 경로.
- `issue-analyzer`에게 읽기 전용 분석을 요청한다.
- 결과(대상 모듈 후보, 정합상 올바른 위치, 구조·영향도 요약, 권장 진행 경로)를 대화로만 전달한다.
- 이슈·워크스페이스·상태 파일·설계 문서를 생성하지 않는다. git과 무관하며 롤백이 필요 없다.

## 모드 2 — 시연 (구현 후 원복)
실제로 코드를 잠깐 만들어 동작을 확인하되 흔적을 남기지 않는 모드.
1. 대상 저장소의 현재 상태를 기록해둔다(baseline).
2. `module-implementer`에게 구현을 지시하되 **커밋 지시는 주지 않는다**.
3. 로컬 빌드·동작 확인까지만 진행한다.
4. 결과를 사람에게 시연한다.
5. 종료 시 baseline으로 원복(롤백)하고 흔적을 정리한다.

## 불변식
이 스킬로 만든 산출물은 git 이력화(개발 완료·release 커밋) 대상이 아니다. 종료 시 롤백으로 흔적을 남기지 않는다.

"""#

// source: docs/sample/skills/error-handling-review/SKILL.md
private let skillErrorHandlingReview = #"""
---
name: error-handling-review
description: "Activate when reviewing error-handling completeness on any platform — Swift, Objective-C, Dart, etc. Covers unhandled external calls, crash-prone force unwrap/cast operations, silently swallowed errors, and missing user-facing recovery."
---

# Error-Handling Review

## Procedure

### Step 1: Scan for unhandled external calls
Search every external interaction that can fail:
- Network requests (URLSession, http, dio)
- File I/O (read/write/delete operations)
- DB operations (CoreData, SQLite, Hive)
- System APIs that return optionals or throw
- JSON/data parsing (JSONDecoder, jsonDecode)

For each, verify there is a `catch`, `guard`, nil-check, or error callback.

### Step 2: Scan for force operations
Search for force operations that can trigger runtime crashes:

**Swift/ObjC**:
- `try!` — replace with `do/catch` or `try?`
- `as!` — replace with `as?` + guard
- `!` (force unwrap) — replace with `guard let` / `if let`
- `array[index]` without a bounds check

**Dart/Flutter**:
- `!` (bang operator) — replace with null check or `??`
- `as` cast without an `is` check
- `List[index]` without a bounds check
- `.first` / `.last` on potentially empty collections

### Step 3: Trace error propagation
For each error-handling site found in Step 1:
- Does the error propagate to a meaningful handler? (not silently swallowed)
- Is the error logged or reported appropriately?
- Does the user see a helpful message? (not a raw exception)
- Is there recovery logic where appropriate? (retry, fallback, graceful degradation)

### Step 4: Report findings

## Checklist
- [ ] Every external call has error handling
- [ ] No force unwrap/try/cast without a safety guarantee
- [ ] Errors propagate to meaningful handlers (not silently swallowed)
- [ ] User-visible error messages are appropriate
- [ ] Recovery logic exists where applicable (retry, fallback)

## Output Format

```markdown
## Error-Handling Review

### Unhandled External Calls
| Call | Location | Issue | Suggested fix |
|------|----------|-------|---------------|
| [API call] | file:line | No error handling | Add do/catch |

### Force Operations
| Operation | Location | Risk | Suggested fix |
|-----------|----------|------|---------------|
| [force unwrap] | file:line | Runtime crash | Use guard let |

### Propagation Issues
| Error source | Location | Issue |
|--------------|----------|-------|
| [source] | file:line | Error silently swallowed |

### Summary
- Unhandled calls: [count]
- Force operations: [count]
- Propagation issues: [count]
- Overall risk: [Low/Medium/High]
```

"""#

// source: docs/sample/skills/interface-first-design/SKILL.md
private let skillInterfaceFirstDesign = #"""
---
name: interface-first-design
description: "Activate when designing a new component or feature on macOS (Objective-C/Cocoa). Define the public `.h` contract and delegate `@protocol` and pick a communication pattern from existing conventions before writing the `.m` implementation."
---

# Interface-First Design — macOS

> **Core principle: define the contract before the implementation.**
> Write the `.h` interface first; `.m` comes after.

## Procedure

### Step 1 — Define the public interface (`.h` first)

```objc
@protocol [ComponentName]Delegate <NSObject>
@optional
- (void)[component]:([ComponentName] *)component didComplete:(id)result;
- (void)[component]:([ComponentName] *)component didFailWithError:(NSError *)error;
@end

@interface [ComponentName] : NSObject
@property (nonatomic, weak) id<[ComponentName]Delegate> delegate;
@property (nonatomic, readonly) [StateType] currentState;
- (instancetype)initWith[Dependency]:([DependencyType] *)dependency;
- (void)start[Action];
- (void)stop[Action];
@end
```

### Step 2 — Pick a communication pattern

Search existing codebase patterns before choosing. Stay consistent with surrounding modules.

| Pattern | When to use |
|---------|-------------|
| **Delegate** | 1:1 callback, one-way dependency |
| **NSNotificationCenter** | 1:N broadcast, loose coupling |
| **Block/Closure** | Async completion handler |
| **KVO** | Observe property changes |

### Step 3 — Verify layer separation

```
View (UI layer) <-> Controller/Manager (business logic) <-> Model (data layer)
```

- View accessing Model directly → forbidden
- Controller depending on View's implementation details → forbidden

### Step 4 — Dependency review

- [ ] New Singleton? Only if consistent with the project's established pattern. Prefer DI.
- [ ] DI (Dependency Injection) applicable? Prefer DI over Singleton.
- [ ] Facade pattern applicable? Use when hiding a complex subsystem.

## Checklist

- [ ] Draft `.h` interface with every public method and property
- [ ] Define `@protocol` containing delegate methods
- [ ] Communication pattern chosen and consistent with the codebase
- [ ] Layer separation verified (View does not access Model directly)
- [ ] Dependencies are injectable; no unnecessary singletons
- [ ] Module is unit-testable in isolation

## Output Format

```
Component: [ComponentName]
Interface: [path to .h file]
Protocol: [protocol name and methods]
Communication: [chosen pattern + rationale]
Layer: [View <-> Controller <-> Model mapping]
Dependencies: [init injection / singleton / facade]
```

"""#

// source: docs/sample/skills/issue-analysis/SKILL.md
private let skillIssueAnalysis = #"""
---
name: issue-analysis
description: >-
  설계 전 요구·오류의 최소 조사와 후보 파일·심볼 지도를 만든다.
  전체 영향도 분석은 사용자 최종 설계 승인 뒤 impact-analyzer가 수행한다. Use for pre-design issue analysis.
---

# 이슈 사전 조사

## 공통
- 분석 목적의 소스 읽기는 허용한다. 이 스킬 구간에서는 기능 코드 수정·커밋을 하지 않는다.
- 프로젝트에 설계 원칙 파일(SOLID 등)이 있으면 로드해 준수한다.

## 참고문서 캐시 우선
착수 전 `.dab-index/PROJECT_INDEX.md` + `.dab-index/fingerprint`를 확인한다. 일치하는 캐시는 후보 파일·공개 심볼 지도일 뿐 증거가 아니다. 먼저 지도에서 이번 요구와 닿는 후보만 고르고 그 파일만 읽는다. 캐시가 없거나 불일치하면 구조 지도만 재생성하고, 직접 LSP/grep은 변경 심볼·API·경계 통과를 확인해야 하는 `impact-analyzer` 단계까지 넓히지 않는다.

## 1. 최소 조사
- 요구/오류 현상을 정리하고 경미 vs 복잡을 판단한다.
- 오류 이슈면 원인 판단을 우선할 수 있다(진단 트랙 — `root-cause-loop` 참고).
- 요구가 모호하거나 후보 모듈이 둘 이상일 때만 서브에이전트 `issue-analyzer`에 위임한다.
- 후보 파일·심볼, 캐시 hit/miss 사유, 실제 읽은 파일만 기록한다. 이 단계에서 수정 모듈 목록·연쇄 영향·API 계약을 확정하지 않는다.

## 2. 이후
후보와 열린 결정을 바탕으로 설계 협업을 한다. 사용자가 최종 설계를 승인한 뒤에만 `impact-analyzer`에 전체 영향도 분석을 위임한다. 분석 결과가 없거나 사용자 구현 승인이 없거나 설계가 바뀌면 구현하지 않는다.

"""#

// source: docs/sample/skills/issue-artifacts/SKILL.md
private let skillIssueArtifacts = #"""
---
name: issue-artifacts
description: >-
  docs/issues 아래 STATUS·DESIGN·IMPACT·REPORT 등 산출물 경로와 섹션을 작성한다.
  Use when writing issue work documents.
---

# 이슈 산출물 작성

## 경로
`docs/issues/{이슈번호}/`

## single-writer
이슈 본문 산출물은 오케스트레이션 세션이 작성한다. 사람 리뷰 파일은 사람만 작성한다(대화 채널에서 리뷰하면 파일 생략 가능).

## STATUS.md
필드: issue, phase, gate, status, updated_at, note.

## DESIGN.md
- 목적/범위 · 모듈 구조 · API 계약 · (또는 IMPACT로 분리한) 코드 영향도.
- 결정된 내용만 담는다 — 미결 섹션 금지. 열린 결정이 있으면 확정본을 쓰지 말고 대화로 먼저 확인한다.

## IMPACT.md
수정 대상 · 연쇄 영향 · API 변화 · 테스트 포인트 · 문제 보고 · 이관 후보.

## REPORT.md
1. 이슈 요약 2. 설계·영향도 분석·API 3. 적용 모듈·commit 4. 코드 작업 5. 테스트 6. 체크리스트.
완료 단계에서 작성한다. 기존 산출물을 조립하는 비차단 사후 리뷰용 문서다.

## NOTES.md (선택) — 세션 이어가기용 메모
세션이 끊겨도 이 이슈 작업을 이어갈 수 있도록 하는 메모.
- 저장 타이밍: 단계 완료 시 / 중요 결정 확정 시 / 세션 종료 전.
- 저장 항목: 지금까지 결정한 것, 진행 상태, 다음에 할 일.
- 항상 최신 내용으로 덮어쓴다.

## review/ (선택) — 동료 리뷰
완료된 작업에 동료가 비차단으로 코멘트를 남기는 폴더. `review/{리뷰어}_{날짜}.md` 형식. release나 완료 처리와 무관하며, 승인 개념이 없다. 리뷰 0건도 정상이다.

## handoff/{대상}.md (선택)
공통모듈 등으로 이관할 때의 요청서. 무엇을·왜 · 제안 인터페이스 · 영향 범위. 경로: `docs/issues/{이슈}/handoff/{id}.md`

"""#

// source: docs/sample/skills/issue-implementation/SKILL.md
private let skillIssueImplementation = #"""
---
name: issue-implementation
description: >-
  사람 승인·영향도 분석 이후 구현·빌드·테스트·문서 갱신·커밋 규약.
  Use when implementing an approved issue design.
---

# 이슈 구현 규칙

## 진입 조건
- 확정 DESIGN + 영향도 분석 결과가 있어야 한다(신규 개발은 예외 가능).
- 사람 최종 승인 후에만 진행한다. 승인 전이나 설계 협업 중에는 구현하지 않는다. 축약은 사람 동의 후에만 한다.

## 구현 전 — 기존 패턴 검색
새 코드를 발명하기 전에 유사한 기존 패턴(같은 파일이나 관련 폴더의 비슷한 로직·구조)을 먼저 찾는다.
- 명확한 패턴이 하나면 그 구조를 그대로 따라 구현하고, 참고한 패턴을 보고서에 남긴다(파일 위치 포함).
- 패턴이 여럿이라 뭘 따라야 할지 애매하면 임의로 고르지 말고, 후보를 정리해 사람에게 확인받은 뒤 진행한다.

## 구현 중
- 프로젝트 관례·팀 코딩 규칙을 준수한다.
- 계약을 이행할 수 없으면 즉시 문제로 보고한다.

## 진단용 임시 로그
`root-cause-loop`/`log-prober`가 심은 `[DEBUG-FIX]` 태그 로그는 커밋에서 제외한다(작업 트리에만 존재).

## 공통모듈 이관
프로젝트 범위에서 공통 모듈을 직접 수정하지 않는다 → `common-handoff`로 이관 + `COMMON_MODULE_HANDOFF: {id}` 마커. 우회 선택지를 만들지 않는다.

## 범위
담당 범위 밖 수정을 하지 않는다. 모호하면 추측하지 말고 보고한다. 프로젝트 관례를 우선한다.

## 서브
구현 분업 → `module-implementer` · 이관 → `common-handoff`

"""#

// source: docs/sample/skills/issue-manager/SKILL.md
private let skillIssueManager = #"""
---
name: issue-manager
description: >-
  레드마인 이슈를 관리 상태로 매핑하고, 팀 전체 주간/월간 보고서·담당자별 진행+미진행 현황·배포 현황을
  작성한다. 프로젝트의 docs/ISSUE_MANAGEMENT_GUIDE.md 규칙을 최우선 따른다. 개인 1인의 서술형 업무
  정리("내가 한 일")는 이 스킬의 대상이 아니다. Use for team-wide Redmine status reports,
  per-assignee tracking, deployment status — not for a single person's work summary.
---

# 이슈매니저 (팀 현황·상태관리)

## 0. 가이드 우선
- CWD `docs/ISSUE_MANAGEMENT_GUIDE.md`를 최우선 참조 — 상태매핑 규칙·리포트 템플릿·파일 경로(`docs/{월}/`)는 이 가이드를 따른다.
- 가이드가 없으면: 임의로 추측해 진행하지 말고 즉시 사용자에게 보고 후 지시를 기다린다.

## 1. 상태 매핑 (가이드에 별도 정의 없을 때 기본값)
| Redmine 상태 | ID | 관리 상태 |
|---|---|---|
| 신규(New) | 1 | 개발 대기 |
| 진행(Doing) | 2 | 개발 진행 |
| 해결(Complete), State≠ST | 3 | 개발 완료 |
| 해결(Complete), State=ST | 3 | QA 시작 |
| 완료성공(End/Success) | 5 | QA 완료 |
| 피드백(Feedback) | 4 | 피드백 |
| 보류(Pause) | 7 | 보류 |
| 중단(Stop) | 8 | 중단 |
| 완료실패(End/Fail) | 6 | 완료실패 |
- 해결(3) 상태는 반드시 custom_fields의 **State** 값을 확인해 ST 여부로 QA시작/개발완료를 가른다.
- 사용자가 특정 이슈의 관리 상태를 명시적으로 지정하면 이 매핑보다 사용자 지시를 우선한다.

## 2. 조회 원칙
- 실시간 조회 우선 — 이전 데이터·캐시 재사용 금지, 추측 금지.
- 독립적인 이슈 조회는 병렬로 수행.
- 조회 실패 시 즉시 보고 후 재시도 여부를 확인.

## 3. 담당자별 이슈 추출 — A·B 합쳐서 중복 제거
- **A. 진행 이슈**: 해당 기간 `time_entries`(소요시간)가 등록된 이슈.
- **B. 미진행 이슈**: `start_date`가 해당 기간이거나, `created_on`이 해당 기간이면서 상태=신규(status_id=1)인 이슈.
- A에 이미 포함된 이슈는 B에서 제외(중복 제거).

## 4. 배포 현황 관리
- 배포 관련 이슈를 플랜 이슈 / 추가 이슈로 분류.
- 배포 버전이 있는 이슈는 버전을 표기, 없으면 빈 칸.
- 모든 표에서 동일한 컬럼명·표기 방식 유지.

## 5. 리포트 원칙
- 모든 표의 건수는 실제 나열된 이슈 수와 정확히 일치해야 한다 — 불일치 시 관련 표를 함께 수정.
- 담당자별 추출 시 진행/미진행 이슈 간 중복을 반드시 제거.
- 동일 문서 내 같은 이슈의 상태 표기는 모든 위치에서 일관되게.
- **변경 전파**: 이슈 상태가 바뀌면 그 이슈가 등장하는 모든 섹션(요약·상세·담당자별·배포)을 함께 업데이트.

## 6. 커뮤니케이션
- 응답 앞에 `[이슈매니저]` 접두사 사용.
- 사용자가 요청한 범위와 내용만 작성 — 요청하지 않은 데이터·구조 변경, 추가 분석을 독단적으로 하지 않는다.
- 건수 불일치·상태 모호성 등 의문이 있으면 임의 판단하지 말고 사용자에게 확인.
- 수정 완료 후 변경된 항목과 영향 범위를 간결히 보고.

## 7. 메모리
`ai/memory/ISSUE_MANAGER_MEMORY.md` — 활성화 시 로드해 이전 컨텍스트 복원, 없으면 아래 필드로 새로 생성.
- 필드: 현재 진행 상태 / 팀 멤버(담당자명↔Redmine ID) / 프로젝트 정보 / 핵심 의사결정(상태 매핑 오버라이드 등) / 미완료 작업.
- 저장 타이밍: 리포트 작성 완료 시 / 담당자별 이슈 추출 완료 시 / 중요 의사결정 확정 시 / 세션 종료 전.
- 저장 금지: 개별 이슈 전체 상세 데이터, 사용자 개인정보, Redmine API 응답 원본.
- 항상 덮어쓰기(추가 아님), 200줄 이내, 완료 3세션 경과 항목은 정리.

"""#

// source: docs/sample/skills/issue-orchestration/SKILL.md
private let skillIssueOrchestration = #"""
---
name: issue-orchestration
description: >-
  최소 이슈 분석→설계 협업→사용자 최종 설계 승인→전체 영향도 분석→사용자 구현 승인→구현→확인→완료로 진행한다.
  휴먼 게이트·대화 우선·스킬/서브 호출 시점을 총괄한다. Use for issue orchestration workflow.
---

# 이슈 오케스트레이션

## 역할
- 이슈(프로젝트) 단위 개발 진행을 총괄한다. 판단·설계 취합·게이트 운영을 담당한다.
- 사람과의 업무 통신(게이트 확인·보고·알림)은 이 세션을 경유한다.
- 상태는 파일·산출물에 남긴다. 승인 대기를 조용히 세션에서 버티는 방식으로 처리하지 않는다.

## 작업 모델
- 이슈 1개 = 워크스페이스 1개. 기능 개발/오류 이슈 동일 프로세스로 진행한다.
- 버전은 개발 단계에서 결정하지 않는다.

## 필수 순서
최소 이슈 분석 → 설계 협업 → 사용자 최종 설계 승인 → 전체 영향도 분석 → 사용자 구현 승인 → 구현 → 확인 → 완료.

| 단계 | 할 일 |
|---|---|
| 최소 이슈 분석 | 요구 파악, 경미/복잡 판단 |
| 설계 협업 | 초안 작성, 열린 결정은 대화로 확정 |
| 사용자 최종 설계 승인 | DESIGN에 결정된 내용만, 승인 전 영향도 분석 금지 |
| 전체 영향도 분석 | IMPACT 작성 |
| 사용자 구현 승인 | 승인 전 구현 금지 |
| 구현 | `issue-implementation` / `module-implementer` |
| 확인 | 사람 테스트 요청 |
| 완료 | REPORT 작성, 재작업 경로 처리 |

### 경미 경로
축약 가능해 보여도 스스로 생략하지 않는다. 무엇을 줄일지·왜 경미한지·간단 경로를 사람에게 묻고 동의 후에만 간단 진행한다.

## 설계 협업 · 대화 우선
- 미결을 설계서에 남기지 말고 대화로 확정한다.
- 번호 매긴 질문 + 항목별 권장안을 제시하고 사람 답변을 기다린다.
- 확정 DESIGN에는 결정된 내용만 남긴다(미결 섹션 금지).
- 파일에만 적고 조용히 멈추지 않는다.
- 규약상 결정적인 사안(예: 공통모듈 이관)은 우회 선택지를 만들지 않는다.

## 고정 휴먼 게이트
1. 이슈 착수 확인
2. 사용자 최종 설계 승인
3. 사용자 구현 승인
4. 사람 테스트

## 스킬·서브 사용
단계별 스킬·서브 매핑과 호출 조건은 CLAUDE.md의 "단계별 매핑"·서브에이전트 표를 따른다(중복 제거).

## 정합 위치 · 이관
수정 위치를 정할 때는 정합상 올바른 위치를 기준으로 판단한다. 프로젝트 범위에서 공통모듈에 속한다고 판단되면 우회 구현하지 말고 `common-handoff`로 이관한다.

## 산출물 경로
`docs/issues/{이슈번호}/` — STATUS.md, DESIGN.md, IMPACT.md, REPORT.md, NOTES.md(선택), review/(선택), handoff/(선택).

## 완료 후 재작업 3경로
1. **테스트 반려**: 사람이 결함을 발견하면 설계 협업 단계부터 재실행한다.
2. **완료 후 회수 재작업**: 이미 완료 처리된 이슈를 나중에 다시 고쳐야 하면, 완료 상태에서 회수해 설계 협업부터 재작업 후 다시 완료 처리한다.
3. **배포 후 결함**: 배포까지 끝난 뒤 문제가 생기면 기존 이슈를 재사용하지 말고 완전히 새 이슈로 시작한다.

## 범위
- 보고·산출물 없이 완료를 추측하지 않는다.
- 커밋·문서 어디에도 AI 작성 표식을 남기지 않는다.
- 응답 앞에 `[오케스트레이터]` 접두사를 사용한다.

"""#

// source: docs/sample/skills/macos-zero-trace/SKILL.md
private let skillMacosZeroTrace = #"""
---
name: macos-zero-trace
description: "Activate when handling sensitive data such as credentials, tokens, or API keys. Forbid storage outside Keychain; audit logs, pasteboard, and URLs for leakage."
---

# Sensitive Data Protection

> If the project already has an established storage/transport policy, **follow that policy first**. The items below are general checkpoints for handling sensitive data.

## Storage

- Tokens, passwords, and API keys go **in Keychain only**. Never store them in plain text in `UserDefaults`, plist, or JSON files.
- Default Keychain access level: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `kSecAttrAccessibleAlways` is forbidden.
- `kSecAttrSynchronizable = false` (block iCloud Keychain sync).

## Logs

- Do not emit sensitive data via `NSLog`/`printf`.
- Use the `%{private}` format specifier with `os_log` (auto-masked in release).
- Scrub payload fields in crash reporters and remote loggers.

## Transport

- TLS 1.2 or higher. No ATS exceptions.
- **Never place auth tokens in URL query strings** — URLs persist in logs and proxies. Use headers.

## UI

- Use `NSSecureTextField` for password input.
- When copying sensitive values to the pasteboard (`NSPasteboard`), limit lifetime or clear immediately on the next write.

## Output Format

| Issue | Severity |
|-------|----------|
| Plain-text token/password in `UserDefaults`/plist | Critical |
| Sensitive data exposed in logs | Critical |
| Keychain access level `AccessibleAlways` | Critical |
| Token included in URL query | High |
| iCloud Keychain sync not blocked | High |
| No TLS or ATS exception | High |

"""#

// source: docs/sample/skills/release-pipeline/SKILL.md
private let skillReleasePipeline = #"""
---
name: release-pipeline
description: >-
  (SDK 프로젝트가 아닌 일반 프로젝트에서) 실제 빌드→배포를 진행할 때 사용한다. SDK/라이브러리 프로젝트의
  배포는 이 스킬 대신 sdk-dylib-deploy/sdk-build-sync를 사용한다. Use for non-SDK project release/deploy.
---

# 배포 파이프라인 (비-SDK 프로젝트)

## 시작 전 — 설정 확인 (MANDATORY)
프로젝트 루트의 `docs/RELEASE_CONFIG.md`를 확인한다. 빌드 명령·배포 대상·버전 규칙 등 필수 항목이 채워져 있는지 본다.
- **완비**: 아래 절차대로 진행한다.
- **미비**: 추측해서 진행하지 말고 "배포 설정이 없어 진행할 수 없습니다"라고 보고하고 중단한다.

## 절차
1. 로컬 빌드로 현재 상태를 확인한다.
2. 게이트 선택을 사람에게 확인한다: ①개발 빌드만 ②코드사이닝+배포까지 ③생략.
3. 설정값대로 빌드·배포를 실행한다.
4. 버전을 확정하고(설정에 정의된 규칙에 따라), 배포 결과를 사람에게 보고한다.

## 원칙
- 버전은 배포 시점에 한 번만 확정한다. 개발 단계에서 임의로 정하지 않는다.
- 배포는 되돌리기 어려운 작업이다 — 실행 전 반드시 사람 확인을 받는다.

## docs/RELEASE_CONFIG.md 필수 항목
- 빌드 명령어
- 코드사이닝/공증 방법(해당 시)
- 배포 대상 경로/서버
- 버전 규칙(예: SemVer patch+1)

"""#

// source: docs/sample/skills/root-cause-loop/SKILL.md
private let skillRootCauseLoop = #"""
---
name: root-cause-loop
description: >-
  원인을 알 수 없는 오류를 진단할 때 사용한다. 의심 지점에 임시 로그를 심고, 재현 테스트를 요청하고,
  로그를 근거로 재분석하는 과정을 원인이 확정될 때까지 반복한다. Use for unclear-cause bug diagnosis.
---

# 원인불명 진단 루프

## 진입
오류 이슈를 접수하면 먼저 1차 진단으로 원인 확정 여부를 가른다.
- **원인 확정**: 이 스킬을 쓰지 않고 바로 정상 흐름(`issue-analysis`→설계→구현)에 합류한다.
- **원인 불명·간헐적**: 이 스킬로 진행한다.

## 절차
1. `issue-analyzer`에게 1차 원인 가설을 요청한다. 근거가 없으면 "불명"으로 남긴다.
2. `log-prober`에게 의심 지점에 `[DEBUG-FIX]` 태그 진단 로그 삽입을 지시한다(로직은 건드리지 않는다).
3. 사람에게 재현 테스트와 로그 수집을 요청한다.
4. 받은 로그를 근거로 `issue-analyzer`에게 재분석을 요청한다.
5. 원인이 잡힐 때까지 2~4를 반복한다(매회 사람 테스트가 자연스러운 확인 지점이 된다).
6. 원인이 확정되면 `log-prober`에게 진단 로그 제거를 지시하고, 정상 흐름(설계/구현)에 합류한다.

## 규칙
- 진단 로그의 추가/제거는 git commit에서 제외한다. 커밋 이력은 항상 깨끗하게 유지한다.
- 로그 제거 완료가 이슈 종결 조건에 포함된다.
- 대화 우선: 착수 확인·원인 보고·수정 방향은 대화에 요약+선택지+권장안으로 제시하고, 진단 결과를 파일에만 남기고 조용히 멈추지 않는다.

"""#

// source: docs/sample/skills/sdk-build-sync/SKILL.md
private let skillSdkBuildSync = #"""
---
name: sdk-build-sync
description: "SDK 하위 모듈(sdk_modules / sdk_units / sdk_logics 등)을 수정한 뒤, 해당 모듈을 재빌드해서 산출물을 현재 작업 중인 프레임워크 프로젝트 안의 동일 모듈 폴더에 동기화한다. 사용자가 모듈명을 인자로 넘기면 활성화한다. 예: `/sdk-build-sync paescreenprovider`. 경로는 절대로 하드코딩하지 말고, 현재 작업 디렉토리에서 SDK 루트를 탐색해 추론한다."
---

# SDK Build & Sync

수정된 SDK 하위 모듈을 재빌드해, 그 산출물을 현재 작업 중인 프레임워크 프로젝트의 `sdk/` 트리 안에 있는 같은 이름의 폴더로 교체-복사한다.

## 동작 원칙

- **절대경로 금지**: 어떤 단계에서도 `/Volumes/...`, `/Users/...` 같은 머신 종속 경로를 직접 입력하지 않는다. 현재 cwd / git 루트에서 출발해 디렉토리 패턴으로 추론한다.
- **소스/배포 위치 모름 가정**: 모듈은 `sdk_modules`, `sdk_units`, `sdk_logics` 중 어디에든 있을 수 있다. 탐색으로 찾는다.
- **현 프로젝트 configuration 미러링**: 모듈 빌드 configuration은 "현재 작업 중인 프레임워크 프로젝트"가 마지막에 사용한 configuration과 동일하게 맞춘다.
- **유니버설 빌드 강제(무조건)**: 모든 xcodebuild 호출은 `-arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO` 를 필수로 붙여 arm64+x86_64 fat 바이너리를 만든다. `-destination 'platform=macOS'` 의 CLI 기본은 native arch 단일(예: Apple Silicon에서 arm64 only) 이므로 소비 프로젝트가 유니버설 링크(예: Release ONLY_ACTIVE_ARCH=NO)를 요구하면 `Undefined symbol` 링크 실패가 발생한다. 선택 옵션 아님, 예외 없음.
- **파괴적 작업 명시**: 폴더 삭제와 빌드 산출물 교체가 일어난다. 각 단계 진행 전에 어떤 경로가 지워지고 어떤 경로로 복사되는지 사용자에게 한 줄 요약 후 진행.
- **`/Volumes/SourceCode/...` 류 경로는 예시일 뿐**: SKILL 본문이나 코드에 사용자 머신의 실제 경로를 박지 않는다. 모든 변수는 런타임 탐색으로 결정.

## 전체 흐름

```
[모듈명 인자] → [SDK 루트 추론] → [모듈 소스 위치 찾기] → [현재 framework configuration 추출]
            → [기존 deploy 폴더 삭제] → [모듈 재빌드] → [framework 내 모듈 폴더 교체]
            → [결과 보고]
```

## Step 0 — 인자 확인

- 호출 형태: `/sdk-build-sync <module_name>`
- `<module_name>`이 비어 있으면 묻고 중단. 자동 탐지 모드 없음.

## Step 1 — SDK 루트 추론

`sdks/` 컨테이너 디렉토리를 추론한다. 컨테이너의 정의: **하위에 `sdk_modules`, `sdk_units`, `sdk_logics`, `sdk_framework` 중 2개 이상을 가지는 디렉토리**.

탐색 순서 (먼저 매칭되는 것 사용):

1. cwd → 위로 올라가며 각 디렉토리에서 위 조건을 검사.
2. git 루트(`git rev-parse --show-toplevel`)에서 위로 올라가며 동일 검사.
3. git 루트의 형제 디렉토리(`..`)에서 동일 검사.

탐색 명령 예시 (상대경로 / 변수 사용):

```bash
# cwd에서 위로 거슬러 올라가며 sdks 루트 찾기
dir="$(pwd)"
while [ "$dir" != "/" ]; do
  count=0
  for sub in sdk_modules sdk_units sdk_logics sdk_framework; do
    [ -d "$dir/$sub" ] && count=$((count+1))
  done
  if [ "$count" -ge 2 ]; then SDK_ROOT="$dir"; break; fi
  dir="$(dirname "$dir")"
done
echo "SDK_ROOT=$SDK_ROOT"
```

찾지 못하면 사용자에게 SDK 루트를 묻고 중단.

## Step 2 — 모듈 소스 위치 찾기

`SDK_ROOT` 하위에서 `<module>`이라는 디렉토리를 찾는다. 우선순위 후보:

```
$SDK_ROOT/sdk_modules/<module>
$SDK_ROOT/sdk_units/<module>
$SDK_ROOT/sdk_logics/<module>
```

위에서 못 찾으면 `find "$SDK_ROOT" -maxdepth 3 -type d -iname "<module>"` 로 확장 탐색. 단, `modules_deploy` 하위는 제외(빌드 산출물 영역).

```bash
MODULE_SRC=""
for parent in sdk_modules sdk_units sdk_logics; do
  cand="$SDK_ROOT/$parent/<module>"
  [ -d "$cand" ] && MODULE_SRC="$cand" && MODULE_PARENT="$parent" && break
done
# fallback
if [ -z "$MODULE_SRC" ]; then
  MODULE_SRC="$(find "$SDK_ROOT" -maxdepth 3 -type d -iname "<module>" \
                ! -path "*/modules_deploy/*" | head -1)"
  MODULE_PARENT="$(basename "$(dirname "$MODULE_SRC")")"
fi
```

`MODULE_SRC` 또는 그 하위에 `.xcodeproj`가 있는지 검증. 없으면 빌드 불가 → 사용자에게 알리고 중단.

## Step 3 — Deploy 위치 추론

배포 위치는 모듈 카테고리(parent)와 같은 레벨 또는 그 안에 있는 `modules_deploy` 디렉토리이다. 후보 순서:

```
$SDK_ROOT/$MODULE_PARENT/modules_deploy/<module>     # 예: sdk_modules/modules_deploy/<module>
$SDK_ROOT/modules_deploy/<module>
```

존재하는 상위 `modules_deploy/` 디렉토리를 먼저 찾고, 그 하위에 `<module>` 폴더 경로를 `DEPLOY_DST`로 잡는다.

```bash
DEPLOY_PARENT=""
for cand in "$SDK_ROOT/$MODULE_PARENT/modules_deploy" "$SDK_ROOT/modules_deploy"; do
  [ -d "$cand" ] && DEPLOY_PARENT="$cand" && break
done
DEPLOY_DST="$DEPLOY_PARENT/<module>"
```

`DEPLOY_PARENT`를 못 찾았다면, `MODULE_PARENT` 안에서 `modules_deploy` 디렉토리를 한 번 더 검색. 그래도 없으면 사용자에게 묻는다(스킬이 임의로 새로 만들지 않는다).

## Step 4 — 현재 framework configuration 추출

"현재 작업 중인 프레임워크 프로젝트" = cwd 또는 git 루트에서 가장 가까운 `.xcodeproj` (단, `MODULE_SRC` 안의 것은 제외). 후보를 찾으면 마지막으로 사용된 configuration을 추출.

순서대로 시도:

1. `*.xcworkspace/xcuserdata/*/WorkspaceSettings.xcsettings`에서 마지막 active configuration.
2. `*.xcodeproj/xcuserdata/*/xcschemes/xcschememanagement.plist`의 `lastUsed`.
3. `xcodebuild -project <fw>.xcodeproj -showBuildSettings 2>/dev/null | awk '/ CONFIGURATION = /{print $3; exit}'`.
4. 위 모두 실패 → `Release` fallback. 사용자에게 한 줄로 알린다.

```bash
FW_PROJECT="$(find "$(pwd)" -maxdepth 3 -name '*.xcodeproj' \
              ! -path "$MODULE_SRC/*" | head -1)"
CONFIG="$(xcodebuild -project "$FW_PROJECT" -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/^[[:space:]]+CONFIGURATION = /{print $2; exit}')"
[ -z "$CONFIG" ] && CONFIG="Release"
```

## Step 5 — 사용자에게 실행 계획 제시

다음을 한 화면에 요약하고, 사용자가 멈추지 않는 한 진행:

- 모듈명, MODULE_SRC, DEPLOY_DST, FRAMEWORK_PROJECT, CONFIG
- 삭제될 경로(들): `DEPLOY_DST`, `FW_MODULE_DST` (Step 7에서 결정)

여기까지가 비파괴 단계. Step 6부터 파괴적 작업.

## Step 5.5 — 유니버설 체인 propagation (필수, 유니버설 강제와 짝)

유니버설(arm64+x86_64) 빌드는 의존성도 유니버설이어야 링크된다. 소비 프로젝트가 아닌 **중간 저장소의 vendored `sdk/`** 안에 arm64 only(또는 반대) 슬라이스인 dylib 이 있으면 downstream 빌드가 `ignoring file ... found architecture 'arm64', required architecture 'x86_64'` 로 실패한다.

따라서 각 하위 모듈을 유니버설로 빌드해 modules_deploy 에 넣은 뒤, **그 모듈을 소비하는 상위 모듈의 소스 저장소 `sdk/<cat>/<mod>` 아래 vendored 카피에 대해서도 modules_deploy → sdk/ 로 로컬 cp propagation 을 수행**해야 한다. 이는 "친절한 확장"이 아니라 유니버설 빌드가 성립하기 위한 기술적 필수 조건이다.

Propagation 은 오직 로컬 cp 만 사용하고, `gsdkmanager` 체크아웃/재수신은 사용하지 않는다(캐시가 stale 이면 옛 것으로 덮어써서 방금 만든 유니버설을 무력화한다).

```bash
# <upstream_mod> 을 방금 유니버설로 빌드한 후, 그것을 vendoring 하는 각 <consumer_mod> 에 대해
CONSUMER_SDK="$SDK_ROOT/<cat>/<consumer_mod>/<capitalized>/sdk"
CONSUMER_VENDORED="$CONSUMER_SDK/<upstream_cat>/<upstream_mod>"
if [ -d "$CONSUMER_VENDORED" ]; then
  rm -rf "$CONSUMER_VENDORED"
  cp -R "$SDK_ROOT/<upstream_cat>/modules_deploy/<upstream_mod>" "$CONSUMER_VENDORED"
fi
```

Downstream 빌드가 arch mismatch 로 실패하지 않을 때까지 이 propagation 은 생략 금지.

## Step 6 — Deploy 폴더 삭제 후 재빌드 (유니버설 강제)

```bash
[ -d "$DEPLOY_DST" ] && rm -rf "$DEPLOY_DST"

XCODEPROJ="$(find "$MODULE_SRC" -maxdepth 2 -name '*.xcodeproj' | head -1)"
SCHEME="$(xcodebuild -project "$XCODEPROJ" -list 2>/dev/null \
          | awk '/Schemes:/{flag=1;next} flag{gsub(/^[[:space:]]+/,""); if($0=="")exit; print}' \
          | head -1)"

# 유니버설(arm64+x86_64) 강제. 절대 생략 금지 — 소비 프로젝트가 x86_64 slice 를 요구하면 Undefined symbol 링크 실패.
xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" \
           -configuration "$CONFIG" \
           -destination 'generic/platform=macOS' \
           -arch arm64 -arch x86_64 \
           ONLY_ACTIVE_ARCH=NO \
           build 2>&1 | tail -60
```

`BUILD FAILED` 또는 `error:` 발견 시 즉시 중단하고 에러 표시. 산출물 동기화로 넘어가지 않는다.

빌드 후 `DEPLOY_DST`가 다시 생성되었는지 확인. 생성되지 않았다면 산출물 위치가 다른 것 — 사용자에게 알리고 중단.

빌드 후 산출 dylib 이 실제로 유니버설인지 검증:

```bash
DYLIB="$(find "$DEPLOY_DST/dylib" -name '*.dylib' | head -1)"
lipo -info "$DYLIB" | grep -qE "arm64.*x86_64|x86_64.*arm64" || {
  echo "[sdk-build-sync] STEP 6 FAIL: 산출 dylib 이 유니버설이 아님 — $(lipo -info $DYLIB)"; exit 1;
}
```

## Step 7 — Framework 내 모듈 위치 탐색 후 교체

현재 framework 프로젝트의 `sdk/` 트리(또는 그에 상응하는 경로) 하위에서 `<module>` 폴더를 찾는다.

```bash
FW_ROOT="$(dirname "$FW_PROJECT")"
# framework가 그 위에 sdk/ 폴더를 두는 패턴이므로, FW_PROJECT의 부모 ~ 부모의 부모를 후보로 탐색
FW_MODULE_DST="$(find "$FW_ROOT/.." -maxdepth 5 -type d -iname "<module>" \
                 ! -path "*/build/*" ! -path "*/DerivedData/*" \
                 ! -path "$MODULE_SRC*" ! -path "$DEPLOY_PARENT/*" \
                 | head -1)"
```

- 못 찾으면 사용자에게 위치를 묻는다.
- 후보가 여러 개라면 모두 보여주고 선택을 받는다(임의로 결정하지 않음).

확정되면 교체:

```bash
rm -rf "$FW_MODULE_DST"
cp -R "$DEPLOY_DST" "$FW_MODULE_DST"
```

## Step 8 — 결과 보고

다음 5줄로만 보고:

- 모듈명
- 빌드 configuration
- 빌드 결과: 성공 / 실패
- 동기화 대상 경로 (FW_MODULE_DST를 SDK_ROOT 기준 상대경로로 표시)
- 후속 작업 제안: framework 프로젝트 클린/리빌드 여부

## 금지 사항

- `find /` 처럼 루트 전체 탐색 금지. 항상 `SDK_ROOT` 또는 framework 루트 범위 안에서 탐색.
- `git clean -fdx`, `git reset --hard` 같은 부수적 정리 작업 금지. 산출물 교체 외 git 트리는 손대지 않는다.
- 사용자가 명시하지 않은 다른 모듈도 같이 동기화하는 "친절한 확장" 금지.
- `xcodebuild clean`을 자동으로 끼워 넣지 않는다. 모듈 빌드 실패 시 사용자에게 물어보고 결정.
- `modules_deploy/` 폴더 자체가 없을 때 자동 생성 금지. 사용자에게 확인 후 진행.

## 실패 시 메시지 양식

각 단계 실패는 다음 형식으로 한 줄 요약:

```
[sdk-build-sync] STEP <n> FAIL: <한 줄 사유> — <필요한 사용자 입력 or 다음 행동>
```

"""#

// source: docs/sample/skills/sdk-development-process/SKILL.md
private let skillSdkDevelopmentProcess = #"""
---
name: sdk-development-process
description: >-
  SDK/라이브러리 개발 시 지켜야 할 작업 방식(UI 역할범위, 함수 단위 개발, 버전/문서화 규율, 완료 검증).
  공개 Header 폴더·Framework 타겟·ai/sample/ 폴더 등의 신호로 SDK/라이브러리 프로젝트로 판별되면
  활성화. Use for SDK/library development workflow.
---

# SDK/라이브러리 개발 프로세스

## 감지 신호
`sdk-library-conventions`와 동일(공개 Header 폴더·Framework 타겟·`ai/sample/`·SemVer+CHANGELOG).

## UI 역할 범위 (MANDATORY)
SDK 코드는 UI 요소(NSView/NSWindow 등)의 생성·배치·레이아웃 작업을 하지 않는다. UI는 SDK의 책임 범위가 아니다.
- **허용**: 기존 IBAction의 내부 비즈니스 로직 수정, UI와 무관한 순수 로직/데이터 처리 함수.
- **예외**: `ai/sample/` 경로의 Sample App(SDK 검증용)에 한해 UI 개발 제한을 해제한다. 단 XIB/Storyboard는 여전히 금지, 코드 기반 UI만 허용한다.
- UI 작업을 요청받으면: ① 즉시 "SDK 개발 범위 밖입니다"로 거절 ② SDK 인터페이스 대안 제시 ③ 사용자가 직접 작성하도록 안내.

## 함수 단위 개발
신규 클래스는 골격(시그니처만)을 먼저 제시해 승인받고, 이후 함수를 하나씩 작성 → 제시 → 확인 → 다음 함수로 진행한다. 설계 전체를 한 번에 구현하지 않는다. 다만 패턴이 명확하고 반복적인 경우까지 매번 확인받을 필요는 없다 — 애매하거나 설계에 영향을 주는 함수만 확인받는다.

## 버전/문서화 규율
- Semantic Versioning(Major.Minor.Patch)을 준수하고 CHANGELOG에 기록한다.
- SDK 연동 가이드는 `INTEGRATION_GUIDE.md` 하나로 통합 작성한다(README와 같은 위치). 공개 API 사용법·초기화 절차·콜백/Delegate 처리·에러 핸들링을 모두 포함한다.

## 완료 검증 (DoD)
1. 설계 가이드에 따른 기능 구현 완료
2. 전역 코딩/명명 규칙 준수
3. **Unit Test 통과** — 실패하는 코드는 제출할 수 없다
4. **Sample App으로 실제 동작 증명** — 호스트 앱에서 기능이 실제로 동작함을 증명하는 최소 단위 샘플을 제공하거나 실행 결과를 보고한다
5. 보안·Zero-Trace 원칙 위반 여부 자가 점검
6. **Public API 노출 검증** — 공개 인터페이스가 설계서에 정의된 대로 정확히 노출되는지, 불필요한 내부 심볼이 새어나가지 않는지 확인

"""#

// source: docs/sample/skills/sdk-dylib-deploy/SKILL.md
private let skillSdkDylibDeploy = #"""
---
name: sdk-dylib-deploy
description: "수정된 SDK dylib 모듈(들)을 의존성 순서(최하위부터)대로 Release/Debug 유니버셜(arm64+x86_64)로 재빌드해 `sdk_deploy/{category}/{release|debug}/<module>`(=gitlab clone)에 배포하고 commit+tag+push 한다. 호출: `/sdk-dylib-deploy <module_name> [<module_name> ...]`. 카테고리·경로는 cwd/git 루트에서 추론(하드코딩 금지)."
---

# SDK Dylib Deploy

하나 이상의 dylib 모듈을 **의존성 순서(최하위부터)**로 배포한다. 각 모듈은: ① 프로젝트의 vendored `sdk/` 폴더를 통째로 삭제 → ② gsdkmanager로 의존성을 gitlab에서 새로 내려받음(방금 push 된 하위 모듈 포함) → ③ Release/Debug 재빌드 → ④ `sdk_deploy/{category}`(gitlab clone)에 배포 → ⑤ commit + tag + push. **하위 모듈을 먼저 push 해야 상위 모듈이 그것을 내려받으므로 순서가 핵심**이다.

## 동작 원칙

- **절대경로 금지**: `/Volumes/...`, `/Users/...` 류 머신 종속 경로를 박지 않는다. cwd / git 루트 / `sdks` 컨테이너 탐색으로 결정.
- **여러 모듈 + 의존성 순서**: 인자가 여러 개면 각 모듈의 `GSDKMFile_logic/unit/module` 의존 선언을 읽어 **배포 목록 내부의** 의존 관계만으로 위상정렬(topological sort)해 **다른 것이 의존하는(하위) 모듈부터** 처리한다. 고정 순서를 가정하지 않는다.
- **빌드 전 항상 sdk 폴더 삭제**: 매 빌드(Release/Debug 각각) 직전에 프로젝트의 vendored `sdk/` 폴더를 `rm -rf` 로 통째로 지운다(하위 전부). **pbxproj 의 파일 레퍼런스는 건드리지 않는다 — 폴더 실체만 지운다.** gsdkmanager 가 다시 채운다.
- **gsdkmanager 없는 모듈 처리 — 2가지로 구분**(GSDKMFile 의존성 유무로 판단):
  - ① **의존성 0(예 `RXCommonModels`)**: `gsdkmanager/`·vendored `sdk/` 가 아예 없다. **sdk 삭제·`sdk_starter.sh` 재수신·checkout_config 백업/복원 단계를 생략하고 곧장 빌드**한다(중단 금지).
  - ② **의존성은 있는데 gsdkmanager 만 누락(예 `RXIPCProvider`)**: gsdkmanager 가 단지 체크아웃에서 빠진 것이다(빌드가 `<Module>/sdk/sdk_modules/<dep>` 를 찾다 실패). **중단하지 말고**, 형제 모듈의 `gsdkmanager/`(`sdk_checkout.py`·`sdk_starter.sh`·`gitlab_token.account`)를 복사하고 `checkout_config` 를 생성해 gsdkmanager 를 복원한 뒤, **정상 플로우(sdk 삭제·`sdk_starter.sh` 재수신·빌드)** 로 진행한다(이 모듈 `GSDKMFile` 의 의존성을 그대로 받아온다).
  - 어느 경우든 산출물 비우기·빌드·배포·commit/tag/push 는 동일하게 수행.
- **gsdkmanager 명시 실행**: gsdkmanager 는 xcscheme pre-action(`sdk_starter.sh`)으로 걸려 있으나 **`xcodebuild` 는 scheme pre-action 을 실행하지 않는다.** 따라서 빌드 직전 **`gsdkmanager/sdk_starter.sh -c <config>` 를 스킬이 직접 실행**해 의존성을 새로 받는다. (gitlab 토큰 `gsdkmanager/gitlab_token.account` + 네트워크 필요. sdk_checkout.py 는 "없는 모듈만" 받으므로 sdk 폴더를 통째로 지운 뒤 실행해야 전부 fresh 다운로드된다.)
- **gitlab 전파**: `sdk_deploy/{category}` 는 gitlab `macapplicationdev/sdk_deploy/{category}` 의 clone(branch `main`). 기존 배포가 복사하는 위치가 곧 이 워킹카피다. 배포 후 그 repo 에서 **해당 모듈 경로만** `git add` → commit → tag → `git push`(commit + tag) 해야 다음(상위) 모듈의 gsdkmanager 가 새 버전을 내려받는다.
- **배포 전 원격 최신화(필수·시작 조건)**: 파괴적 단계에 들어가기 전에 배포 대상 각 `sdk_deploy/{category}` 카테고리 repo 를 `git fetch origin && git pull --ff-only origin <branch>` 로 **원격 최신에 맞춘 뒤 시작**한다(Step 4.5). 워킹카피가 stale(behind) 이면 배포물을 commit/tag 해도 push 가 non-fast-forward 로 거부되고, 이미 push 한 태그·커밋과 어긋난다. `--ff-only` 가 실패하면(로컬에 push 안 된 커밋 존재) **자동 merge/rebase/force 금지**, 사용자에게 보고·확인.
- **commit/tag 형식은 repo 기존 형식 미러**: 태그·커밋 제목은 그 repo 에서 **해당 ProjectName 의 기존 태그/커밋을 조회해 동일 형식**으로 만든다(§7). 버전은 그 모듈 **소스의 xcconfig `DYLIB_CURRENT_VERSION`** 을 따른다(deploy 태그 +1 아님).
- **두 configuration 순차**: Release → Debug. Release 실패 시 그 모듈에서 즉시 중단(Debug·push 안 함). 한 모듈 실패 시 전체 체인 중단(이미 push 된 하위는 그대로 둠).
- **checkout_config 복원**: 각 모듈 처리 시작 시 `gsdkmanager/checkout_config` 원본을 백업, 끝(성공/실패/중단 무관)에 복원.
- **빌드 destination 고정 + 유니버셜 필수**: 항상 **Any Mac** + **유니버셜(arm64+x86_64)** — `-destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`. My Mac(`platform=macOS`) 금지. **단일 아키텍처 빌드 금지 — 반드시 fat binary**. 산출 dylib 를 `lipo -info` 로 arm64+x86_64 둘 다 있는지 검증, 하나라도 빠지면 그 모듈 중단.
- **sdk_ui = `.framework` UI 모듈 특수 처리**: `MODULE_PARENT=sdk_ui` 모듈(예 `UIRXRCAPIHostDraw`)은 dylib 이 아니라 `.framework` 산출이라 아래가 다르다.
  - ① **배포 폴더명 = ProjectName 소문자**(`GSDKMFile` 의 `project` 필드 소문자). **소스 폴더명과 다를 수 있다** — 예: 소스 `sdk_ui/rxrcapihostdraw` → 배포 `sdk_ui/{release|debug}/uirxrcapihostdraw`.
  - ② **버전 = `common_xcframework_swift/*_release.xcconfig` 의 `CURRENT_PROJECT_VERSION`**(`DYLIB_CURRENT_VERSION` 은 이 값을 `$(CURRENT_PROJECT_VERSION)` 로 참조하므로 그대로 읽으면 안 됨).
  - ③ **산출물 = `.framework`(dylib+public_headers 아님)**: build phase 가 `modules_deploy/<projlower>/framework/` 에 `cp -rf` 로 두지만 **이 복사본은 심링크가 평탄화**되므로 배포에 쓰지 말 것. 대신 **DerivedData `Build/Products/{Release|Debug}/<Project>.framework` 원본을 `ditto` 로 배포**한다(심링크 보존 — `cp -R`/평탄화 금지).
  - ④ **배포 대상 = `CAT_REPO/{release|debug}/<projlower>/<Project>.framework`** (그 안의 `.framework` 만 교체).
  - ⑤ **검증**: `ditto` 후 최상위 심링크 4개(`Headers`/`Modules`/`Resources`/`<Project>` → `Versions/Current/...`)와 `Versions/Current`→`A` 가 살아있고, 바이너리 `Versions/A/<Project>` 가 유니버설(`lipo`) 인지 확인. 심링크가 사라졌으면(=`cp` 로 평탄화) 중단.
  - 그 외(sdk 삭제·gsdkmanager 재수신·checkout_config 백업/복원·Release→Debug 순차·commit/tag/push 형식 미러)는 dylib 모듈과 동일.
- **파괴 작업 명시**: 어떤 경로가 지워지고 어디로 복사·push 되는지 진행 전 한 화면에 요약.
- **부수 정리 금지**: `xcodebuild clean`, `git clean`, `git reset`, `git stash`, force push, auto-rebase 등 자동 실행 금지. 명시한 삭제(`sdk/`, `modules_deploy/<module>`, 배포 대상 폴더) 외엔 손대지 않는다.

## 전체 흐름

```
[모듈명 인자(1개 이상)] → [SDK_ROOT 추론] → [각 모듈: 소스위치 + 카테고리]
   → [GSDKMFile 의존성 그래프 → 위상정렬(하위 먼저)]
   → [배포 대상 sdk_deploy/{cat} repo 원격 최신화: pull --ff-only]
   → [실행 계획 표시]
   → 정렬 순서대로 한 모듈씩 완결:
        checkout_config 백업
        (Release) sdk/ 삭제 → sdk_starter.sh -c Release → 빌드 → sdk_deploy/{cat}/release/{mod} 교체
        (Debug)   sdk/ 삭제 → sdk_starter.sh -c Debug   → 빌드 → sdk_deploy/{cat}/debug/{mod} 교체
        checkout_config 복원
        [버전 = 소스 xcconfig DYLIB_CURRENT_VERSION] [형식 = repo 기존 미러]
        sdk_deploy/{cat}: git add {release,debug}/{mod} → commit → tag → push(commit+tag)
   → [결과 보고]
```

## Step 0 — 인자 확인

- 호출: `/sdk-dylib-deploy <module_name> [<module_name> ...]` (소문자 폴더명, 1개 이상).
- 비어 있으면 묻고 중단. 자동 탐지 없음.

## Step 1 — SDK_ROOT 추론

`sdks/` 컨테이너 정의: 하위에 `sdk_modules`,`sdk_units`,`sdk_logics`,`sdk_framework` 중 2개 이상.

```bash
dir="$(pwd)"; SDK_ROOT=""
while [ "$dir" != "/" ]; do
  c=0; for s in sdk_modules sdk_units sdk_logics sdk_framework; do [ -d "$dir/$s" ] && c=$((c+1)); done
  [ "$c" -ge 2 ] && SDK_ROOT="$dir" && break
  dir="$(dirname "$dir")"
done
```
cwd → git 루트 → git 루트 형제 순으로 검사. 못 찾으면 사용자에게 묻고 중단.

## Step 2 — 각 모듈 소스위치 + 카테고리

각 `<module>` 에 대해 우선순위로 탐색:
```
$SDK_ROOT/sdk_modules/<module>   → MODULE_PARENT=sdk_modules
$SDK_ROOT/sdk_units/<module>     → MODULE_PARENT=sdk_units
$SDK_ROOT/sdk_logics/<module>    → MODULE_PARENT=sdk_logics
$SDK_ROOT/sdk_framework/<module> → MODULE_PARENT=sdk_framework
$SDK_ROOT/sdk_ui/<module>        → MODULE_PARENT=sdk_ui   (.framework UI 모듈 — §동작원칙 'sdk_ui 특수 처리')
```
fallback: `find "$SDK_ROOT" -maxdepth 3 -type d -iname "<module>" ! -path "*/modules_deploy/*"`. 부모가 5개 카테고리 중 하나가 아니면 중단·확인.
각 모듈의 `.xcodeproj` 존재 검증(없으면 중단). 각 모듈의 ProjectName(PascalCase)은 `GSDKMFile_*` 의 `"project"` 필드에서 읽는다(태그/커밋용).

## Step 3 — 의존성 위상정렬 (하위 먼저)

각 모듈 루트의 `GSDKMFile_logic` / `GSDKMFile_unit` / `GSDKMFile_module` 을 읽는다.
- 각 파일의 타입 객체(`logic`/`unit`/`module`)의 **key 들**이 의존하는 ProjectName(PascalCase).
- 그 의존 집합을 **이번 배포 목록**의 ProjectName 과 (대소문자 무시) 교집합 → 간선(모듈 → 그 모듈이 의존하는 모듈).
- 위상정렬해 **의존받는(하위) 모듈이 먼저** 오게 정렬. 사이클이면 중단·보고.
- 배포 목록에 없는 의존성은 무시(이미 gitlab 에 있다고 가정).

예) `framework, ftpmanager, commandmanager, connectionmanager`:
`connectionmanager`(나머지가 의존) → `commandmanager`·`ftpmanager`(connectionmanager 의존) → `framework`(셋 다 의존). 정렬 결과 순서로 배포.

## Step 4 — 모듈별 경로 확정

각 모듈에 대해:
```bash
# vendored sdk 폴더 (삭제 대상; pbxproj 레퍼런스는 두고 폴더만 지움)
SDK_VENDORED="$(find "$MODULE_SRC" -maxdepth 3 -type d -name sdk ! -path '*/build/*' ! -path '*DerivedData*' | head -1)"
# gsdkmanager
GSDK_DIR="$(find "$MODULE_SRC" -maxdepth 2 -type d -name gsdkmanager | head -1)"
CHECKOUT_CFG="$GSDK_DIR/checkout_config"
# 빌드 산출물
DEPLOY_SRC="$( [ -d "$SDK_ROOT/$MODULE_PARENT/modules_deploy" ] && echo "$SDK_ROOT/$MODULE_PARENT/modules_deploy/<module>" || echo "$SDK_ROOT/modules_deploy/<module>" )"
# sdk_deploy (gitlab clone) — sdks 컨테이너의 형제
SDK_DEPLOY="$(dirname "$SDK_ROOT")/sdk_deploy"; [ -d "$SDK_DEPLOY" ] || SDK_DEPLOY="$SDK_ROOT/sdk_deploy"
CAT_REPO="$SDK_DEPLOY/$MODULE_PARENT"          # 예: sdk_deploy/sdk_logics (git repo, origin=gitlab, branch main)
RELEASE_DST="$CAT_REPO/release/<module>"
DEBUG_DST="$CAT_REPO/debug/<module>"
```
- `DEPLOY_SRC`/`CAT_REPO` 를 못 찾으면 그 모듈에서 중단·확인. **`GSDK_DIR`/`SDK_VENDORED`/`CHECKOUT_CFG` 가 없으면 중단하지 말고 §동작원칙의 'gsdkmanager 없는 모듈 처리 — 2가지'** 로 분기한다: 의존성 0이면 직접 빌드, 의존성이 있으면 형제 모듈에서 gsdkmanager 를 복원한 뒤 정상 플로우.
- `CAT_REPO` 가 git repo 이고 `origin` 이 gitlab `sdk_deploy` 인지 확인. 아니면 push 단계에서 중단·확인.
- `release`/`debug` 디렉토리가 없으면 임의 생성 금지 — 확인.

## Step 4.5 — 배포 repo 원격 최신화 (파괴 전 필수)

배포 대상 카테고리들의 고유 `CAT_REPO` 각각에 대해, 파괴적 단계 진입 전에 원격 최신으로 맞춘다.
```bash
CUR_BRANCH="$(git -C "$CAT_REPO" rev-parse --abbrev-ref HEAD)"
git -C "$CAT_REPO" fetch origin 2>&1 | tail -3
git -C "$CAT_REPO" pull --ff-only origin "$CUR_BRANCH" 2>&1 | tail -5
```
- `--ff-only` 성공(또는 already up to date) 이어야 진행. **stale(behind) 상태로 배포 시작 금지.**
- `--ff-only` 실패 = 로컬에 원격에 없는 커밋(직전 실패 잔여 등)이 있다는 뜻 → **자동 merge/rebase/force 금지**, 사용자에게 상태 보고 후 지시받는다.
- 같은 카테고리에 여러 모듈이 있어도 repo 최신화는 카테고리당 1회.

## Step 5 — 실행 계획 제시 (비파괴)

정렬된 순서와, 각 모듈의 `MODULE_SRC`/카테고리/`SDK_VENDORED`(삭제)/`RELEASE_DST`·`DEBUG_DST`(교체)/`CAT_REPO`(commit+tag+push 대상)/예정 버전·태그를 한 화면 요약. 이후부터 파괴적.

## Step 6 — 모듈별 빌드·배포 (정렬 순서대로, 한 모듈씩 완결)

각 모듈에 대해 아래 수행. **한 모듈의 push(§7)까지 끝낸 뒤** 다음 모듈로 간다(상위 모듈이 방금 push 된 하위를 받도록).

```bash
# checkout_config 백업/복원·트랩은 gsdkmanager 가 있는 모듈만 (없는 베이스 모듈은 스킵)
HAS_GSDK=0
if [ -n "$GSDK_DIR" ] && [ -f "$CHECKOUT_CFG" ]; then
  HAS_GSDK=1
  ORIG_CFG="$(cat "$CHECKOUT_CFG")"
  trap 'printf "%s" "$ORIG_CFG" > "$CHECKOUT_CFG"' EXIT   # 복원 보장
fi

XCODEPROJ="$(find "$MODULE_SRC" -maxdepth 2 -name '*.xcodeproj' | head -1)"
SCHEME="$(xcodebuild -project "$XCODEPROJ" -list 2>/dev/null | awk '/Schemes:/{f=1;next} f{gsub(/^ +/,"");print;exit}')"

for CONFIG in Release Debug; do
  cfg_lc="$(echo "$CONFIG" | tr 'A-Z' 'a-z')"
  # 6-1~6-3) gsdkmanager 가 있는 모듈만: vendored sdk 삭제 → 산출물 비우기 → gsdkmanager 재다운로드
  if [ "$HAS_GSDK" -eq 1 ]; then
    [ -d "$SDK_VENDORED" ] && rm -rf "$SDK_VENDORED"        # 폴더 실체만 (pbxproj 레퍼런스 유지)
    [ -d "$DEPLOY_SRC" ] && rm -rf "$DEPLOY_SRC"
    ( cd "$GSDK_DIR" && ./sdk_starter.sh -c "$CONFIG" ) 2>&1 | tail -30   # checkout_config 도 이 안에서 갱신
  else
    # gsdkmanager 없는 베이스 모듈(예 RXCommonModels): 삭제·재다운로드 생략, 산출물만 비움
    [ -d "$DEPLOY_SRC" ] && rm -rf "$DEPLOY_SRC"
  fi
  # 6-4) 빌드 — 반드시 유니버셜(arm64+x86_64)
  xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -configuration "$CONFIG" \
             -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build 2>&1 | tail -40
  #   → BUILD FAILED / error: 발견 시 즉시 중단(복원 후 보고). DEPLOY_SRC 미생성 시 중단.
  #   → 산출 dylib `lipo -info` 로 arm64+x86_64 둘 다 확인. 단일 아키텍처면 중단(유니버셜 강제).
  # 6-5) sdk_deploy 교체
  DST="$CAT_REPO/$cfg_lc/<module>"
  [ -d "$DST" ] && rm -rf "$DST"; mkdir -p "$(dirname "$DST")"; cp -R "$DEPLOY_SRC" "$DST"
done

# 6-6) checkout_config 복원 (gsdkmanager 있는 모듈만)
[ "$HAS_GSDK" -eq 1 ] && printf '%s' "$ORIG_CFG" > "$CHECKOUT_CFG"
```

> **sdk_ui(.framework) 모듈은 6-5 교체가 다르다** (§동작원칙 'sdk_ui 특수 처리'): `DEPLOY_SRC`(modules_deploy dylib) 대신 **DerivedData `Build/Products/<CONFIG>/<Project>.framework` 원본**을 `ditto` 로 `CAT_REPO/<cfg_lc>/<projlower>/<Project>.framework` 에 배포한다(심링크 보존). DerivedData 경로는 `xcodebuild -showBuildSettings ... | grep -m1 CONFIGURATION_BUILD_DIR` 로 얻거나 방금 빌드 산출물을 `find` 로 찾는다. build phase 가 만든 `modules_deploy/<projlower>/framework/` 복사본은 심링크가 평탄화되어 있으니 쓰지 않는다. sdk 삭제·재수신·유니버설·Release→Debug 순차는 위와 동일.

## Step 7 — commit + tag + push (해당 카테고리 repo)

`CAT_REPO` 에서 수행. **버전은 소스 xcconfig 의 `DYLIB_CURRENT_VERSION` 을 따르고, 태그·커밋 형식은 그 repo 의 기존 것을 미러**한다.

```bash
PROJ="<ProjectName>"        # GSDKMFile 의 project 필드 (PascalCase)
cd "$CAT_REPO"
git fetch --tags origin 2>/dev/null

# 7-1) 버전 = 그 모듈 소스의 xcconfig DYLIB_CURRENT_VERSION (deploy 태그 +1 아님)
#   소스 common/<module>_release.xcconfig(없으면 _debug)에서 읽는다. 태그 형식은 {ProjectName}_{x.y.z} 유지.
NEWVER="$(grep -E 'DYLIB_CURRENT_VERSION' "$MODULE_SRC"/common/*_release.xcconfig 2>/dev/null | head -1 | sed -E 's/.*= *//' | tr -d ' \r')"
[ -z "$NEWVER" ] && NEWVER="$(grep -E 'DYLIB_CURRENT_VERSION' "$MODULE_SRC"/common/*_debug.xcconfig 2>/dev/null | head -1 | sed -E 's/.*= *//' | tr -d ' \r')"
# sdk_ui(.framework) 모듈: 버전은 common_xcframework_swift/*_release.xcconfig 의 CURRENT_PROJECT_VERSION (DYLIB_CURRENT_VERSION 은 $(CURRENT_PROJECT_VERSION) 참조라 위에서 안 잡힘)
[ -z "$NEWVER" ] && NEWVER="$(grep -E 'CURRENT_PROJECT_VERSION' "$MODULE_SRC"/common_xcframework_swift/*_release.xcconfig 2>/dev/null | head -1 | sed -E 's/.*= *//' | tr -d ' \r')"
#   NEWVER 가 비면 사용자에게 확인. deploy repo 의 기존 최고 태그보다 낮으면(역행) 중단·확인.
#   태그·커밋은 §7 대로 repo 기존 형식 미러(예 draw: 커밋 "UIRXRCAPIHostDraw v{ver}", 태그 "UIRXRCAPIHostDraw_{ver}"). add 경로는 sdk_ui면 release/<projlower> debug/<projlower>.
NEWTAG="${PROJ}_${NEWVER}"

# 7-2) 커밋 제목 형식 = 그 모듈의 가장 최근 커밋 제목을 미러 (repo 마다·모듈마다 형식이 다를 수 있음)
LAST_MSG="$(git log -i --grep="$PROJ" --format='%s' -1)"   # 예: "RXRCAPIHostFTPManager v0.1.0"
#   LAST_MSG 에서 버전 토큰만 NEWVER 로 치환해 동일 형식의 NEWMSG 생성.
#   (예: "RXRCAPIHostFTPManager v0.1.0" → "RXRCAPIHostFTPManager v0.1.1")
#   해당 모듈 커밋이 없으면 사용자에게 커밋 형식 확인.

# 7-3) 해당 모듈 경로만 스테이징 → commit → tag → push
git add "release/<module>" "debug/<module>"
git commit -m "$NEWMSG"
git tag "$NEWTAG"
git push origin "$(git rev-parse --abbrev-ref HEAD)"
git push origin "$NEWTAG"
```

- 태그는 기존이 모두 `{ProjectName}_{x.y.z}` → 그대로, 버전은 소스 xcconfig `DYLIB_CURRENT_VERSION`.
- 커밋 제목은 그 모듈 최근 커밋 형식을 그대로 따르고 버전만 교체.
- push 실패(권한/네트워크/충돌) 시 중단·보고. 충돌이면 사용자 확인(자동 rebase/force 금지).
- **한 모듈 push 성공 후** 다음 모듈로(그래야 상위 모듈 gsdkmanager 가 새 태그를 받음).

## Step 8 — 결과 보고

모듈별로:
- 모듈 / 카테고리 / 처리 순번
- Release·Debug 빌드 결과(성공/실패 위치)
- 배포 경로(release/debug, SDK_ROOT 기준 상대)
- 새 버전 / 태그 / 커밋 제목 / push 결과
- checkout_config 복원 결과(원본→현재)
마지막에 전체 순서와 성공/중단 지점 요약.

## 실패 시 메시지 양식

```
[sdk-dylib-deploy] <module> STEP <n> FAIL: <한 줄 사유> — checkout_config 복원 완료/실패, 이전 모듈 push 상태 유지
```

## 금지 사항

- `find /` 전 시스템 탐색 금지. `SDK_ROOT`/그 부모 1단계까지로 제한.
- 인자에 없는 모듈을 같이 배포 금지.
- `xcodebuild clean`/`git clean`/`git reset`/`git stash`/force push/auto-rebase 금지.
- pbxproj 의 sdk 파일 레퍼런스를 지우지 않는다(폴더 실체만 삭제).
- `sdk_deploy/{category}/{release|debug}` 디렉토리가 없을 때 임의 생성 금지(확인). 단 그 안의 `<module>` 폴더는 교체 대상이라 직접 다룬다.
- `modules_deploy` 디렉토리 자체가 없을 때 임의 생성 금지.
- checkout_config 복원을 스킵하지 않는다(어떤 실패 경로에서도).
- 의존성 순서를 무시하고 임의 순서로 배포하지 않는다(상위가 옛 하위를 받게 됨).

"""#

// source: docs/sample/skills/sdk-library-conventions/SKILL.md
private let skillSdkLibraryConventions = #"""
---
name: sdk-library-conventions
description: >-
  SDK/라이브러리 프로젝트에서 코드 자체가 지켜야 할 규칙(Public API 하위호환, Zero-Trace 보안).
  공개 Header 폴더·Framework 타겟·ai/sample/ 폴더·SemVer+CHANGELOG 등의 신호로 SDK/라이브러리
  프로젝트로 판별되면 활성화. Use for SDK/library source code conventions.
---

# SDK/라이브러리 코드 규칙

## 감지 신호 (하나 이상 해당 시 활성화)
공개 Header 폴더(`*/Headers/*.h` 등) · Xcode Framework/Static-Library 타겟 · `ai/sample/` 폴더 · `CHANGELOG.md`+SemVer 버전 표기.

## Public API 하위 호환
- 공개 헤더에 노출되는 클래스·프로토콜·메서드는 배포 후 변경 시 하위 호환성을 반드시 고려한다.
- Deprecated 마킹 없이 공개 API를 삭제하거나 시그니처를 변경하지 않는다.
- SDK 내부 구현 클래스와 외부 공개 인터페이스를 명확히 분리한다. 내부 클래스를 공개 헤더에 노출하지 않는다.
- 외부 라이브러리 의존을 최소화한다. 불가피하면 명시적으로 문서화한다.

## Zero-Trace (흔적 차단)
- 코드에서 로컬 파일 시스템에 로그를 남기거나 민감한 데이터를 저장하지 않는다. 모든 데이터 처리는 메모리 내에서 수행한다.
- 프로세스 간 통신(IPC)은 Unix Domain Sockets(UDS)를 사용하며, 네트워크 포트를 노출하지 않는다.
- API Key·비밀번호 등 민감한 정보는 코드에 하드코딩하지 않으며, 로그에도 출력하지 않는다.

"""#

// source: docs/sample/skills/solid-objc-design/SKILL.md
private let skillSolidObjcDesign = #"""
---
name: solid-objc-design
description: "Activate when designing or reviewing Objective-C/Cocoa class and protocol structure for SOLID compliance. Checks SRP/OCP/LSP/ISP/DIP plus cohesion and an acyclic dependency graph."
---

# SOLID Design Review — Objective-C / Cocoa

## Procedure
1. Identify every type in scope (class, protocol, category).
2. Evaluate each against the S/O/L/I/D criteria below.
3. Flag violations with `file:line` and a suggested refactor.

## Checklist

### S — Single Responsibility
**Check**: One reason to change per class.
- [ ] `.m` file exceeds ~500 lines → split
- [ ] Class name contains "And" → multiple responsibilities
- [ ] Owns unrelated concerns (e.g., network + UI + logging)

**Bad**: `@interface FileManager` owns download, save, showUI, log methods
**Good**: Split into `FileDownloader`, `FileStorage`, `TransferProgressView`

### O — Open/Closed
**Check**: Extend by adding new types, not by modifying existing code.
- [ ] Adding behavior requires modifying an existing `if/switch` → abstract behind a Protocol
- [ ] Could a Category extend it instead?

**Good**: `FileTransferProtocol` conformed by `FTPTransfer`, `SFTPTransfer`

### L — Liskov Substitution
**Check**: Every subtype honors the full contract of the base type.
- [ ] Subclass throws exceptions from overridden methods
- [ ] Subclass empties out `[super method]` or returns dummy values
- [ ] Every `id<Protocol>` consumer can swap any conformer interchangeably

### I — Interface Segregation
**Check**: Clients depend only on the methods they use.
- [ ] Protocol has many `@optional` methods → split into focused protocols
- [ ] Delegate with 5+ methods → consider splitting
- [ ] Conformers implement empty stubs for protocol methods

**Bad**: One `DataManagerDelegate` covering file, progress, auth, profile methods
**Good**: Split into `FileReceiveDelegate`, `ProgressDelegate`, `AuthDelegate`

### D — Dependency Inversion
**Check**: High-level depends on abstractions, not concrete classes.
- [ ] Property type is a concrete class → use `id<Protocol>`
- [ ] Introducing a new Singleton → can it be replaced with DI (init injection)?
- [ ] Can the dependency be swapped for a mock in unit tests?

**Bad**: `@property MySQLDatabase *database;`
**Good**: `@property id<DatabaseProtocol> database;` + init injection

### Cohesion & Coupling
- [ ] Every method operates on the same set of instance variables (high cohesion)
- [ ] No utility dump classes aggregating unrelated functionality
- [ ] No direct references to concrete classes across module boundaries → use protocols
- [ ] Communication via delegation/notification/block; do not call external objects' methods directly
- [ ] Dependency graph is acyclic (no import cycles)

## Output Format
```
[PRINCIPLE] file:line — violation description.
Refactor: suggested fix.
```

"""#

// source: docs/sample/skills/xcode-build-verify/SKILL.md
private let skillXcodeBuildVerify = #"""
---
name: xcode-build-verify
description: "Activate after code changes in a macOS (Objective-C/Cocoa) project to verify the build compiles cleanly with `xcodebuild`. Must pass with 0 errors before reporting implementation complete."
---

# Xcode Build Verification (macOS)

## Procedure

### Step 0: Identify project and scheme
```bash
xcodebuild -list
```
Use the output to determine the correct `-project` and `-scheme` values for the build command below.

### Step 1: Run the build
```bash
xcodebuild -project [PROJECT].xcodeproj -scheme [SCHEME] -destination 'platform=macOS' build 2>&1 | tail -50
```

### Step 2: Filter the result
```bash
grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

### Step 3: Analyze
- **BUILD SUCCEEDED + 0 errors**: pass. Report to user.
- **New warnings appeared**: review each. If significant, report.
- **BUILD FAILED**: diagnose the error and fix via the 3-option workflow.

## Checklist
- [ ] `xcodebuild` succeeded with 0 errors
- [ ] No newly introduced warnings
- [ ] Changed code matches the project coding style
- [ ] No leftover debug logs or test code

## Output Format
```
Build Verification:
[x] xcodebuild succeeded (0 errors)
[x] No new warnings
[x] Matches project style
[x] No stray logs
Build verification complete
```

## Common macOS/ObjC Error Patterns
- `ARC Semantic Issue`: missing `__bridge` cast or wrong ownership
- `Undeclared identifier`: missing `#import` or `@class` forward declaration
- `No visible @interface`: method not declared in the `.h` file
- `Incompatible pointer types`: wrong collection generic or missing cast

"""#
