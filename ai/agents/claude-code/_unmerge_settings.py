#!/usr/bin/env python3
"""
Strip the OpenObserve telemetry config from a Claude Code settings.json
(or settings.local.json).

Reads the settings file path from stdin (one line).

Removes the managed native OTLP env keys this integration writes, plus any
leftover keys / `Stop` hook from the older hook-based flow. If `env` or
`hooks.Stop` becomes empty it is removed entirely, so no dead keys are left
behind. Other top-level keys (permissions, anything not ours) are untouched.

Note: the OTEL_* keys are treated as managed by this integration (the
installer overwrites them), so uninstall removes them. If you point Claude
Code at another OTLP backend after uninstalling, re-set those vars.
"""
import json
import os
import pathlib
import sys
import tempfile


LEGACY_HOOK_FILENAME = "openobserve_hooks.py"
MANAGED_ENV_KEYS = (
    # native OTLP telemetry (current flow)
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA",
    "OTEL_METRICS_EXPORTER",
    "OTEL_LOGS_EXPORTER",
    "OTEL_TRACES_EXPORTER",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_ENDPOINT",
    "OTEL_EXPORTER_OTLP_HEADERS",
    # legacy hook-based flow
    "TRACE_TO_OPENOBSERVE",
    "OPENOBSERVE_URL",
    "OPENOBSERVE_ORG",
    "OPENOBSERVE_AUTH_TOKEN",
    "OPENOBSERVE_TRACES_STREAM_NAME",
)


def main() -> int:
    try:
        path = pathlib.Path(sys.stdin.readline().rstrip("\n"))
    except Exception as e:
        print(f"Failed to read settings path from stdin: {e}", file=sys.stderr)
        return 2

    if not path.name or not path.exists() or path.stat().st_size == 0:
        return 0

    try:
        settings = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(f"Existing settings not valid JSON: {path}", file=sys.stderr)
        return 1
    if not isinstance(settings, dict):
        return 0

    # Strip our env vars (native + legacy).
    env = settings.get("env")
    if isinstance(env, dict):
        for k in MANAGED_ENV_KEYS:
            env.pop(k, None)
        if env:
            settings["env"] = env
        else:
            settings.pop("env", None)

    # Strip any legacy Stop-hook entries that point at openobserve_hooks.py.
    hooks = settings.get("hooks")
    if isinstance(hooks, dict):
        stop_groups = hooks.get("Stop")
        if isinstance(stop_groups, list):
            new_groups = []
            for grp in stop_groups:
                if not isinstance(grp, dict):
                    new_groups.append(grp)
                    continue
                inner = grp.get("hooks")
                if not isinstance(inner, list):
                    new_groups.append(grp)
                    continue
                new_inner = []
                for h in inner:
                    if not isinstance(h, dict) or h.get("type") != "command":
                        new_inner.append(h)
                        continue
                    cmd = h.get("command", "")
                    if isinstance(cmd, str) and cmd.endswith(LEGACY_HOOK_FILENAME):
                        # Drop this entry.
                        continue
                    new_inner.append(h)
                if new_inner:
                    grp["hooks"] = new_inner
                    new_groups.append(grp)
            if new_groups:
                hooks["Stop"] = new_groups
            else:
                hooks.pop("Stop", None)
        if hooks:
            settings["hooks"] = hooks
        else:
            settings.pop("hooks", None)

    # Atomic write.
    d = path.parent
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
