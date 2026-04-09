.PHONY: test test-phase-gate test-plan-file test-pretooluse test-post-edit-failure test-integration lint lint-lang eval eval-integration

test: test-phase-gate test-plan-file test-pretooluse test-post-edit-failure

test-phase-gate:
	@echo "=== phase-gate tests ==="
	@bash scripts/tests/phase-gate.test.sh

test-plan-file:
	@echo "=== plan-file tests ==="
	@bash scripts/tests/plan-file.test.sh

test-pretooluse:
	@echo "=== pretooluse-bash tests ==="
	@bash scripts/tests/pretooluse-bash.test.sh

test-post-edit-failure:
	@echo "=== post-edit-failure tests ==="
	@bash scripts/tests/post-edit-failure.test.sh

lint: lint-lang

lint-lang:
	@echo "=== lang-lint: Hangul detection in LLM-facing files ==="
	@bash scripts/lint-lang.sh

test-integration:
	@echo "=== integration eval: end-to-end harness tests ==="
	@bash eval/integration/run-integration-eval.sh

eval:
	@echo "=== critic eval: regression fixtures ==="
	@bash eval/run-eval.sh

eval-integration: test-integration
