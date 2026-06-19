---
name: critic-fix
description: Codex fix prompt rendered from a decision agent FIX-PLAN. Rendered by build_fix_prompt (scripts/lib/critic-helpers.sh); engine-agnostic.
user-invocable: false
---
Fix the following issues found by {agent}. Apply ALL items in the fix plan comprehensively.

Plan: {plan}
Spec reference: {spec_ref}
Review log (evidence): {log}

## Fix plan — address every item below

{fix_plan}

## Evidence rule
Read the exact cited file:line before modifying any file. If the cited excerpt is not present at that line, skip that item.

## Completion
After applying all fixes, output a summary of every change made.
