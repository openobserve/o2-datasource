#!/bin/bash
# o2-datasource / ai / agents / github-copilot / uninstall.sh
#
# Removes the OpenObserve-managed GitHub Copilot OTel env block from the
# user's shell profile(s). Counterpart to install.sh.

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
GitHub Copilot -> OpenObserve uninstaller

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

START="# >>> openobserve-github-copilot >>>"
END="# <<< openobserve-github-copilot <<<"

TARGETS=()
for profile in "$HOME/.zshrc" "$HOME/.bashrc"; do
    if [ -f "$profile" ] && grep -qF "$START" "$profile"; then
        TARGETS+=("$profile")
    fi
done

if (( ${#TARGETS[@]} == 0 )); then
    print_info "No OpenObserve GitHub Copilot block found in ~/.zshrc or ~/.bashrc. Nothing to do."
    exit 0
fi

print_info "Managed block found in: ${TARGETS[*]}"

if (( DRY_RUN == 1 )); then
    print_success "Dry-run mode: would remove the block from the file(s) above. No changes made."
    exit 0
fi

if (( FORCE == 0 )); then
    printf "Remove the OpenObserve Copilot env block from the file(s) above? [y/N] "
    read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) print_info "Aborted."; exit 0 ;;
    esac
fi

for profile in "${TARGETS[@]}"; do
    backup="${profile}.bak.$(date +%s)"
    cp "$profile" "$backup"
    print_info "Backed up $profile to $backup"
    tmp="$(mktemp)"
    awk -v start="$START" -v end="$END" '
        $0 == start {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' "$profile" > "$tmp"
    mv "$tmp" "$profile"
    print_info "Removed managed block from $profile"
done

print_success "Done. Open a new terminal for the change to take effect."
