#!/bin/bash
# o2-datasource / ai / frameworks / setup.sh
#
# Unified installer for AI framework / SDK / provider telemetry to OpenObserve.
# Per-integration packages + snippet live in ./integrations.json.
#
# Usage (curl|bash):
#   curl -fsSL https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai/frameworks/setup.sh | \
#     bash -s -- \
#       --integration=openai \
#       --url=https://api.openobserve.ai \
#       --org=default \
#       --traces-stream=ai_traces \
#       --token="Basic <base64>"

set -euo pipefail

# ── Resolve the repo's raw base URL ──────────────────────────────────────────
# Override REPO_RAW for local testing (e.g. file:// or a fork).
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/openobserve/o2-datasource/main/ai}"

# ── Source lib/common.sh (local checkout or curl) ────────────────────────────
# When this script is invoked as a file path, prefer the sibling lib/common.sh.
# Under `curl | bash`, BASH_SOURCE is empty/non-file, so we fetch.
_self_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

COMMON_SH=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/../lib/common.sh" ]; then
    COMMON_SH="$_self_dir/../lib/common.sh"
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

# ── Resolve integrations.json (local checkout or curl) ───────────────────────
INTEGRATIONS_JSON=""
INTEGRATIONS_TMP=""
if [ -n "$_self_dir" ] && [ -f "$_self_dir/integrations.json" ]; then
    INTEGRATIONS_JSON="$_self_dir/integrations.json"
else
    INTEGRATIONS_TMP="$(mktemp)"
    TEMP_FILES+=("$INTEGRATIONS_TMP")
    if ! curl -fsSL "$REPO_RAW/frameworks/integrations.json" -o "$INTEGRATIONS_TMP"; then
        print_error "Failed to fetch integrations.json from $REPO_RAW"
        exit 1
    fi
    INTEGRATIONS_JSON="$INTEGRATIONS_TMP"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
INTEGRATION=""
O2_URL=""
O2_ORG=""
O2_TOKEN=""
O2_TRACES_STREAM=""
O2_LOGS_STREAM=""
ENV_FILE="./.env"
DRY_RUN=0

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
OpenObserve Framework Telemetry Installer

Usage:
    $0 [OPTIONS]

Required:
    --integration=NAME    One of: openai, anthropic, gemini, langchain, crewai,
                          google-adk, claude-agent-sdk, openai-agents, openrouter,
                          litellm
    --url=URL             OpenObserve instance URL (e.g. https://api.openobserve.ai)
    --org=ID              OpenObserve organization slug or ID
    --token=TOKEN         Auth token in the form "Basic <base64>" or "Bearer <token>"

Optional:
    --traces-stream=NAME  OpenObserve stream name for traces (SDK default: default)
    --logs-stream=NAME    OpenObserve stream name for logs (SDK default: default)
    --env-file=PATH       Path to .env to write/merge (default: ./.env)
    --quiet               Suppress info logs; errors and warnings still print
    --dry-run             Validate config + print plan, don't install
    --help                Show this help

Examples:
    $0 --integration=openai \\
       --url=https://api.openobserve.ai \\
       --org=default \\
       --traces-stream=ai_traces \\
       --token="Basic \$(echo -n 'me@example.com:pass' | base64)"

    # Local testing against this checkout:
    REPO_RAW="file://\$(pwd)/.." $0 --integration=anthropic ...
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --integration=*) INTEGRATION="${arg#*=}" ;;
        --url=*)         O2_URL="${arg#*=}" ;;
        --org=*)         O2_ORG="${arg#*=}" ;;
        --token=*)       O2_TOKEN="${arg#*=}" ;;
        --traces-stream=*) O2_TRACES_STREAM="${arg#*=}" ;;
        --logs-stream=*) O2_LOGS_STREAM="${arg#*=}" ;;
        --env-file=*)    ENV_FILE="${arg#*=}" ;;
        --quiet)         O2_QUIET=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        --help|-h)       usage; exit 0 ;;
        *)
            print_error "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

# ── Required-flag validation ─────────────────────────────────────────────────
missing=()
[ -z "$INTEGRATION" ] && missing+=("--integration")
[ -z "$O2_URL" ]      && missing+=("--url")
[ -z "$O2_ORG" ]      && missing+=("--org")
[ -z "$O2_TOKEN" ]    && missing+=("--token")
if (( ${#missing[@]} > 0 )); then
    print_error "Missing required flag(s): ${missing[*]}"
    usage
    exit 1
fi

# ── Value validation ─────────────────────────────────────────────────────────
if ! validate_url "$O2_URL"; then
    print_error "Invalid --url: must start with http:// or https://"
    exit 1
fi
O2_URL="$(strip_trailing_slash "$O2_URL")"

# Token format: "Basic <base64>" or "Bearer <token>". Validate base64 portion if Basic.
token_scheme="${O2_TOKEN%% *}"
token_payload="${O2_TOKEN#* }"
case "$token_scheme" in
    Basic)
        if ! validate_base64 "$token_payload"; then
            print_warning "Token payload after 'Basic ' is not valid base64 — continuing anyway."
        fi
        ;;
    Bearer)
        : # accept as-is
        ;;
    *)
        print_warning "Token does not start with 'Basic ' or 'Bearer '. Continuing, but the OpenObserve exporter may reject it."
        ;;
