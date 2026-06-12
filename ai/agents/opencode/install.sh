#!/bin/bash
# o2-datasource / ai / agents / opencode / install.sh
#
# Installs the OpenCode -> OpenObserve telemetry plugin and configures it.
#
# Mechanism: OpenCode itself does not ship native OTLP export. We install
# @devtheops/opencode-plugin-otel (npm-published, no build step needed),
# reference it from opencode.jsonc by package name, and write a sourced
# env file with standard OTEL_EXPORTER_OTLP_* variables pointing at the
# user's OpenObserve instance.
#
# Plugin source: https://github.com/DEVtheOPS/opencode-plugin-otel
#
# Requires: node, npm (to install the plugin), python3 (for JSON merge).
#
# Usage:
#   curl -fsSL .../agents/opencode/install.sh | bash -s -- \
#     --url=... --org=... --token="Basic ..."

set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai}"
PLUGIN_PACKAGE_DEFAULT="@devtheops/opencode-plugin-otel"
PLUGIN_VERSION_DEFAULT="latest"

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
O2_TRACES_STREAM=""
SCOPE="global"
PLUGIN_PACKAGE="$PLUGIN_PACKAGE_DEFAULT"
PLUGIN_VERSION="$PLUGIN_VERSION_DEFAULT"
DRY_RUN=0
SKIP_PLUGIN_INSTALL=0

usage() {
    cat <<EOF
OpenCode -> OpenObserve installer

Usage:
    $0 [OPTIONS]

Required:
    --url=URL              OpenObserve instance URL
    --org=ID               OpenObserve organization slug or ID
    --token=TOKEN          Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
    --traces-stream=NAME   OpenObserve stream name for traces (default: OpenObserve default)
    --scope=SCOPE          "global" (~/.config/opencode/) or
                           "project" (./.opencode/) — default: global
                           Note: plugin is always installed globally via npm;
                           scope affects opencode.jsonc location only.
    --plugin-package=NAME  npm package to install (default: $PLUGIN_PACKAGE_DEFAULT)
    --plugin-version=SPEC  npm version spec (default: $PLUGIN_VERSION_DEFAULT)
    --skip-plugin-install  Skip npm install (use when plugin is already on disk)
    --dry-run              Validate config + print plan, no changes
    --quiet                Suppress info logs
    --help                 Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --url=*)               O2_URL="${arg#*=}" ;;
        --org=*)               O2_ORG="${arg#*=}" ;;
        --token=*)             O2_TOKEN="${arg#*=}" ;;
        --traces-stream=*)     O2_TRACES_STREAM="${arg#*=}" ;;
        --scope=*)             SCOPE="${arg#*=}" ;;
        --plugin-package=*)    PLUGIN_PACKAGE="${arg#*=}" ;;
        --plugin-version=*)    PLUGIN_VERSION="${arg#*=}" ;;
        --skip-plugin-install) SKIP_PLUGIN_INSTALL=1 ;;
        --dry-run)             DRY_RUN=1 ;;
        --quiet)               O2_QUIET=1 ;;
        --help|-h)             usage; exit 0 ;;
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
    global)
        OPENCODE_DIR="$HOME/.config/opencode"
        CONFIG_FILE="$OPENCODE_DIR/opencode.jsonc"
        ;;
    project)
        OPENCODE_DIR="./.opencode"
        # Project scope still uses the global opencode.jsonc — opencode's
        # per-project plugin convention puts plugins under .opencode/plugin/,
        # but registration still happens in ~/.config/opencode/opencode.jsonc.
        CONFIG_FILE="$HOME/.config/opencode/opencode.jsonc"
        ;;
    *) print_error "Invalid --scope=$SCOPE. Use 'global' or 'project'."; exit 1 ;;
esac

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

PY="$(detect_python)" || { print_error "Python 3.9+ not found."; exit 1; }
if (( SKIP_PLUGIN_INSTALL == 0 )); then
    require_cmd npm
fi

# Standard OTel base endpoint — DEVtheOPS plugin appends /v1/{signal}.
OTLP_ENDPOINT="$O2_URL/api/$O2_ORG"
OTLP_HEADERS="Authorization=$O2_TOKEN"
[ -n "$O2_TRACES_STREAM" ] && OTLP_HEADERS="$OTLP_HEADERS,stream-name=$O2_TRACES_STREAM"

