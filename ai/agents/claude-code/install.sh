#!/bin/bash
# o2-datasource / ai / agents / claude-code / install.sh
#
# Points Claude Code at OpenObserve using Claude Code's native OpenTelemetry
# support. Writes the CLAUDE_CODE_* + OTEL_* env vars into Claude Code's
# settings.json so every session exports metrics, events, and (beta) traces
# to OpenObserve over OTLP. No hook, no SDK, no code changes.
#
# Reference: https://openobserve.ai/docs/integration/ai/claude-code-tracing/
#
# Usage (curl|bash):
#   curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/agents/claude-code/install.sh | \
#     bash -s -- \
#       --url=https://api.openobserve.ai \
#       --org=default \
#       --token="Basic <base64>" \
#       --scope=global

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai}"

# ── Source lib/common.sh (local checkout or curl) ────────────────────────────
_self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

COMMON_SH=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/../../lib/common.sh" ]; then
    COMMON_SH="$_self_dir/../../lib/common.sh"
else
    COMMON_SH="$(mktemp)"
    # Pre-source trap to clean COMMON_SH if curl fails. install_error_trap
    # (called later, after source) replaces this EXIT trap with cleanup_on_exit,
    # which also handles COMMON_SH if it looks like a temp — see lib/common.sh.
    trap 'rm -f "$COMMON_SH"' EXIT
    if ! curl -fsSL "$REPO_RAW/lib/common.sh" -o "$COMMON_SH"; then
        printf "✗ Failed to fetch lib/common.sh from %s\n" "$REPO_RAW" >&2
        exit 1
    fi
fi
# shellcheck disable=SC1090
source "$COMMON_SH"

# ── Resolve _merge_settings.py source (local checkout or curl) ───────────────
MERGE_SRC=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/_merge_settings.py" ]; then
    MERGE_SRC="$_self_dir/_merge_settings.py"
else
    MERGE_SRC="$(mktemp)"
    TEMP_FILES+=("$MERGE_SRC")
    if ! curl -fsSL "$REPO_RAW/agents/claude-code/_merge_settings.py" -o "$MERGE_SRC"; then
        print_error "Failed to fetch _merge_settings.py from $REPO_RAW"
        exit 1
    fi
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
O2_URL=""
O2_ORG=""
O2_TOKEN=""
O2_STREAM="default"
SCOPE="global"
DRY_RUN=0

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Claude Code -> OpenObserve installer (native OpenTelemetry)

Usage:
    $0 [OPTIONS]

Required:
    --url=URL             OpenObserve instance URL (e.g. https://api.openobserve.ai)
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
    --stream=NAME         OpenObserve stream for Claude Code logs + traces
                          (a single stream-name header routes both).
                          Default: default
                          (--traces-stream is accepted as an alias)
    --scope=SCOPE         "global" (~/.claude/settings.json) or
                          "project" (./.claude/settings.local.json)
                          Default: global
    --quiet               Suppress info logs
    --dry-run             Validate config + print plan, no changes
    --help                Show this help

Examples:
    $0 --url=https://api.openobserve.ai \\
       --org=default \\
       --token="Basic \$(echo -n 'me@example.com:pass' | base64)"
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --url=*)     O2_URL="${arg#*=}" ;;
        --org=*)     O2_ORG="${arg#*=}" ;;
        --token=*)   O2_TOKEN="${arg#*=}" ;;
        --scope=*)   SCOPE="${arg#*=}" ;;
        --stream=*)        O2_STREAM="${arg#*=}" ;;
        --traces-stream=*) O2_STREAM="${arg#*=}" ;;  # back-compat alias for --stream
        --quiet)     O2_QUIET=1 ;;
        --dry-run)   DRY_RUN=1 ;;
        --help|-h)   usage; exit 0 ;;
        *)
            print_error "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

# ── Required-flag validation ─────────────────────────────────────────────────
missing=()
[ -z "$O2_URL" ]   && missing+=("--url")
[ -z "$O2_ORG" ]   && missing+=("--org")
[ -z "$O2_TOKEN" ] && missing+=("--token")
if (( ${#missing[@]} > 0 )); then
    print_error "Missing required flag(s): ${missing[*]}"
    usage
    exit 1
fi

case "$SCOPE" in
    global|project) ;;
    *)
        print_error "Invalid --scope=$SCOPE. Use 'global' or 'project'."
        exit 1
        ;;
esac

# An explicit but empty --stream= falls back to the default stream.
[ -z "$O2_STREAM" ] && O2_STREAM="default"

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

# Token format check (warn, don't reject).
token_scheme="${O2_TOKEN%% *}"
token_payload="${O2_TOKEN#* }"
case "$token_scheme" in
    Basic)
        if ! validate_base64 "$token_payload"; then
            print_warning "Token payload after 'Basic ' is not valid base64 — continuing anyway."
        fi
        ;;
    Bearer) : ;;
    *) print_warning "Token does not start with 'Basic ' or 'Bearer '. Continuing." ;;
esac

# ── Resolve python (used only for the JSON settings merge) ────────────────────
PY="$(detect_python)" || {
    print_error "Python 3.9+ not found on PATH. Install python3 and re-run."
    exit 1
}
print_info "Using Python: $($PY --version 2>&1)"

# ── Resolve settings path for this scope ─────────────────────────────────────
if [ "$SCOPE" = "global" ]; then
    SETTINGS_FILE="$HOME/.claude/settings.json"
else
    SETTINGS_FILE="./.claude/settings.local.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
print_info "OTLP endpoint: $O2_URL/api/$O2_ORG"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Stream (logs+traces): $O2_STREAM"
print_info "Scope: $SCOPE"
print_info "Settings file: $SETTINGS_FILE"
print_info "Signals: metrics + events + traces (beta)"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

# ── Step 1: Merge native telemetry env into settings file ────────────────────
print_step "1/2" "Writing native OpenTelemetry env into $SETTINGS_FILE..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

# Backup if the settings file already exists.
if [ -f "$SETTINGS_FILE" ]; then
    backup="${SETTINGS_FILE}.bak.$(date +%s)"
    cp "$SETTINGS_FILE" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing settings to $backup"
fi

# Delegate the JSON merge to _merge_settings.py. Config goes over stdin
# (not env / argv) so the auth token never appears in `ps` output. The merge
# writes/updates only the managed CLAUDE_CODE_* + OTEL_* keys, and migrates
# any older install by stripping the legacy openobserve_hooks.py Stop hook.
if ! printf '%s\n' \
        "$SETTINGS_FILE" \
        "$O2_URL" \
        "$O2_ORG" \
        "$O2_TOKEN" \
        "$O2_STREAM" \
    | "$PY" "$MERGE_SRC"; then
    print_error "Settings merge failed."
    exit 1
fi
print_success "$SETTINGS_FILE updated."

# ── Step 2: Done — print verification + uninstall instructions ───────────────
print_step "2/2" "Done. Next steps:"
cat <<EOF

  Settings file:  $SETTINGS_FILE
  OTLP endpoint:  $O2_URL/api/$O2_ORG

Verify it's working:

  1. Start a NEW Claude Code session (env is read at session start) and run any
     trivial turn.
  2. In OpenObserve, open Logs and select the '$O2_STREAM' stream — you should
     see events (user_prompt, api_request, tool_result, ...).
  3. Metrics land in the 'claude_code_*' streams; the per-turn span tree shows
     up under Traces in the '$O2_STREAM' stream (service.name = claude-code).

Uninstall:

  curl -fsSL $REPO_RAW/agents/claude-code/uninstall.sh | bash -s -- --scope=$SCOPE

EOF

trap - ERR INT TERM
exit 0
