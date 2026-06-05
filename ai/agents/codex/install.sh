#!/bin/bash
# o2-datasource / ai / agents / codex / install.sh
#
# Configures Codex CLI to export OpenTelemetry traces to OpenObserve.
#
# Mechanism (per the project brief — verify against current Codex docs before
# distributing): Codex supports native OTLP export via standard OTEL_EXPORTER_*
# environment variables. This installer writes them into ~/.codex/config.toml
# under an [otel] section so they apply to every Codex run.
#
# IF Codex's actual schema differs from what's assumed here, the user-facing
# behavior is: file gets written, env vars don't take effect. Easy to spot.
#
# Usage:
#   curl -fsSL .../agents/codex/install.sh | bash -s -- \
#     --url=... --org=... --token="Basic ..."

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai}"

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
        printf "✗ Failed to fetch lib/common.sh from %s\n" "$REPO_RAW" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1090
source "$COMMON_SH"

O2_URL=""
O2_ORG=""
O2_TOKEN=""
SCOPE="global"
DRY_RUN=0

usage() {
    cat <<EOF
Codex -> OpenObserve installer

Usage:
    $0 [OPTIONS]

Required:
    --url=URL             OpenObserve instance URL
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
    --scope=SCOPE         "global" (~/.codex/config.toml) — only supported value
    --dry-run             Validate config, no changes
    --quiet               Suppress info logs
    --help                Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --url=*)     O2_URL="${arg#*=}" ;;
        --org=*)     O2_ORG="${arg#*=}" ;;
        --token=*)   O2_TOKEN="${arg#*=}" ;;
        --scope=*)   SCOPE="${arg#*=}" ;;
        --quiet)     O2_QUIET=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --help|-h)   usage; exit 0 ;;
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

case "$SCOPE" in
    global) ;;
    project)
        print_error "--scope=project not yet supported for Codex (no per-project config path is documented)."
        exit 1
        ;;
    *) print_error "Invalid --scope=$SCOPE. Use 'global'."; exit 1 ;;
esac

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

PY="$(detect_python)" || {
    print_error "Python 3.9+ not found on PATH (needed for TOML merge)."
    exit 1
}

CODEX_DIR="$HOME/.codex"
CONFIG_FILE="$CODEX_DIR/config.toml"

# Codex 0.135+ emits OTel LOGS + METRICS (no traces in exec mode). Its
# `endpoint` field is literal — there is no per-signal endpoint override and
# codex does NOT auto-append /v1/{signal}. So all signals POST to the
# configured endpoint. We point it at /v1/logs since logs carry the useful
# per-request data (model, prompt, response). Metrics will 404 to /v1/logs
# (silent, acceptable loss for now). Traces aren't emitted at all.
OTLP_ENDPOINT="$O2_URL/api/$O2_ORG/v1/logs"

print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Config file: $CONFIG_FILE"
print_info "OTLP endpoint: $OTLP_ENDPOINT"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

print_step "1/2" "Merging OTel settings into $CONFIG_FILE..."
mkdir -p "$CODEX_DIR"

if [ -f "$CONFIG_FILE" ]; then
    backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing config to $backup"
fi

# We intentionally do a line-oriented merge (not full TOML re-emit) so user
# comments and non-managed sections survive untouched. The managed section
# is delimited by sentinels so we can rewrite it in place on re-runs.
O2_CONFIG="$CONFIG_FILE" \
O2_ENDPOINT="$OTLP_ENDPOINT" \
O2_TOKEN_VAL="$O2_TOKEN" \
O2_ORG_VAL="$O2_ORG" \
"$PY" - <<'PY'
import os, pathlib, tempfile

path = pathlib.Path(os.environ["O2_CONFIG"])
endpoint = os.environ["O2_ENDPOINT"]
token = os.environ["O2_TOKEN_VAL"]
org = os.environ["O2_ORG_VAL"]

START = "# >>> openobserve-otel >>>"
END   = "# <<< openobserve-otel <<<"

# Codex 0.135+ config schema for OTLP HTTP export:
#   [otel.exporter.otlp-http]
#   protocol = "binary"    # protobuf — "json" is also valid
#   endpoint = "..."
#   headers = { ... }      # inline TOML table, not a string
def toml_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')

headers_inline = ", ".join([
    f'Authorization = "{toml_escape(token)}"',
    f'organization = "{toml_escape(org)}"',
    'stream-name = "default"',
])

block_lines = [
    START,
    "[otel.exporter.otlp-http]",
    'protocol = "binary"',
    f'endpoint = "{toml_escape(endpoint)}"',
    f"headers = {{ {headers_inline} }}",
    END,
]
block = "\n".join(block_lines) + "\n"

existing = ""
if path.exists():
    existing = path.read_text(encoding="utf-8")

if START in existing and END in existing:
    pre, _, rest = existing.partition(START)
    _, _, post = rest.partition(END)
    # strip trailing newline left after our END sentinel
    post = post.lstrip("\n")
    new = pre.rstrip() + ("\n\n" if pre.strip() else "") + block + ("\n" + post if post.strip() else "")
else:
    sep = "\n\n" if existing.strip() else ""
    new = existing.rstrip() + sep + block

d = path.parent
d.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix="config.", suffix=".tmp", dir=str(d))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new if new.endswith("\n") else new + "\n")
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
print_success "$CONFIG_FILE updated."

print_step "2/2" "Done. Next steps:"
cat <<EOF

  Config file:    $CONFIG_FILE
  OTLP endpoint:  $OTLP_ENDPOINT

Verify it's working:

  1. Run any Codex command.
  2. In OpenObserve, open Traces and filter by service.name=codex (or whatever
     value Codex emits — check the resource attributes if absent).

Uninstall:

  curl -fsSL $REPO_RAW/agents/codex/uninstall.sh | bash

EOF

trap - ERR INT TERM
exit 0
