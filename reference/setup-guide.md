# Prerequisites — Global Developer Setup

The following belong in **each developer's `~/.claude/settings.json`**, not in the bundle (`workspace/`).

## System dependencies

The harness scripts require `jq` (JSON processor) to be installed:

```bash
# macOS
brew install jq

# Debian/Ubuntu
apt-get install -y jq

# Alpine (CI)
apk add --no-cache jq
```

`jq` is used by `plan-file.sh` (state.json read/write) and `pretooluse-bash.sh` (hook payload parsing). CI images that do not include it will fail silently on hook invocations.

## Stop hook

Plays a sound when Claude finishes a task:
```json
{
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/notify-stop.sh"}]}]
  }
}
```

`notify-stop.sh` example (macOS):
```bash
#!/usr/bin/env bash
afplay /System/Library/Sounds/Glass.aiff
```

## PermissionRequest hook (remote approver)

Allows approving/denying Claude's permission requests via a remote channel:
```json
{
  "hooks": {
    "PermissionRequest": [{"hooks": [{"type": "command", "command": "~/.claude/hooks/claude-remote-approver.sh hook"}]}]
  }
}
```

Install:
```bash
cp workspace/scripts/claude-remote-approver.sh ~/.claude/hooks/claude-remote-approver.sh
chmod +x ~/.claude/hooks/claude-remote-approver.sh
```

The copy in `workspace/scripts/` is the distributable template; the active version must live in `~/.claude/hooks/`.

## Model preference

```json
{
  "model": "opusplan"
}
```

`opusplan` routes planning interactions to Opus 4.6 for deeper reasoning. Use `/plan <description>` to enter plan mode immediately with a task description, or `/model` in-session to switch.

## Other per-machine settings

```json
{
  "skipDangerousModePermissionPrompt": true
}
```

## Full example

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
