#!/bin/bash
# o2-datasource / ai / agents / claude-code / install.sh
#
# Installs the Claude Code -> OpenObserve Stop hook.
# Reference: https://openobserve.ai/docs/integration/ai/agents/claude-code/
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

# ── Resolve hook source (local checkout or curl) ─────────────────────────────
HOOK_SRC=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/openobserve_hooks.py" ]; then
    HOOK_SRC="$_self_dir/openobserve_hooks.py"
else
    HOOK_SRC="$(mktemp)"
    TEMP_FILES+=("$HOOK_SRC")
    if ! curl -fsSL "$REPO_RAW/agents/claude-code/openobserve_hooks.py" -o "$HOOK_SRC"; then
        print_error "Failed to fetch openobserve_hooks.py from $REPO_RAW"
        exit 1
    fi
fi

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
SCOPE="global"
DRY_RUN=0

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Claude Code -> OpenObserve installer

Usage:
    $0 [OPTIONS]

Required:
    --url=URL             OpenObserve instance URL
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
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

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

# Token format check (matches frameworks/setup.sh policy: warn, don't reject)
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

# ── Resolve python ───────────────────────────────────────────────────────────
PY="$(detect_python)" || {
    print_error "Python 3.9+ not found on PATH. Install python3 and re-run."
    exit 1
}
print_info "Using Python: $($PY --version 2>&1)"
if [ -n "${VIRTUAL_ENV:-}" ]; then
    print_info "Active virtualenv: $VIRTUAL_ENV (pip will install into it)"
fi

# ── Resolve paths for this scope ─────────────────────────────────────────────
if [ "$SCOPE" = "global" ]; then
    CLAUDE_DIR="$HOME/.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.json"
else
    CLAUDE_DIR="./.claude"
    SETTINGS_FILE="$CLAUDE_DIR/settings.local.json"
fi
HOOKS_DIR="$HOME/.claude/hooks"           # hook script always lives globally
HOOK_DEST="$HOOKS_DIR/openobserve_hooks.py"
STATE_DIR="$HOME/.claude/state"
LOG_FILE="$STATE_DIR/openobserve_hook.log"

# ── Summary ──────────────────────────────────────────────────────────────────
print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Scope: $SCOPE"
print_info "Settings file: $SETTINGS_FILE"
print_info "Hook script: $HOOK_DEST"
print_info "Log file: $LOG_FILE"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

# ── Step 1: pip install openobserve-telemetry-sdk ────────────────────────────
print_step "1/4" "Installing openobserve-telemetry-sdk..."
retry_command pip_install "$PY" openobserve-telemetry-sdk
print_success "SDK installed."

# Verify the imports the hook depends on are usable now.
if ! verify_imports "$PY" "from openobserve import openobserve_init_traces, openobserve_flush, openobserve_shutdown; from opentelemetry import trace"; then
    print_error "openobserve-telemetry-sdk imports failed after install. See errors above."
    exit 1
fi

# ── Step 2: Copy openobserve_hooks.py into place ─────────────────────────────
print_step "2/4" "Installing hook script..."
mkdir -p "$HOOKS_DIR"
# Back up an existing hook if present.
if [ -f "$HOOK_DEST" ]; then
    backup="${HOOK_DEST}.bak.$(date +%s)"
    cp "$HOOK_DEST" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing hook to $backup"
fi
cp "$HOOK_SRC" "$HOOK_DEST"
RESOURCES_CREATED+=("hook: $HOOK_DEST")
print_success "Hook script installed at $HOOK_DEST"

# ── Step 3: Merge into settings file ─────────────────────────────────────────
print_step "3/4" "Merging Stop hook + env into $SETTINGS_FILE..."
mkdir -p "$(dirname "$SETTINGS_FILE")"

# Backup if the settings file already exists.
if [ -f "$SETTINGS_FILE" ]; then
    backup="${SETTINGS_FILE}.bak.$(date +%s)"
    cp "$SETTINGS_FILE" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing settings to $backup"
fi

# Delegate the JSON merge to _merge_settings.py. Config goes over stdin
# (not env / argv) so the auth token never appears in `ps` output.
# The merge script uses $PY for the hook command, matches existing entries
# by filename suffix (so a Python upgrade between installs doesn't
# duplicate the Stop hook), and updates the command in place if found.
if ! printf '%s\n' \
        "$SETTINGS_FILE" \
        "$PY $HOOK_DEST" \
        "$O2_URL" \
        "$O2_ORG" \
        "$O2_TOKEN" \
    | "$PY" "$MERGE_SRC"; then
    print_error "Settings merge failed."
    exit 1
fi
print_success "$SETTINGS_FILE updated."

# ── Step 4: Done — print verification + uninstall instructions ───────────────
print_step "4/4" "Done. Next steps:"
cat <<EOF

  Hook script:    $HOOK_DEST
  Settings file:  $SETTINGS_FILE
  Hook log:       $LOG_FILE

Verify it's working:

  1. Start a new Claude Code session and ask it anything trivial.
  2. tail -f $LOG_FILE  — you should see "Processed N turns" lines.
  3. In OpenObserve, open Traces and filter by service.name=claude-code.

Uninstall:

  curl -fsSL $REPO_RAW/agents/claude-code/uninstall.sh | bash -s -- --scope=$SCOPE

EOF

trap - ERR INT TERM
exit 0
