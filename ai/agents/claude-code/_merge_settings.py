#!/usr/bin/env python3
"""
Merge Claude Code's native OpenTelemetry env vars into a Claude Code
settings.json (or settings.local.json) so it exports metrics, events, and
(beta) traces to OpenObserve over OTLP — no hook, no SDK.

Reads config from stdin — one value per line, in this order:

    1. settings file path     e.g. /Users/me/.claude/settings.json
    2. OpenObserve base URL   e.g. https://api.openobserve.ai
    3. OpenObserve org        e.g. default
    4. Auth header value      e.g. "Basic <base64>" or "Bearer <token>"
    5. Stream name (optional) e.g. claude_code  (blank/omitted -> default)

Stdin is used (rather than env vars or argv) so the auth token never appears
in `ps` output or any subprocess environment block.

Behavior:
  - Adds/updates only the managed CLAUDE_CODE_* and OTEL_* keys in `env`.
    Every other env key is preserved.
  - Migrates older installs: removes the legacy custom env vars
    (TRACE_TO_OPENOBSERVE, OPENOBSERVE_*) and the legacy `Stop` hook that
    pointed at openobserve_hooks.py, so re-running cleans up the old flow.
  - All other top-level keys (permissions, etc.) are left untouched.
  - Write is atomic: tempfile + os.replace.
"""
import json
import os
import pathlib
import sys
import tempfile


LEGACY_HOOK_FILENAME = "openobserve_hooks.py"
LEGACY_ENV_KEYS = (
    "TRACE_TO_OPENOBSERVE",
    "OPENOBSERVE_URL",
    "OPENOBSERVE_ORG",
    "OPENOBSERVE_AUTH_TOKEN",
    "OPENOBSERVE_TRACES_STREAM_NAME",
)


def main() -> int:
    try:
        path = pathlib.Path(sys.stdin.readline().rstrip("\n"))
        url = sys.stdin.readline().rstrip("\n")
        org = sys.stdin.readline().rstrip("\n")
        token = sys.stdin.readline().rstrip("\n")
        # Optional 5th line. Blank or omitted (EOF -> "") falls back to the
        # `default` stream so older callers and "just press enter" both work.
        stream = sys.stdin.readline().rstrip("\n") or "default"
    except Exception as e:
        print(f"Failed to read config from stdin: {e}", file=sys.stderr)
        return 2

    if not path.name or not url or not org or not token:
        print("Missing required input on stdin (path, url, org, or token).", file=sys.stderr)
        return 2

    # OpenObserve OTLP base endpoint. The OTel SDK appends /v1/metrics,
    # /v1/logs, and /v1/traces itself, so this must NOT end in a slash.
    endpoint = f"{url.rstrip('/')}/api/{org}"
    managed_env = {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA": "1",
        "OTEL_METRICS_EXPORTER": "otlp",
        "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_TRACES_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
        "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
        # stream-name routes OpenObserve's OTLP logs + traces into the chosen
        # stream (defaults to `default`; set a dedicated stream to isolate
        # Claude Code's telemetry). One header covers logs AND traces; the
        # card's detection still matches via service_name = 'claude-code'.
        # Metric streams are named per-metric (claude_code_*) and are
        # unaffected by this header.
        "OTEL_EXPORTER_OTLP_HEADERS": f"Authorization={token},stream-name={stream}",
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

    # Merge env: drop legacy keys, then add/update the managed keys. Anything
    # the user set that we don't manage is preserved.
    env = settings.get("env")
    if not isinstance(env, dict):
        env = {}
    for k in LEGACY_ENV_KEYS:
        env.pop(k, None)
    env.update(managed_env)
    settings["env"] = env

    # Migrate: strip the legacy Stop hook that pointed at openobserve_hooks.py
    # (matched by filename suffix). Native telemetry replaces it entirely.
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
                new_inner = [
                    h for h in inner
                    if not (
                        isinstance(h, dict)
                        and h.get("type") == "command"
                        and isinstance(h.get("command"), str)
                        and h["command"].endswith(LEGACY_HOOK_FILENAME)
                    )
                ]
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
