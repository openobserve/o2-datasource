#!/bin/bash
# o2-datasource / ai / lib / common.sh
#
# Shared bash helpers sourced by every installer in this repo.
# Modeled on openobserve/o2-datasource/k8s/install.sh conventions.
#
# Installers fetch this file at startup; the harness sources it from
# the local checkout. Do not call this file directly.

# Terminal colors (NC = no color / reset).
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Respect --quiet by toggling O2_QUIET=1 before sourcing.
O2_QUIET="${O2_QUIET:-0}"

print_info() {
    [ "$O2_QUIET" = "1" ] && return 0
    printf "${BLUE}ℹ${NC} %s\n" "$1"
}

print_success() {
    [ "$O2_QUIET" = "1" ] && return 0
    printf "${GREEN}✓${NC} %s\n" "$1"
}

print_warning() {
    printf "${YELLOW}⚠${NC} %s\n" "$1" >&2
}

print_error() {
    printf "${RED}✗${NC} %s\n" "$1" >&2
}

print_step() {
    [ "$O2_QUIET" = "1" ] && return 0
    printf "\n${CYAN}[Step %s] %s${NC}\n" "$1" "$2"
}

# redact_secret: mask credentials in log output.
# Shows "abcd****wxyz" for inputs longer than 8 chars, "****" otherwise.
redact_secret() {
    local secret="$1"
    if [ ${#secret} -le 8 ]; then
        printf "****"
    else
        printf "%s****%s" "${secret:0:4}" "${secret: -4}"
    fi
}

# validate_base64: returns 0 if input is valid base64, non-zero otherwise.
# Accepts the payload portion only — strip "Basic " prefix before calling.
validate_base64() {
    local input="$1"
    if printf '%s' "$input" | base64 -d >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# validate_url: returns 0 if input starts with http:// or https://.
validate_url() {
    local url="$1"
    [[ "$url" =~ ^https?:// ]]
}

# strip_trailing_slash: echo input with any trailing /'s removed.
strip_trailing_slash() {
    local s="$1"
    while [[ "$s" == */ ]]; do s="${s%/}"; done
    printf '%s' "$s"
}

# retry_command: run "$@" up to RETRY_COUNT times, sleeping RETRY_DELAY between.
# Defaults: 3 attempts, 5s delay. Override via env.
retry_command() {
    local max_attempts="${RETRY_COUNT:-3}"
    local delay="${RETRY_DELAY:-5}"
    local attempt=1
    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        if (( attempt < max_attempts )); then
            print_warning "Attempt $attempt failed: $*. Retrying in ${delay}s..."
            sleep "$delay"
        fi
        ((attempt++))
    done
    print_error "Command failed after $max_attempts attempts: $*"
    return 1
}

# Cleanup-on-error infrastructure.
# Installer adds to RESOURCES_CREATED as it goes; on ERR/INT/TERM we list them.
RESOURCES_CREATED=()
TEMP_FILES=()

cleanup_on_error() {
    local exit_code=$?
    print_error "Installation failed (exit $exit_code). Cleaning up temp files..."
    for f in "${TEMP_FILES[@]:-}"; do
        [ -f "$f" ] && rm -f "$f"
    done
    if (( ${#RESOURCES_CREATED[@]} > 0 )); then
        print_warning "These resources may have been created — review and clean up if needed:"
        for r in "${RESOURCES_CREATED[@]}"; do
            print_info "  - $r"
        done
    fi
    exit "$exit_code"
}

# Silent counterpart of cleanup_on_error — runs on every EXIT so that even a
# clean `exit 0` cleans up temp files. cleanup_on_error already does this for
# the error path, but without an EXIT trap a successful run would leak any
# entry in TEMP_FILES (e.g. INTEGRATIONS_TMP in frameworks/setup.sh,
# SETUP_TMP in cursor/install.sh). Idempotent: if cleanup_on_error already ran,
# the files are gone and the `rm -f` is a no-op.
#
# Also handles $COMMON_SH if it looks like a curl|bash bootstrap temp. Each
# installer sets `trap 'rm -f "$COMMON_SH"' EXIT` before sourcing this file,
# but install_error_trap below replaces the EXIT trap — so we re-do the
# bootstrap cleanup here. macOS mktemp writes to /var/folders/, Linux to /tmp/.
cleanup_on_exit() {
    if [ -n "${COMMON_SH:-}" ] && [ -f "$COMMON_SH" ]; then
        case "$COMMON_SH" in
            /tmp/*|/var/folders/*) rm -f "$COMMON_SH" ;;
        esac
    fi
    for f in "${TEMP_FILES[@]:-}"; do
        [ -f "$f" ] && rm -f "$f"
    done
}

# Caller installs the trap via:  install_error_trap
install_error_trap() {
    trap cleanup_on_error ERR INT TERM
}

# Register cleanup_on_exit immediately at source time, so every installer
# (whether or not it calls install_error_trap) gets temp-file cleanup on a
# clean `exit 0`. The early `trap 'rm -f "$COMMON_SH"' EXIT` set BEFORE
# sourcing this file is replaced by this trap — that's fine because
# cleanup_on_exit also handles COMMON_SH (see its body).
trap cleanup_on_exit EXIT

# require_cmd: print_error + exit 1 if the given command isn't on PATH.
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Required command not found: $1"
        print_info "Install it and re-run."
        exit 1
    fi
}

# detect_python: echo a python3 command (>= 3.9) that has pip available, or empty.
# Many distros ship python with no pip module (apt's python3-minimal), so we
# verify both: version >= 3.9 AND `<py> -m pip --version` works.
#
# If $VIRTUAL_ENV is set, the venv's interpreter is preferred — otherwise we'd
# pick e.g. `python3.13` from $PATH, which resolves outside the venv (venvs
# typically only symlink `python` and `python3`, not version-pinned names),
# and `pip install` would fail with PEP 668 on the system Python.
detect_python() {
    local py
    # 1. Active venv wins — its python is the one the user has clearly opted into.
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "$VIRTUAL_ENV/bin/python" ]; then
        if "$VIRTUAL_ENV/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null \
           && "$VIRTUAL_ENV/bin/python" -m pip --version >/dev/null 2>&1; then
            printf '%s' "$VIRTUAL_ENV/bin/python"
            return 0
        fi
    fi
    # 2. The user's default `python3` — match it if it works. If we picked a
    #    different interpreter here, packages would install to one site-packages
    #    but the user's `python3 my_app.py` would find none of them.
    # 3. Only if `python3` is missing or lacks pip (e.g. Debian's python3-minimal),
    #    fall through to version-pinned names in descending order.
    for py in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9; do
        if command -v "$py" >/dev/null 2>&1; then
            if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null \
               && "$py" -m pip --version >/dev/null 2>&1; then
                printf '%s' "$py"
                return 0
            fi
        fi
    done
    return 1
}

# pip_install: install packages with venv awareness + PEP 668 fallback.
# Args: <python_cmd> <pkg> [<pkg> ...]
#
# Behavior:
#   - If $VIRTUAL_ENV is set, install into the venv (no --user, no fallback needed).
#   - Otherwise, try `pip install --user --upgrade` first.
#   - On PEP 668 errors, retry with `--break-system-packages --user --upgrade`.
pip_install() {
    local py="$1"; shift
    local pkgs=("$@")
    local out rc
    local base_args=(--upgrade)

    if [ -n "${VIRTUAL_ENV:-}" ]; then
        # Inside an active venv: pip installs into the venv's site-packages.
        # --user would point outside the venv and is rejected; PEP 668 doesn't apply.
        out=$("$py" -m pip install "${base_args[@]}" "${pkgs[@]}" 2>&1) && rc=0 || rc=$?
    else
        out=$("$py" -m pip install --user "${base_args[@]}" "${pkgs[@]}" 2>&1) && rc=0 || rc=$?
        if (( rc != 0 )) && printf '%s' "$out" | grep -q "externally-managed-environment"; then
            print_warning "PEP 668 detected — retrying with --break-system-packages"
            out=$("$py" -m pip install --break-system-packages --user "${base_args[@]}" "${pkgs[@]}" 2>&1) && rc=0 || rc=$?
        fi
    fi

    if (( rc != 0 )); then
        print_error "pip install failed:"
        printf '%s\n' "$out" >&2
        return 1
    fi
    [ "$O2_QUIET" = "1" ] || printf '%s\n' "$out" | tail -3
    return 0
}

# verify_imports: run a python `-c "import ...; import ..."` and report.
# Args: <python_cmd> "<import_block>"
verify_imports() {
    local py="$1"
    local block="$2"
    if "$py" -c "$block" 2>/tmp/o2_import_err; then
        return 0
    fi
    print_error "Import verification failed:"
    cat /tmp/o2_import_err >&2
    rm -f /tmp/o2_import_err
    return 1
}

# write_env_atomic: merge or create a .env file, preserving non-managed keys.
# Args: <env_file_path> <python_cmd> <key1=val1> [<key2=val2> ...]
#
# Behavior:
#   - Reads existing file (if any), parses key=value lines (skipping comments).
#   - Overwrites the managed keys passed in.
#   - Preserves unrelated keys and comment/blank lines verbatim.
#   - Backs up existing file to <path>.bak.<unix-ts> on first write.
#   - Atomic: writes to <path>.tmp then renames.
write_env_atomic() {
    local env_path="$1"; shift
    local py="$1"; shift
    local kvs=("$@")
    local backup=""
    if [ -f "$env_path" ]; then
        backup="${env_path}.bak.$(date +%s)"
        cp "$env_path" "$backup"
        RESOURCES_CREATED+=("backup: $backup")
        print_info "Backed up existing $env_path to $backup"
    fi
    # Use python for the merge so we get correct key handling.
    O2_ENV_PATH="$env_path" O2_ENV_KVS="$(printf '%s\n' "${kvs[@]}")" "$py" - <<'PY'
import os, sys, tempfile
path = os.environ["O2_ENV_PATH"]
kvs_raw = os.environ["O2_ENV_KVS"].strip().splitlines()
managed = {}
order = []
for line in kvs_raw:
    if "=" not in line:
        continue
    k, v = line.split("=", 1)
    if k not in managed:
        order.append(k)
    managed[k] = v

existing_lines = []
existing_keys = set()
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as f:
        for line in f.read().splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                existing_lines.append(line)
                continue
            if "=" in line:
                k = line.split("=", 1)[0].strip()
                if k in managed:
                    existing_lines.append(f"{k}={managed[k]}")
                    existing_keys.add(k)
                    continue
            existing_lines.append(line)

out_lines = list(existing_lines)
for k in order:
    if k not in existing_keys:
        out_lines.append(f"{k}={managed[k]}")

content = "\n".join(out_lines).rstrip("\n") + "\n"
d = os.path.dirname(os.path.abspath(path)) or "."
fd, tmp = tempfile.mkstemp(prefix=".env.", dir=d)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

# load_integration_data: extract one integration's metadata from integrations.json.
# Args: <integrations_json_path> <integration_name> <python_cmd>
# Prints fields to stdout as eval-able shell:
#   INTEG_PACKAGES="..." INTEG_VERIFY_IMPORTS="..." INTEG_SNIPPET="..." \
#   INTEG_INSTRUCTION="..." INTEG_EXTRA_ENV="..." INTEG_VERIFY="..."
load_integration_data() {
    local json_path="$1" name="$2" py="$3"
    O2_JSON="$json_path" O2_NAME="$name" "$py" - <<'PY'
import json, os, shlex, sys
path = os.environ["O2_JSON"]
name = os.environ["O2_NAME"]
with open(path) as f:
    data = json.load(f)
items = data.get("integrations", {})
if name not in items:
    valid = ", ".join(sorted(items.keys())) or "(none yet)"
    print(f"echo 'unknown integration: {name}. valid: {valid}' >&2; exit 1")
    sys.exit(0)
i = items[name]
def q(s):
    return shlex.quote(s if isinstance(s, str) else json.dumps(s))
packages = " ".join(i.get("packages", []))
verify_imports = "; ".join(i.get("verify_imports", []))
snippet = i.get("snippet", "")
instruction = i.get("instruction", "")
extra_env = "\n".join(f"{k}={v}" for k, v in i.get("extra_env", {}).items())
verify_step = i.get("verify_step", "")
print(f"INTEG_PACKAGES={q(packages)}")
print(f"INTEG_VERIFY_IMPORTS={q(verify_imports)}")
print(f"INTEG_SNIPPET={q(snippet)}")
print(f"INTEG_INSTRUCTION={q(instruction)}")
print(f"INTEG_EXTRA_ENV={q(extra_env)}")
print(f"INTEG_VERIFY_STEP={q(verify_step)}")
PY
}

# print_snippet_block: print a framed code block with the user-facing snippet.
print_snippet_block() {
    local snippet="$1" instruction="$2"
    [ "$O2_QUIET" = "1" ] && return 0
    printf "\n${CYAN}━━━ Paste this into your app ━━━${NC}\n"
    printf "%s\n" "$snippet"
    printf "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    [ -n "$instruction" ] && printf "%s\n" "$instruction"
}
