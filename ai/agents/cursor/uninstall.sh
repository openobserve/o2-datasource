#!/bin/bash
# o2-datasource / ai / agents / cursor / uninstall.sh
#
# Strips OpenObserve-specific keys from ~/.cursor/hooks/otel_config.json.
# Optionally removes the config file and the upstream cursor-otel-hook
# registration from ~/.cursor/hooks.json.

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
        printf "✗ Failed to fetch lib/common.sh\n" >&2; exit 1
    fi
fi
# shellcheck disable=SC1090
source "$COMMON_SH"

REMOVE_CONFIG=0
REMOVE_HOOK=0
DRY_RUN=0
FORCE=0

usage() {
    cat <<EOF
Cursor -> OpenObserve uninstaller

Usage:
    $0 [OPTIONS]

Options:
    --remove-config   Delete ~/.cursor/hooks/otel_config.json entirely
    --remove-hook     Also delete the cursor-otel-hook binary/wrapper
                      (run cursor-otel-hook's own uninstall if available)
    --remove-all      Implies both --remove-config and --remove-hook
    --dry-run         Show what would be removed
    --force           Skip confirmation
    --quiet           Suppress info logs
    --help            Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --remove-config)   REMOVE_CONFIG=1 ;;
        --remove-hook)     REMOVE_HOOK=1 ;;
        --remove-all)      REMOVE_CONFIG=1; REMOVE_HOOK=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        --force)           FORCE=1 ;;
        --quiet)           O2_QUIET=1 ;;
        --help|-h)         usage; exit 0 ;;
        *) print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

HOOKS_DIR="$HOME/.cursor/hooks"
OTEL_CONFIG="$HOOKS_DIR/otel_config.json"
HOOKS_REGISTRY="$HOME/.cursor/hooks.json"
PY="$(detect_python)" || { print_error "Python 3.9+ not found."; exit 1; }

print_info "OTel config: $OTEL_CONFIG (will be deleted: $REMOVE_CONFIG)"
print_info "Hooks dir: $HOOKS_DIR (cleared if --remove-hook: $REMOVE_HOOK)"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: no changes made."
    exit 0
fi

if (( FORCE == 0 )); then
    printf "Continue? (y/N) "; read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) print_info "Aborted."; exit 0 ;; esac
fi

# Strip managed keys from otel_config.json
if [ -f "$OTEL_CONFIG" ]; then
    backup="${OTEL_CONFIG}.bak.$(date +%s)"
    cp "$OTEL_CONFIG" "$backup"
    print_info "Backed up to $backup"

    O2_OTEL_CFG="$OTEL_CONFIG" "$PY" - <<'PY'
import json, os, pathlib, tempfile
path = pathlib.Path(os.environ["O2_OTEL_CFG"])
if not path.exists() or path.stat().st_size == 0:
    raise SystemExit(0)
try:
    cfg = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError:
    raise SystemExit(0)
if not isinstance(cfg, dict):
    raise SystemExit(0)
for k in ("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "OTEL_EXPORTER_OTLP_PROTOCOL",
          "OTEL_EXPORTER_OTLP_HEADERS", "OTEL_SERVICE_NAME"):
    cfg.pop(k, None)
fd, tmp = tempfile.mkstemp(prefix="otel_config.", suffix=".tmp", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=False); f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
    print_success "Stripped managed keys from $OTEL_CONFIG"
fi

if (( REMOVE_CONFIG == 1 )) && [ -f "$OTEL_CONFIG" ]; then
    rm -f "$OTEL_CONFIG"
    print_success "Deleted $OTEL_CONFIG"
fi

if (( REMOVE_HOOK == 1 )) && [ -d "$HOOKS_DIR" ]; then
    # Best-effort: remove the upstream binary + wrapper. Leave hooks.json to
    # upstream's own uninstall path; we don't touch it because we didn't
    # create it.
    rm -f "$HOOKS_DIR/cursor-otel-hook" "$HOOKS_DIR/cursor-otel-hook.exe" \
          "$HOOKS_DIR/otel_hook.sh" "$HOOKS_DIR/cursor_otel_hook.log"
    print_success "Removed upstream hook files from $HOOKS_DIR (hooks.json untouched)"
fi

print_success "Uninstall complete."
