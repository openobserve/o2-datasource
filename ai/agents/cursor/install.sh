#!/bin/bash
# o2-datasource / ai / agents / cursor / install.sh
#
# Configures Cursor IDE to export agent telemetry to OpenObserve.
#
# Mechanism: Cursor has a native hooks system. The third-party tool
# `cursor-otel-hook` (LangGuard-AI) registers as a Cursor hook and emits
# OTLP traces for sessionStart, sessionEnd, preToolUse, postToolUse, etc.
# Upstream: https://github.com/LangGuard-AI/cursor-otel-hook
#
# This installer:
#   1) Bootstraps cursor-otel-hook by fetching+running its upstream setup.sh
#      (skip with --skip-bootstrap if you've already done that).
#   2) Overwrites ~/.cursor/hooks/otel_config.json with OpenObserve values.
#
# Requires: python3 (for JSON merge). Bootstrap requires: curl + bash.
#
# Usage:
#   curl -fsSL .../agents/cursor/install.sh | bash -s -- \
#     --url=... --org=... --token="Basic ..."

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/LangGuard-AI/cursor-otel-hook}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"

_self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

COMMON_SH=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/../../lib/common.sh" ]; then
    COMMON_SH="$_self_dir/../../lib/common.sh"
else
    COMMON_SH="$(mktemp)"
    trap 'rm -f "$COMMON_SH"' EXIT
    if ! curl -fsSL "$REPO_RAW/lib/common.sh" -o "$COMMON_SH"; then
        printf "✗ Failed to fetch lib/common.sh\n" >&2; exit 1
    fi
fi
# shellcheck disable=SC1090
source "$COMMON_SH"

O2_URL=""
O2_ORG=""
O2_TOKEN=""
O2_TRACES_STREAM=""
DRY_RUN=0
SKIP_BOOTSTRAP=0

usage() {
    cat <<EOF
Cursor -> OpenObserve installer

Usage:
    $0 [OPTIONS]

Required:
    --url=URL             OpenObserve instance URL
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
    --traces-stream=NAME  OpenObserve stream name for traces (default: OpenObserve default)
    --skip-bootstrap      Skip the upstream cursor-otel-hook setup
                          (use when the binary + Cursor hook events are
                          already registered)
    --upstream-repo=URL   Override upstream repo URL
    --upstream-ref=REF    Override upstream branch/tag
    --dry-run             Validate config + print plan, no changes
    --quiet               Suppress info logs
    --help                Show this help

Notes:
    Cursor's hooks system is configured in ~/.cursor/hooks.json with hook
    binaries/scripts placed in ~/.cursor/hooks/. The upstream installer
    registers cursor-otel-hook with Cursor; this installer then points it at
    OpenObserve by writing otel_config.json on top.
EOF
}

for arg in "$@"; do
    case $arg in
        --url=*)             O2_URL="${arg#*=}" ;;
        --org=*)             O2_ORG="${arg#*=}" ;;
        --token=*)           O2_TOKEN="${arg#*=}" ;;
        --traces-stream=*)   O2_TRACES_STREAM="${arg#*=}" ;;
        --skip-bootstrap)    SKIP_BOOTSTRAP=1 ;;
        --upstream-repo=*)   UPSTREAM_REPO="${arg#*=}" ;;
        --upstream-ref=*)    UPSTREAM_REF="${arg#*=}" ;;
        --dry-run)           DRY_RUN=1 ;;
        --quiet)             O2_QUIET=1 ;;
        --help|-h)           usage; exit 0 ;;
        *) print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