print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
[ -n "$O2_TRACES_STREAM" ] && print_info "Traces stream: $O2_TRACES_STREAM"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Scope: $SCOPE"
print_info "Plugin package: $PLUGIN_PACKAGE@$PLUGIN_VERSION"
print_info "Config file: $CONFIG_FILE"
print_info "OTLP endpoint: $OTLP_ENDPOINT"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

# ── Step 1: npm install the plugin ───────────────────────────────────────────
if (( SKIP_PLUGIN_INSTALL == 1 )); then
    print_step "1/3" "Skipping plugin install (--skip-plugin-install)"
else
    print_step "1/3" "Installing $PLUGIN_PACKAGE@$PLUGIN_VERSION via npm..."
    retry_command npm install -g --silent "$PLUGIN_PACKAGE@$PLUGIN_VERSION"
    RESOURCES_CREATED+=("npm global: $PLUGIN_PACKAGE")
    print_success "Plugin installed."
fi

# ── Step 2: merge opencode.jsonc ─────────────────────────────────────────────
print_step "2/3" "Merging $CONFIG_FILE..."
mkdir -p "$(dirname "$CONFIG_FILE")"

if [ -f "$CONFIG_FILE" ]; then
    backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup"
    RESOURCES_CREATED+=("backup: $backup")
    print_info "Backed up existing config to $backup"
fi

# Python merger: JSONC = JSON with //-line and /* */ block comments.
O2_CONFIG="$CONFIG_FILE" \
O2_PLUGIN_NAME="$PLUGIN_PACKAGE" \
"$PY" - <<'PY'
import os, re, json, pathlib, tempfile

path = pathlib.Path(os.environ["O2_CONFIG"])
plugin_name = os.environ["O2_PLUGIN_NAME"]

def strip_jsonc_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    out_lines = []
    for line in text.splitlines():
        in_str = False
        esc = False
        idx = -1
        for i, ch in enumerate(line):
            if esc:
                esc = False; continue
            if ch == "\\":
                esc = True; continue
            if ch == '"':
                in_str = not in_str; continue
            if not in_str and ch == "/" and i + 1 < len(line) and line[i+1] == "/":
                idx = i; break
        out_lines.append(line if idx == -1 else line[:idx])
    return "\n".join(out_lines)

cfg = {}
if path.exists() and path.stat().st_size > 0:
    raw = path.read_text(encoding="utf-8")
    try:
        cfg = json.loads(strip_jsonc_comments(raw))
    except json.JSONDecodeError as e:
        raise SystemExit(f"Existing opencode config is not valid JSON/JSONC: {path} ({e})")
    if not isinstance(cfg, dict):
        raise SystemExit(f"Existing config root is not an object: {path}")

cfg.setdefault("$schema", "https://opencode.ai/config.json")

plugins = cfg.get("plugin")
if not isinstance(plugins, list):
    plugins = []
if plugin_name not in plugins:
    plugins.append(plugin_name)
cfg["plugin"] = plugins

d = path.parent
d.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix="opencode.", suffix=".tmp", dir=str(d))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
print_success "$CONFIG_FILE updated."

# ── Step 3: write env file (user sources before launching opencode) ──────────
print_step "3/3" "Writing OTel env file..."
ENV_FILE="$OPENCODE_DIR/openobserve.env"
mkdir -p "$OPENCODE_DIR"

cat >"$ENV_FILE" <<EOF
# OpenObserve OTLP exporter config for @devtheops/opencode-plugin-otel.
# Source this file before launching opencode:
#   source $ENV_FILE && opencode
export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT"
export OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
export OTEL_EXPORTER_OTLP_HEADERS="$OTLP_HEADERS"
export OTEL_SERVICE_NAME="opencode"
EOF
RESOURCES_CREATED+=("env: $ENV_FILE")
print_success "Env file written: $ENV_FILE"

cat <<EOF

Done.

  Plugin:        $PLUGIN_PACKAGE (installed globally via npm)
  Config:        $CONFIG_FILE
  Env file:      $ENV_FILE
  OTLP base:     $OTLP_ENDPOINT

To activate, source the env file before launching OpenCode:

  source $ENV_FILE && opencode

Or add to your shell rc (~/.bashrc, ~/.zshrc):

  [ -f $ENV_FILE ] && source $ENV_FILE

Verify:

  Run any OpenCode session. In OpenObserve, open Traces and filter by
  service_name=opencode.

Uninstall:

  curl -fsSL $REPO_RAW/agents/opencode/uninstall.sh | bash -s -- --scope=$SCOPE

EOF

trap - ERR INT TERM
exit 0
