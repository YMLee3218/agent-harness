# Distribution Models

This bundle supports two deployment paths. Choose one per downstream project — do not mix them.

## git subtree (recommended for teams that customize)

```bash
# Add the bundle as a subtree (run from the downstream project root)
git subtree add --prefix .claude \
  git@github.com:your-org/tdd-vsa-harness.git main --squash

# Update later
git subtree pull --prefix .claude \
  git@github.com:your-org/tdd-vsa-harness.git main --squash
```

**When to use:** Your team needs to fork and modify harness behaviour (custom hooks, critic adjustments, project-specific skills). Local `local-*` files are never touched by subtree pulls; bundle files are updated cleanly.

**Trade-offs:**
- Full history squashed; changes visible in `git log`
- Subtree pull conflicts resolved manually if you've modified bundle files directly
- Suitable for: product teams, monorepos, orgs with compliance requirements

## Plugin marketplace (recommended for teams that want zero maintenance)

```json
// settings.json enabledPlugins
{
  "enabledPlugins": {
    "tdd-vsa@your-marketplace": true
  }
}
```

**When to use:** Your team wants the harness as-is with no modifications. Updates deploy automatically when the marketplace version bumps.

**Trade-offs:**
- No local modifications to bundle files (changes are lost on update)
- Update timing controlled by marketplace publisher, not your team
- Suitable for: teams adopting TDD-VSA without customisation

## Never mix the two

Using both git subtree and marketplace for the same downstream project creates two competing copies of settings, hooks, and skills. Symptoms: duplicate hook fires, conflicting permissions, unpredictable phase-gate behaviour. If you need to switch deployment models, remove one completely before adding the other.

## Local overlay (works with either model)

Regardless of distribution model, use the `local-*` naming convention for project-specific additions — the bundle never creates `local-*` files, so updates are always conflict-free. See `reference/local-overlay.md`.
