#!/bin/bash
# o2-datasource / ai / agents / opencode / uninstall.sh
#
# Reverses what install.sh wrote:
#   - removes the opencode-telemetry plugin path from opencode.jsonc
#   - clears experimental.openTelemetry
#   - optionally removes the plugin dir and env file

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

SCOPE="global"
REMOVE_PLUGIN=0
REMOVE_ENV=0
DRY_RUN=0
FORCE=0

usage() {
    cat <<EOF
OpenCode -> OpenObserve uninstaller

Usage:
    $0 [OPTIONS]

Options:
    --scope=SCOPE        "global" or "project" (default: global)
    --remove-plugin      Also delete the plugin directory
    --remove-env         Also delete the openobserve.env file
    --remove-all         Implies both --remove-plugin and --remove-env
    --dry-run            Show what would be removed
    --force              Skip confirmation
    --quiet              Suppress info logs
    --help               Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --scope=*)         SCOPE="${arg#*=}" ;;
        --remove-plugin)   REMOVE_PLUGIN=1 ;;
        --remove-env)      REMOVE_ENV=1 ;;
        --remove-all)      REMOVE_PLUGIN=1; REMOVE_ENV=1 ;;
        --dry-run)         DRY_RUN=1 ;;
        --force)           FORCE=1 ;;
        --quiet)           O2_QUIET=1 ;;
        --help|-h)         usage; exit 0 ;;
        *) print_error "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

case "$SCOPE" in
    global)
        OPENCODE_DIR="$HOME/.config/opencode"
        PLUGIN_DIR="$OPENCODE_DIR/plugins/opencode-telemetry"
        CONFIG_FILE="$OPENCODE_DIR/opencode.jsonc"
        ;;
    project)
        OPENCODE_DIR="./.opencode"
        PLUGIN_DIR="$OPENCODE_DIR/plugin/opencode-telemetry"
        CONFIG_FILE="$HOME/.config/opencode/opencode.jsonc"
        ;;
    *) print_error "Invalid --scope=$SCOPE."; exit 1 ;;
esac

ENV_FILE="$OPENCODE_DIR/openobserve.env"
PY="$(detect_python)" || { print_error "Python 3.9+ not found."; exit 1; }

print_info "Scope: $SCOPE"
print_info "Plugin dir: $PLUGIN_DIR (will be removed: $REMOVE_PLUGIN)"
print_info "Config file: $CONFIG_FILE"
print_info "Env file: $ENV_FILE (will be removed: $REMOVE_ENV)"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: no changes made."
    exit 0
fi

if (( FORCE == 0 )); then
    printf "Continue? (y/N) "; read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) print_info "Aborted."; exit 0 ;; esac
fi

if [ -f "$CONFIG_FILE" ]; then
    backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    print_info "Backed up config to $backup"

    O2_CONFIG="$CONFIG_FILE" O2_PLUGIN_PATH="file://$PLUGIN_DIR" "$PY" - <<'PY'
import os, re, json, pathlib, tempfile
path = pathlib.Path(os.environ["O2_CONFIG"])
plugin_uri = os.environ["O2_PLUGIN_PATH"]

def strip(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    out = []
    for line in text.splitlines():
        in_str = False; esc = False; idx = -1
        for i, ch in enumerate(line):
            if esc: esc = False; continue
            if ch == "\\": esc = True; continue
            if ch == '"': in_str = not in_str; continue
            if not in_str and ch == "/" and i+1 < len(line) and line[i+1] == "/":
                idx = i; break
        out.append(line if idx == -1 else line[:idx])
    return "\n".join(out)

if not path.exists() or path.stat().st_size == 0:
    raise SystemExit(0)
try:
    cfg = json.loads(strip(path.read_text(encoding="utf-8")))
except json.JSONDecodeError as e:
    raise SystemExit(f"config not valid: {e}")
if not isinstance(cfg, dict):
    raise SystemExit(0)

plugins = cfg.get("plugin")
if isinstance(plugins, list):
    plugins = [p for p in plugins if p != plugin_uri]
    if plugins:
        cfg["plugin"] = plugins
    else:
        cfg.pop("plugin", None)

exp = cfg.get("experimental")
if isinstance(exp, dict):
    exp.pop("openTelemetry", None)
    if exp:
        cfg["experimental"] = exp
    else:
        cfg.pop("experimental", None)

fd, tmp = tempfile.mkstemp(prefix="opencode.", suffix=".tmp", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=False); f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
    print_success "Stripped plugin entry from $CONFIG_FILE"
fi

if (( REMOVE_PLUGIN == 1 )) && [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR"
    print_success "Removed $PLUGIN_DIR"
fi

if (( REMOVE_ENV == 1 )) && [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
    print_success "Removed $ENV_FILE"
fi

print_success "Uninstall complete."
