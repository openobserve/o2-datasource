#!/usr/bin/env python3
"""
Merge the OpenObserve Stop hook + env vars into a Claude Code settings.json
(or settings.local.json) file.

Reads config from stdin — one value per line, in this order:

    1. settings file path           e.g. /Users/me/.claude/settings.json
    2. hook command string          e.g. "python3.11 /Users/me/.claude/hooks/openobserve_hooks.py"
    3. OPENOBSERVE_URL value
    4. OPENOBSERVE_ORG value
    5. OPENOBSERVE_AUTH_TOKEN value

Stdin is used (rather than env vars or argv) so the auth token never appears
in `ps` output or any subprocess environment block.

Behavior:
  - Existing env block: only the four managed keys are added/updated. All
    other keys preserved.
  - Existing hooks.Stop block: if any entry's command ends with
    `openobserve_hooks.py`, its `command` is updated in place (so a Python
    interpreter change between installs doesn't create duplicates). If no
    such entry exists, a new one is appended.
  - All other top-level keys (permissions, etc.) are left untouched.
  - Write is atomic: tempfile + os.replace.
"""
import json
import os
import pathlib
import sys
import tempfile


HOOK_FILENAME = "openobserve_hooks.py"


def main() -> int:
    try:
        path = pathlib.Path(sys.stdin.readline().rstrip("\n"))
        hook_cmd = sys.stdin.readline().rstrip("\n")
        url = sys.stdin.readline().rstrip("\n")
        org = sys.stdin.readline().rstrip("\n")
        token = sys.stdin.readline().rstrip("\n")
    except Exception as e:
        print(f"Failed to read config from stdin: {e}", file=sys.stderr)
        return 2

    if not path or not hook_cmd:
        print("Missing required input on stdin (path or hook_cmd).", file=sys.stderr)
        return 2

    managed_env = {
        "TRACE_TO_OPENOBSERVE": "true",
        "OPENOBSERVE_URL": url,
        "OPENOBSERVE_ORG": org,
        "OPENOBSERVE_AUTH_TOKEN": token,
    }

    settings = {}
    if path.exists() and path.stat().st_size > 0:
        try:
            settings = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"Existing settings file is not valid JSON: {path}", file=sys.stderr)
            return 1
        if not isinstance(settings, dict):
            print(f"Existing settings file root is not an object: {path}", file=sys.stderr)
            return 1

    # Merge env (only touches the four managed keys).
    env = settings.get("env")
    if not isinstance(env, dict):
        env = {}
    env.update(managed_env)
    settings["env"] = env

    # Merge hooks.Stop[*].hooks[*]. Match by filename suffix and update in
    # place so changing the Python interpreter between installs doesn't
    # create duplicate Stop hook entries.
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    stop_groups = hooks.get("Stop")
    if not isinstance(stop_groups, list):
        stop_groups = []

    already = False
    for grp in stop_groups:
        if not isinstance(grp, dict):
            continue
        inner = grp.get("hooks")
        if not isinstance(inner, list):
            continue
        for h in inner:
            if not isinstance(h, dict) or h.get("type") != "command":
                continue
            cmd = h.get("command", "")
            if isinstance(cmd, str) and cmd.endswith(HOOK_FILENAME):
                # Update in place — this also normalizes the interpreter prefix.
                h["command"] = hook_cmd
                already = True
                break
        if already:
            break

    if not already:
        stop_groups.append({
            "hooks": [
                {"type": "command", "command": hook_cmd}
            ]
        })

    hooks["Stop"] = stop_groups
    settings["hooks"] = hooks

    # Atomic write.
    d = path.parent
    d.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="settings.", suffix=".tmp", dir=str(d))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(settings, f, indent=2, sort_keys=False)
            f.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise

    return 0


if __name__ == "__main__":
    sys.exit(main())
