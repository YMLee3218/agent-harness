# Blocked Guidance

When a dev-cycle or integration-test skill surfaces a `[BLOCKED:{kind}]` marker,
follow this protocol exactly — in Korean.

---

## Presentation format

1. **마커 출력** — 원문 그대로 verbatim 인용
2. **블록 설명** — 한국어 1문장: 이 kind가 무엇을 의미하는지, 어디를 수정해야 하는지
3. **해결 경로** — 한국어로 권장 경로(근본 원인 수정) 먼저, 임시 우회 경로 나중
4. **결정이 필요한 경우** — `AskUserQuestion`으로 선택지 제시 (스펙 모호, 근본 원인 불분명 등)

> 출력 언어: 이 가이드에 따른 모든 사용자 대면 응답은 **한국어**로 작성한다.
> `language.md`의 "Default: Korean" 규칙이 verbatim 마커 출력 이후의 설명·선택지·권장 모두에 적용된다.

---

## 블록 종류별 안내

| Kind | 의미 | 권장 해결 (root-cause first) | 비권장 패턴 |
|------|------|------------------------------|------------|
| `envelope` | 스펙의 Operating Envelope 범위가 잘못 선언됨 | 1. Envelope 섹션을 올바르게 수정 → 2. `unblock` | Envelope 수정 없이 `unblock`만 실행 |
| `docs` | 문서 vs 스펙/테스트 간 Ground truth 모순 | 1. 문서·스펙·테스트 중 올바른 것 결정(cascade) → 2. 수정 → 3. `unblock` | 모순 원인 파악 없이 `unblock`만 실행 |
| `spec` | 스펙 갭 또는 모호함 — 인간의 결정 필요 | 1. 모호한 스펙 항목을 명확히 작성 → 2. `unblock` | 스펙을 그대로 두고 `unblock`만 실행 |
| `code` | 코드 또는 테스트의 근본 원인 버그 | 1. 코드/테스트의 실제 결함 수정 → 2. `unblock` | 코드 검토 없이 `unblock`만 실행 |
| `env` | 환경/세션/도구 문제 (persistent 또는 반복) | 1. 누락된 도구 설치 또는 환경 수정 → 2. `unblock` | 환경 미수정 후 `unblock`으로 우회 |
| `harness` | 하네스 호출 경로, 사이드카 무결성, 또는 참조 데이터 확장 | 1. 하네스 파일 또는 참조 enum 수정 → 2. `unblock` | 하네스 수정 없이 `unblock`만 실행 |
| `ceiling` | 크리틱 루프 상한 초과 — 반복 실패 수정 필요 | 1. 반복 실패의 근본 원인 수정 → 2. `reset-milestone {agent}` | 수정 없이 `reset-milestone`만 실행; `unblock` 단독 실행(`milestone_seq` 미증가로 즉시 재차단) |
| `transient` | ⚠️ plan.md에 나타나면 잘못 기록된 것 — 하네스 자동 처리 대상 | 마커가 plan.md에 있으면 `unblock` 대신 하네스 담당자에게 알림 | `unblock`으로 제거 시도 (의도적으로 지원 안 됨) |

---

## Recommendation policy — scope-bias 금지

> **핵심**: 추천 기준은 **수정 범위의 크기가 아니라 올바른 방향인지 여부**다.

선택지 A(근본 원인 수정, 범위 클 수 있음)와 선택지 B(임시 우회, 범위 작음)가 있을 때:

- **A를 권장**한다.
- B는 **"임시 방편 — 기술 부채 발생, 추후 A 수준의 수정 필요"** 레이블을 붙여 선택지로만 제시한다.
- "수정 범위가 작다", "빠르다", "지금 당장 해결된다"는 것은 **권장 이유가 될 수 없다**.

### 금지 패턴 (예시)

| 상황 | 잘못된 권장 | 올바른 권장 |
|------|------------|------------|
| `[BLOCKED:ceiling]` 발생 | "`reset-milestone`만 실행하면 됩니다" | "크리틱이 반복 실패한 근본 원인을 수정한 뒤 `reset-milestone`을 실행하세요" |
| `[BLOCKED:code]` 발생 | "`unblock`을 실행해 넘어가세요" | "코드 버그를 수정한 뒤 `unblock`을 실행하세요" |
| `[BLOCKED:spec]` 발생 | "일단 `unblock`하고 다음 단계로 가세요" | "모호한 스펙 항목을 먼저 명확히 한 뒤 `unblock`을 실행하세요" |

---

## Anti-avoidance rule

`unblock` 및 `reset-milestone`은 **근본 원인 수정 이후 실행하는 후속 명령**이다.
이슈를 검토하지 않고 이 명령들만 실행하는 것은 비권장이며, 선택지로 제시할 때
반드시 "임시 방편" 레이블을 붙여야 한다.

```
권장 순서: [원인 파악] → [수정] → [unblock 또는 reset-milestone]
비권장:    [unblock 또는 reset-milestone] (수정 없이 즉시 실행)
```

후속 명령 참조: `@reference/markers.md §Clearing stop markers`