esac

# ── Resolve python ───────────────────────────────────────────────────────────
PY="$(detect_python)" || {
    print_error "Python 3.9+ not found on PATH. Install python3 and re-run."
    exit 1
}
print_info "Using Python: $($PY --version 2>&1)"

# ── Look up the integration ──────────────────────────────────────────────────
INTEG_PACKAGES=""
INTEG_VERIFY_IMPORTS=""
INTEG_SNIPPET=""
INTEG_INSTRUCTION=""
INTEG_EXTRA_ENV=""
INTEG_VERIFY_STEP=""

# load_integration_data prints eval-able assignments to stdout, or an
# echo+exit-1 line if the integration name is unknown.
eval_output="$(load_integration_data "$INTEGRATIONS_JSON" "$INTEGRATION" "$PY")"
eval "$eval_output"

if [ -z "$INTEG_PACKAGES" ]; then
    # load_integration_data emits an "echo ...; exit 1" on unknown; if we
    # got here with empty packages something else went wrong.
    print_error "Integration '$INTEGRATION' returned no packages — check integrations.json"
    exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────────────
print_info "Integration: $INTEGRATION"
print_info "OpenObserve URL: $O2_URL"
print_info "Org: $O2_ORG"
[ -n "$O2_TRACES_STREAM" ] && print_info "Traces stream: $O2_TRACES_STREAM"
[ -n "$O2_LOGS_STREAM" ] && print_info "Logs stream: $O2_LOGS_STREAM"
print_info "Token: $(redact_secret "$O2_TOKEN")"
print_info "Env file: $ENV_FILE"
print_info "Packages: $INTEG_PACKAGES"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: configuration valid. No changes made."
    exit 0
fi

install_error_trap

# ── Step 1: pip install ──────────────────────────────────────────────────────
print_step "1/4" "Installing packages..."
# shellcheck disable=SC2086
retry_command pip_install "$PY" $INTEG_PACKAGES
print_success "Packages installed."

# ── Step 2: import verification ──────────────────────────────────────────────
print_step "2/4" "Verifying imports..."
if ! verify_imports "$PY" "$INTEG_VERIFY_IMPORTS"; then
    print_error "One or more required imports failed after install. See errors above."
    exit 1
fi
print_success "Imports OK."

# ── Step 3: write/merge .env ─────────────────────────────────────────────────
print_step "3/4" "Writing $ENV_FILE..."
env_kvs=(
    "OPENOBSERVE_URL=$O2_URL"
    "OPENOBSERVE_ORG=$O2_ORG"
    "OPENOBSERVE_AUTH_TOKEN=$O2_TOKEN"
)
[ -n "$O2_TRACES_STREAM" ] && env_kvs+=("OPENOBSERVE_TRACES_STREAM_NAME=$O2_TRACES_STREAM")
[ -n "$O2_LOGS_STREAM" ] && env_kvs+=("OPENOBSERVE_LOGS_STREAM_NAME=$O2_LOGS_STREAM")
# Append integration-specific extra env vars (one per line).
if [ -n "$INTEG_EXTRA_ENV" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && env_kvs+=("$line")
    done <<<"$INTEG_EXTRA_ENV"
fi
write_env_atomic "$ENV_FILE" "$PY" "${env_kvs[@]}"
print_success "$ENV_FILE updated."

# ── Step 4: print snippet + verification ─────────────────────────────────────
print_step "4/4" "Done. Next steps:"
print_snippet_block "$INTEG_SNIPPET" "$INTEG_INSTRUCTION"

# Also write the snippet to a file so the user can copy it even after the
# terminal scrollback is gone. Lives next to .env in the same dir.
SNIPPET_FILE="$(dirname "$ENV_FILE")/paste_me_${INTEGRATION}.py"
printf '%s\n' "$INTEG_SNIPPET" > "$SNIPPET_FILE"
print_info "Snippet also saved to: $SNIPPET_FILE"

# Tell the user which Python interpreter to run their app with — matches the
# one we pip-installed packages into. If the user's default `python3` differs
# from this, running `python3 my_app.py` will fail with ModuleNotFoundError.
if [ "$PY" != "python3" ]; then
    printf "\n${YELLOW}⚠ Run your app with: %s${NC}\n" "$PY"
    printf "  (packages were installed into %s's site-packages; bare 'python3' on this machine is a different interpreter and will not see them)\n" "$PY"
fi

if [ -n "$INTEG_VERIFY_STEP" ]; then
    printf "\n${CYAN}Verify it's working:${NC}\n%s\n" "$INTEG_VERIFY_STEP"
fi

# Detach the error trap on clean exit so EXIT trap from up top doesn't double-report.
trap - ERR INT TERM
exit 0
