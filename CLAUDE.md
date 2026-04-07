한국어로 응답한다.

# 레이어 규칙

VSA + DDD 레이어 정의 및 의존성 규칙 전문: @reference/layers.md

요약:
- `src/features/` — 비즈니스 흐름 오케스트레이션 (domain + infrastructure 호출 가능)
- `src/domain/` — 순수 비즈니스 규칙 (외부 의존성 금지)
- `src/infrastructure/` — 기술 실행 계층 (DB, HTTP, 파일 I/O)

의존성 방향: `features → domain`, `features → infrastructure`, `infrastructure → domain(인터페이스만)`.
`domain`과 `infrastructure`는 `features`를 절대 import하지 않는다. `domain`은 `infrastructure`를 절대 import하지 않는다.

# Commands

- Test: _(run `/initializing-project` to fill this in)_
- Integration test: _(run `/initializing-project` to fill this in)_

# Prerequisites (글로벌 설정)

아래 항목은 **각 개발자의 `~/.claude/settings.json`** 에 설정한다. 번들(`workspace/`)에는 포함되지 않는다.

- **Stop hook** — `afplay /System/Library/Sounds/Glass.aiff` + `~/.claude/hooks/notify-stop.sh`
- **PermissionRequest hook** — `~/.claude/hooks/claude-remote-approver.sh hook`
- **model** — 개인 선호 모델 (예: `opusplan`)
- **skipDangerousModePermissionPrompt** — 머신별 설정

설치 예시:
```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-stop.sh"}]}],
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/claude-remote-approver.sh hook"}]}]
  },
  "model": "opusplan",
  "skipDangerousModePermissionPrompt": true
}
```

# Plan files

피처 작업 상태는 `plans/{feature-slug}.md` 에 보존된다. `/compact` 후에도 phase 복구 가능.

구조:
```
## Vision
## Scenarios
## Test Manifest
## Phase       (brainstorm | spec | red | green | refactor | integration | done)
## Critic Verdicts
## Open Questions
```

# 라이브러리 문서

라이브러리·프레임워크 API는 context7로 확인한다: `/context7-plugin:docs {library-name}`
