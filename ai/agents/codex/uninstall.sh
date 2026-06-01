#!/bin/bash
# o2-datasource / ai / agents / codex / uninstall.sh
#
# Removes the OpenObserve OTel block from ~/.codex/config.toml.

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

DRY_RUN=0
FORCE=0

usage() {
    cat <<EOF
Codex -> OpenObserve uninstaller

Usage:
    $0 [OPTIONS]

Options:
    --dry-run     Show what would be removed
    --force       Skip confirmation
    --quiet       Suppress info logs
    --help        Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        --quiet)   O2_QUIET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

CONFIG_FILE="$HOME/.codex/config.toml"
PY="$(detect_python)" || { print_error "Python 3.9+ not found."; exit 1; }

print_info "Config file: $CONFIG_FILE"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: no changes made."
    exit 0
fi

if [ ! -f "$CONFIG_FILE" ]; then
    print_info "$CONFIG_FILE does not exist — nothing to remove."
    exit 0
fi

if (( FORCE == 0 )); then
    printf "Remove OpenObserve OTel block from %s? (y/N) " "$CONFIG_FILE"
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) print_info "Aborted."; exit 0 ;;
    esac
fi

backup="${CONFIG_FILE}.bak.$(date +%s)"
cp "$CONFIG_FILE" "$backup"
print_info "Backed up to $backup"

O2_CONFIG="$CONFIG_FILE" "$PY" - <<'PY'
import os, pathlib, tempfile
path = pathlib.Path(os.environ["O2_CONFIG"])
START = "# >>> openobserve-otel >>>"
END   = "# <<< openobserve-otel <<<"
text = path.read_text(encoding="utf-8")
if START in text and END in text:
    pre, _, rest = text.partition(START)
    _, _, post = rest.partition(END)
    post = post.lstrip("\n")
    new = (pre.rstrip() + ("\n" if post.strip() else "")) + post
    fd, tmp = tempfile.mkstemp(prefix="config.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(new if new.endswith("\n") else new + "\n")
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
        raise
PY

print_success "Removed OpenObserve OTel block from $CONFIG_FILE"
