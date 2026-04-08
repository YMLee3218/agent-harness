# Eval Harness

Regression fixtures for critic skills. Run after any change to critic body files, skills, or model routing.

```bash
make -C .. eval
# or:
bash run-eval.sh
```

## Structure

```
fixtures/   — input documents fed to each critic skill
expected/   — expected verdict (PASS or FAIL) for each fixture
run-eval.sh — invokes critics via `claude -p`, extracts verdict, diffs against expected
```

Fixture naming: `{critic}-{good|bad}-{slug}.md` / `.verdict`.

## Model upgrade checklist

Run this checklist when switching critic models (e.g. Haiku 4.5 → Haiku 5, or Sonnet tier bump).

### 1. Critic body few-shot re-calibration
- Re-run `make eval` against the new model.
- If any fixture flips (PASS→FAIL or FAIL→PASS unexpectedly), inspect the verdict output.
- Update calibration examples in `reference/critic-{feature,spec,test,code}-body.md` if the new model interprets the rubric differently.
- Target: all 8 fixtures green before promoting the new model to production.

### 2. Phase-gate keyword necessity re-evaluation
- The `phase-gate.sh` prompt mode currently injects a phase-reminder (non-blocking) in brainstorm/spec phases.
- With stronger models, evaluate whether the reminder is still needed or causes noise.
- Adjust or remove if the model correctly self-enforces phase discipline without the hint.

### 3. `running-dev-cycle` token budget re-measurement
- Profile token usage per phase for each profile (trivial / patch / feature / greenfield).
- Update model routing in `reference/rationale.md` model routing table if cost/quality balance shifts.
- Haiku is currently used for pattern-classification critics; re-evaluate if Haiku error rate rises above ~5% on the fixture suite.

### 4. Consecutive-FAIL threshold
- The harness blocks after 2 consecutive same-category FAILs (`plan-file.sh record-verdict`).
- With a more capable model, consider whether 1 iteration is sufficient for simple critics.
- Do not change the threshold without re-running the full eval suite + manual spot checks.
