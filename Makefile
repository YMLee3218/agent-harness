.PHONY: test test-phase-gate test-plan-file test-pretooluse lint lint-lang

test: test-phase-gate test-plan-file test-pretooluse

test-phase-gate:
	@echo "=== phase-gate tests ==="
	@bash scripts/tests/phase-gate.test.sh

test-plan-file:
	@echo "=== plan-file tests ==="
	@bash scripts/tests/plan-file.test.sh

test-pretooluse:
	@echo "=== pretooluse-bash tests ==="
	@bash scripts/tests/pretooluse-bash.test.sh

lint: lint-lang

lint-lang:
	@echo "=== lang-lint: Hangul detection in LLM-facing files ==="
	@bash scripts/lint-lang.sh
