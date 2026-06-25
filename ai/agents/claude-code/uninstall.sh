#!/bin/bash
# o2-datasource / ai / agents / claude-code / uninstall.sh
#
# Removes the Claude Code -> OpenObserve telemetry config written by install.sh.
# Reverses everything install.sh wrote, and cleans up the older hook-based flow:
#   - Removes the managed CLAUDE_CODE_* + OTEL_* env keys from settings
#   - Removes any legacy Stop hook entry that points at openobserve_hooks.py
#   - Optionally removes the legacy hook script and state files

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

# ── Resolve _unmerge_settings.py source (local checkout or curl) ─────────────
UNMERGE_SRC=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/_unmerge_settings.py" ]; then
    UNMERGE_SRC="$_self_dir/_unmerge_settings.py"
else
    UNMERGE_SRC="$(mktemp)"
    TEMP_FILES+=("$UNMERGE_SRC")
    if ! curl -fsSL "$REPO_RAW/agents/claude-code/_unmerge_settings.py" -o "$UNMERGE_SRC"; then
        print_error "Failed to fetch _unmerge_settings.py from $REPO_RAW"
        exit 1
    fi
fi

SCOPE="global"
REMOVE_HOOK_SCRIPT=0
REMOVE_STATE=0
DRY_RUN=0
FORCE=0

usage() {
    cat <<EOF
Claude Code -> OpenObserve uninstaller

Usage:
    $0 [OPTIONS]

Options:
    --scope=SCOPE          "global" or "project" (default: global)
    --remove-hook-script   (legacy) Also delete \$HOME/.claude/hooks/openobserve_hooks.py
    --remove-state         (legacy) Also delete \$HOME/.claude/state/openobserve_*
    --remove-all           Remove everything (legacy hook script, state, settings entries)
    --dry-run              Show what would be removed
    --force                Skip confirmation prompts
    --quiet                Suppress info logs
    --help                 Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --scope=*)            SCOPE="${arg#*=}" ;;
        --remove-hook-script) REMOVE_HOOK_SCRIPT=1 ;;
        --remove-state)       REMOVE_STATE=1 ;;
        --remove-all)         REMOVE_HOOK_SCRIPT=1; REMOVE_STATE=1 ;;
        --dry-run)            DRY_RUN=1 ;;
        --force)              FORCE=1 ;;
        --quiet)              O2_QUIET=1 ;;
        --help|-h)            usage; exit 0 ;;
        *) print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

case "$SCOPE" in
    global)  SETTINGS_FILE="$HOME/.claude/settings.json" ;;
    project) SETTINGS_FILE="./.claude/settings.local.json" ;;
    *) print_error "Invalid --scope=$SCOPE. Use 'global' or 'project'."; exit 1 ;;
esac

HOOK_DEST="$HOME/.claude/hooks/openobserve_hooks.py"
STATE_DIR="$HOME/.claude/state"

PY="$(detect_python)" || {
    print_error "Python 3.9+ not found on PATH."
    exit 1
}

print_info "Scope: $SCOPE"
print_info "Settings file: $SETTINGS_FILE"
print_info "Hook script: $HOOK_DEST (will be removed: $REMOVE_HOOK_SCRIPT)"
print_info "State dir: $STATE_DIR (will be removed: $REMOVE_STATE)"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: no changes made."
    exit 0
fi

if (( FORCE == 0 )); then
    printf "Continue? (y/N) "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) print_info "Aborted."; exit 0 ;;
    esac
fi

# ── Strip settings entries ───────────────────────────────────────────────────
if [ -f "$SETTINGS_FILE" ]; then
    backup="${SETTINGS_FILE}.bak.$(date +%s)"
    cp "$SETTINGS_FILE" "$backup"
    print_info "Backed up settings to $backup"

    # Delegate strip logic to _unmerge_settings.py — matches the Stop hook
    # entry by filename suffix (not by full command), so a Python upgrade
    # between install and uninstall doesn't leave the entry behind.
    if ! printf '%s\n' "$SETTINGS_FILE" | "$PY" "$UNMERGE_SRC"; then
        print_error "Settings strip failed."
        exit 1
    fi
    print_success "Stripped OpenObserve entries from $SETTINGS_FILE"
else
    print_info "$SETTINGS_FILE not found — nothing to strip."
fi

# ── Optionally remove hook script ────────────────────────────────────────────
if (( REMOVE_HOOK_SCRIPT == 1 )); then
    if [ -f "$HOOK_DEST" ]; then
        rm -f "$HOOK_DEST"
        print_success "Removed $HOOK_DEST"
    else
        print_info "Hook script not present at $HOOK_DEST"
    fi
fi

# ── Optionally remove state ──────────────────────────────────────────────────
if (( REMOVE_STATE == 1 )); then
    if [ -d "$STATE_DIR" ]; then
        for f in "$STATE_DIR/openobserve_hook.log" "$STATE_DIR/openobserve_state.json" "$STATE_DIR/openobserve_state.lock"; do
            [ -e "$f" ] && rm -f "$f" && print_success "Removed $f"
        done
    fi
fi

print_success "Uninstall complete."
