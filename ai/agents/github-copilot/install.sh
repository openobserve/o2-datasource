#!/bin/bash
# o2-datasource / ai / agents / github-copilot / install.sh
#
# Configures GitHub Copilot (CLI + VS Code Copilot Chat) to export
# OpenTelemetry traces to OpenObserve.
#
# Mechanism: the Copilot CLI is configured entirely through environment
# variables (there is no user-level config file for OTel; managed settings
# are an enterprise policy surface). This installer persists the required
# env block into the user's shell profile(s) (~/.zshrc / ~/.bashrc) between
# sentinel markers, so every new terminal — and any VS Code launched from
# one — picks it up. Safe to re-run: the managed block is rewritten in place.
#
# Two variables here are required in practice but missing from GitHub's own
# docs (both verified against a live OpenObserve instance):
#   COPILOT_OTEL_EXPORTER_TYPE=otlp-http   # default is a local *file* exporter
#   OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf  # OTLP JSON is rejected (400)
#
# Usage:
#   curl -fsSL .../agents/github-copilot/install.sh | bash -s -- \
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
O2_STREAM="default"
SCOPE="global"
DRY_RUN=0

usage() {
    cat <<EOF
GitHub Copilot -> OpenObserve installer

Usage:
    $0 [OPTIONS]

Required:
    --url=URL             OpenObserve instance URL
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token: "Basic <base64>" or "Bearer <token>"

Optional:
    --stream=NAME         OpenObserve traces stream for Copilot spans (default: default)
    --scope=SCOPE         "global" (shell profile env block) — only supported value
    --dry-run             Validate config, no changes
    --quiet               Suppress info logs
    --help                Show this help
EOF
}

for arg in "$@"; do
    case $arg in
        --url=*)    O2_URL="${arg#*=}" ;;
        --org=*)    O2_ORG="${arg#*=}" ;;
        --token=*)  O2_TOKEN="${arg#*=}" ;;
        --stream=*) O2_STREAM="${arg#*=}" ;;
        --scope=*)  SCOPE="${arg#*=}" ;;
        --quiet)    O2_QUIET=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        --help|-h)  usage; exit 0 ;;
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
    *) print_error "Invalid --scope=$SCOPE. Use 'global'."; exit 1 ;;
esac

if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

# Guard against a "Basic <base64>" token whose decoded form is "email:" with an
# empty passcode — the OTLP export then 401s silently and no spans ever appear.
case "$O2_TOKEN" in
    Basic\ *)
        b64="${O2_TOKEN#Basic }"
        decoded="$(printf '%s' "$b64" | base64 -d 2>/dev/null || printf '%s' "$b64" | base64 -D 2>/dev/null || true)"
        if [ -z "$decoded" ]; then
            print_error "--token is not valid base64 after 'Basic '."
            exit 1
        fi
        case "$decoded" in
            *:) print_error "--token decodes to '${decoded}' — the passcode after ':' is EMPTY. Generate an ingestion token in OpenObserve (Data Sources -> Custom -> OpenTelemetry) and re-run."; exit 1 ;;
            *:*) ;;
            *) print_error "--token must decode to 'email:passcode'."; exit 1 ;;
        esac
        ;;
    Bearer\ *) ;;
    *) print_error "--token must start with 'Basic ' or 'Bearer '."; exit 1 ;;
esac

OTLP_ENDPOINT="$O2_URL/api/$O2_ORG"

print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
print_info "Traces stream: $O2_STREAM"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "OTLP endpoint (base, exporter appends /v1/traces): $OTLP_ENDPOINT"

# Pick target shell profiles: every one that exists, else create the one
# matching \$SHELL so new terminals inherit the block.
PROFILES=()
[ -f "$HOME/.zshrc" ]  && PROFILES+=("$HOME/.zshrc")
[ -f "$HOME/.bashrc" ] && PROFILES+=("$HOME/.bashrc")
if (( ${#PROFILES[@]} == 0 )); then
    case "${SHELL:-}" in
        */zsh) PROFILES+=("$HOME/.zshrc") ;;
        *)     PROFILES+=("$HOME/.bashrc") ;;
    esac
fi
print_info "Shell profile(s): ${PROFILES[*]}"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

START="# >>> openobserve-github-copilot >>>"
END="# <<< openobserve-github-copilot <<<"

BLOCK="$START
# Managed by o2-datasource github-copilot installer. Re-run install.sh to
# update; run uninstall.sh to remove. Do not edit inside this block.
export COPILOT_OTEL_ENABLED=true
export COPILOT_OTEL_EXPORTER_TYPE=otlp-http
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=\"$OTLP_ENDPOINT\"
export OTEL_EXPORTER_OTLP_HEADERS=\"Authorization=$O2_TOKEN,stream-name=$O2_STREAM\"
export OTEL_SERVICE_NAME=github-copilot
$END"

print_step "1/1" "Writing env block to shell profile(s)..."
for profile in "${PROFILES[@]}"; do
    if [ -f "$profile" ]; then
        backup="${profile}.bak.$(date +%s)"
        cp "$profile" "$backup"
        RESOURCES_CREATED+=("backup: $backup")
        print_info "Backed up $profile to $backup"
        # Remove any existing managed block, then append the fresh one.
        tmp="$(mktemp)"
        awk -v start="$START" -v end="$END" '
            $0 == start {skip=1; next}
            $0 == end   {skip=0; next}
            !skip {print}
        ' "$profile" > "$tmp"
        mv "$tmp" "$profile"
    fi
    printf '\n%s\n' "$BLOCK" >> "$profile"
    print_info "Wrote managed block to $profile"
done

print_success "Done. Open a NEW terminal (or 'source' your profile), then run 'copilot'."
print_info "Note: a Copilot session already running keeps its old env — start a fresh one."
print_info "VS Code: launch it from a new terminal ('code .') so Copilot Chat inherits the env."

trap - ERR INT TERM
exit 0
