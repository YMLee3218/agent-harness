---
name: critic-decision
description: Claude decision/audit prompt for a critic FAIL verdict. Rendered by build_decision_prompt (scripts/lib/critic-helpers.sh); engine-agnostic.
user-invocable: false
---
ultrathink

Perform a comprehensive verdict audit for a FAIL verdict from {agent}.

Review log: {log}
{spec_line}
{docs_line}

Apply all 6 §Audit checklist items:
1. For each blocking finding in the Citation Summary: Read the cited file:line. Excerpt absent → FALSE-POSITIVE. [MISSING]: Read the spec, search for scenario keywords; found → FALSE-POSITIVE.
2. Coverage gaps: Read the spec. Are there Scenarios/Scenario Outlines the review did not address?
3. Fix direction: does the proposed fix target the root cause?
4. False positive/negative risk.
5. Category accuracy — does `<!-- category: X -->` use the highest-priority enum value present (ENVELOPE_MISMATCH > PROPAGATED_VALUE_OUT_OF_SYNC > ENVELOPE_OVERREACH > LAYER_VIOLATION > CROSS_FEATURE_CONTRADICTION > DOCS_CONTRADICTION > UNVERIFIED_CLAIM > SPEC_COMPLIANCE > MISSING_SCENARIO > TEST_INTEGRITY > TEST_QUALITY > SECURITY > LOGIC_ROBUSTNESS > MODULARITY > TYPE_DESIGN > PERFORMANCE > DUPLICATION > ANALYSABILITY > STRUCTURAL)?
6. Per-finding classification:
   - GENUINE: cited excerpt IS present at file:line AND fix direction is determinable from the reviewed files (spec, docs, review log)
   - FALSE-POSITIVE: (a) excerpt absent from cited file:line, OR (b) [MISSING] finding whose scenario keywords are confirmed present in the spec
   - AMBIGUOUS: excerpt present and finding real, but correct fix requires evidence NOT available in the reviewed files — use BLOCKED-AMBIGUOUS

Output (shell-parsed exactly):
AUDIT: ACCEPT
GENUINE: [F1: tag + description, or "none"]
FALSE-POSITIVE: [F2: reason, or "none"]
FIX-PLAN:
  - file: {path}, change: {concrete description}

Special cases:
- All FALSE-POSITIVE → AUDIT: ACCEPT-OVERRIDE, omit FIX-PLAN.
- Any AMBIGUOUS → AUDIT: BLOCKED-AMBIGUOUS; FIX-PLAN for GENUINE only; add per AMBIGUOUS:
  [BLOCKED:spec] {agent}: ambiguous — {one-sentence human question}
  Exception — DOCS_CONTRADICTION finding where docs may be stale and fix direction is unclear: emit instead:
  [BLOCKED:docs] {agent}: contradiction — docs may be stale, ground truth ambiguous; apply cascade
