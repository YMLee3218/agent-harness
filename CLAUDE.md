Respond to the user in Korean.

# Layer definitions:
- `src/features/` — orchestrates business flows using domain decisions
- `src/domain/` — business rules and decisions; no external dependencies
- `src/infrastructure/` — technical execution (DB, HTTP, file I/O)

# Feature classification:
- Small feature: calls one or a few domains directly; single responsibility
- Large feature: composes small features; never calls domain directly

# Allowed dependencies
- `src/features/` → `src/domain/`, `src/features/` → `src/infrastructure/`, `src/infrastructure/` → `src/domain/` (interface only).
- `src/domain/` and `src/infrastructure/` never import from `src/features/`. `src/domain/` never imports from `src/infrastructure/`.

# Commands
- Test: <project-specific>
- Integration test: <project-specific>

# Prerequisites
번들(`workspace/`)을 downstream `.claude/`로 복사한 뒤 아래 외부 의존성을 별도로 설치해야 합니다.

- `~/.claude/hooks/notify-stop.sh` — Stop hook용 알림 스크립트 (번들 외부, 각 개발자 머신에 직접 설치)
- `~/.claude/statusline.sh` — 상태바 스크립트 (번들 외부)
- `claude-remote-approver` npm 패키지 — PermissionRequest hook이 호출하는 원격 승인 서버. `mise node@lts` 환경에서 설치 필요 (`npm i -g claude-remote-approver` 또는 프로젝트 지정 방식).

위 항목이 누락된 경우 해당 hook은 오류 없이 스킵되거나 silent fail합니다. Stop hook의 `notify-stop.sh` 는 `command -v` 로 존재 여부를 확인한 뒤 호출하는 방식으로 optional 처리를 권장합니다.