missing=()
[ -z "$O2_URL" ]   && missing+=("--url")
[ -z "$O2_ORG" ]   && missing+=("--org")
[ -z "$O2_TOKEN" ] && missing+=("--token")
if (( ${#missing[@]} > 0 )); then
    print_error "Missing required flag(s): ${missing[*]}"
    usage; exit 1
fi

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"; exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

PY="$(detect_python)" || { print_error "Python 3.9+ not found."; exit 1; }

CURSOR_DIR="$HOME/.cursor"
HOOKS_DIR="$CURSOR_DIR/hooks"
HOOKS_REGISTRY="$CURSOR_DIR/hooks.json"
OTEL_CONFIG="$HOOKS_DIR/otel_config.json"
TRACES_ENDPOINT="$O2_URL/api/$O2_ORG/v1/traces"

print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
[ -n "$O2_TRACES_STREAM" ] && print_info "Traces stream: $O2_TRACES_STREAM"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Cursor hooks dir: $HOOKS_DIR"
print_info "OTel config: $OTEL_CONFIG"
print_info "Traces endpoint: $TRACES_ENDPOINT"
print_info "Skip upstream bootstrap: $SKIP_BOOTSTRAP"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

# ── Step 1: Bootstrap upstream cursor-otel-hook (binary + Cursor registration)
if (( SKIP_BOOTSTRAP == 1 )); then
    print_step "1/2" "Skipping upstream bootstrap (--skip-bootstrap)"
    if [ ! -d "$HOOKS_DIR" ]; then
        print_error "$HOOKS_DIR does not exist. Remove --skip-bootstrap or install upstream first:"
        print_info "  $UPSTREAM_REPO"
        exit 1
    fi
else
    print_step "1/2" "Running upstream cursor-otel-hook setup.sh..."
    SETUP_TMP="$(mktemp)"
    TEMP_FILES+=("$SETUP_TMP")
    # Map UPSTREAM_REPO -> raw url for setup.sh
    raw_base="$(printf '%s' "$UPSTREAM_REPO" | sed -E 's#^https?://github.com/#https://raw.githubusercontent.com/#; s#\.git$##')"
    setup_url="$raw_base/$UPSTREAM_REF/setup.sh"
    if ! retry_command curl -fsSL "$setup_url" -o "$SETUP_TMP"; then
        print_error "Failed to fetch $setup_url"
        print_info "Run install upstream manually, then re-run with --skip-bootstrap:"
        print_info "  $UPSTREAM_REPO"
        exit 1
    fi
    bash "$SETUP_TMP"
    RESOURCES_CREATED+=("upstream-bootstrap: cursor-otel-hook")
    print_success "Upstream bootstrap completed."
fi

# ── Step 2: Write/merge otel_config.json with OpenObserve values ─────────────
print_step "2/2" "Writing $OTEL_CONFIG with OpenObserve values..."
mkdir -p "$HOOKS_DIR"

if [ -f "$OTEL_CONFIG" ]; then
    backup="${OTEL_CONFIG}.bak.$(date +%s)"
    cp "$OTEL_CONFIG" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing otel_config.json to $backup"
fi

O2_OTEL_CFG="$OTEL_CONFIG" \
O2_ENDPOINT="$TRACES_ENDPOINT" \
O2_TOKEN_VAL="$O2_TOKEN" \
O2_TRACES_STREAM_VAL="$O2_TRACES_STREAM" \
"$PY" - <<'PY'
import json, os, pathlib, tempfile
path = pathlib.Path(os.environ["O2_OTEL_CFG"])
endpoint = os.environ["O2_ENDPOINT"]
token = os.environ["O2_TOKEN_VAL"]
traces_stream = os.environ["O2_TRACES_STREAM_VAL"]

cfg = {}
if path.exists() and path.stat().st_size > 0:
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        cfg = {}
    if not isinstance(cfg, dict):
        cfg = {}

headers = f"Authorization={token}"
if traces_stream:
    headers += f",stream-name={traces_stream}"

# Managed keys — overwrite. Non-managed keys (e.g. CURSOR_OTEL_MASK_PROMPTS)
# are preserved.
managed = {
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": endpoint,
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_HEADERS": headers,
    "OTEL_SERVICE_NAME": "cursor",
}
for k, v in managed.items():
    cfg[k] = v

d = path.parent
d.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix="otel_config.", suffix=".tmp", dir=str(d))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=False); f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
print_success "$OTEL_CONFIG written."

cat <<EOF

Done.

  Hooks dir:       $HOOKS_DIR
  OTel config:     $OTEL_CONFIG
  Hooks registry:  $HOOKS_REGISTRY (managed by upstream cursor-otel-hook)
  Traces target:   $TRACES_ENDPOINT

Verify:

  1. Restart Cursor (so it re-reads hooks.json).
  2. Run any agent task. tail -f ~/.cursor/hooks/cursor_otel_hook.log
  3. In OpenObserve, open Traces and filter by service.name=cursor.

Uninstall:

  curl -fsSL $REPO_RAW/agents/cursor/uninstall.sh | bash

EOF

trap - ERR INT TERM
exit 0
