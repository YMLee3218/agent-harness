---
name: critic-pass-audit
description: Minimal REJECT-PASS convergence check for a 2nd consecutive PASS. Rendered by build_pass_audit_prompt (scripts/lib/critic-helpers.sh); engine-agnostic.
user-invocable: false
---
Perform the PASS convergence check for {agent}.

Review log: {log}
{spec_line}

Read the review log and spec. Apply:
2. Coverage gaps: Read the spec. Is every Scenario and Scenario Outline addressed in the review?
   List any scenario the reviewer did not examine.
4. PASS comprehensiveness: is this PASS a genuine clean slate, or did the reviewer skip angles?

Be conservative — only reject if there is a clearly unreviewed scenario or skipped angle.

Output exactly one of:
VERDICT: ACCEPT
or
VERDICT: REJECT-PASS — {one-sentence description of the unreviewed scenario or skipped angle}
