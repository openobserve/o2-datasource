#!/bin/bash

# OpenObserve Database Collector Uninstaller
# Removes collectors installed by databases/install.sh: stops and deletes the
# service (systemd or launchd) and the instance's config dir. The shared
# otelcol-contrib binary stays unless --remove-binary is given.
#
# Usage:
#   curl -sSLo o2-db-uninstall.sh https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/uninstall.sh \
#     && sudo bash o2-db-uninstall.sh --name=postgres-localhost-5432

# Exit immediately if any command fails
set -e

# ─── Install Locations (must match install.sh) ────────────────────────────────
BIN_PATH="/usr/local/bin/otelcol-contrib"
CONFIG_ROOT="/etc/otelcol-o2"
SYSTEMD_DIR="/etc/systemd/system"
LAUNCHD_DIR="/Library/LaunchDaemons"
LAUNCHD_LOG_DIR="/var/log/otelcol-o2"

# ─── Defaults ─────────────────────────────────────────────────────────────────
INSTANCE_NAME=""
REMOVE_ALL=false
REMOVE_BINARY=false

# ─── Terminal Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Logging Helpers ──────────────────────────────────────────────────────────
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

# ─── Usage / Help Text ────────────────────────────────────────────────────────
usage() {
    cat << EOF
OpenObserve Database Collector Uninstaller

Usage:
    sudo bash $0 --name=NAME | --all [--remove-binary]

Options:
    --name=NAME          Instance to remove (the name install.sh printed, e.g. postgres-localhost-5432)
    --all                Remove every instance under $CONFIG_ROOT
    --remove-binary      Also delete $BIN_PATH (only when no instance is left)
    --help               Show this help message

Installed instances:
$(list_instances | sed 's/^/    /')
EOF
}

# Names of every installed instance (one per line)
list_instances() {
    local dir
    if [ -d "$CONFIG_ROOT" ]; then
        for dir in "$CONFIG_ROOT"/*/; do
            [ -d "$dir" ] && basename "$dir"
        done
    fi
    return 0
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --name=*)
            INSTANCE_NAME="${arg#*=}"
            ;;
        --all)
            REMOVE_ALL=true
            ;;
        --remove-binary)
            REMOVE_BINARY=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $arg"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$INSTANCE_NAME" ] && [ "$REMOVE_ALL" = false ] && [ "$REMOVE_BINARY" = false ]; then
    print_error "Specify --name=NAME or --all"
    usage
    exit 1
fi

if [ -n "$INSTANCE_NAME" ] && [ "$REMOVE_ALL" = true ]; then
    print_error "Use either --name or --all, not both"
    exit 1
fi

# Same character set install.sh produces; also stops "../" from escaping CONFIG_ROOT
if [ -n "$INSTANCE_NAME" ] && [[ ! "$INSTANCE_NAME" =~ ^[a-z0-9-]+$ ]]; then
    print_error "Invalid --name=$INSTANCE_NAME (expected lowercase letters, digits and '-')"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    print_error "This uninstaller removes files under /etc and /usr/local/bin; run it with sudo."
    exit 1
fi

# ─── Removal ──────────────────────────────────────────────────────────────────
# Stops and deletes one instance's service and config. Each step tolerates the
# piece already being gone, so a half-finished install can be cleaned up too.
remove_instance() {
    local name="$1"
    local unit="otelcol-o2-$name.service"
    local label="ai.openobserve.otelcol-o2.$name"
    local plist="$LAUNCHD_DIR/$label.plist"
    local found=false

    print_info "Removing instance: $name"

    # systemd (Linux)
    if [ -f "$SYSTEMD_DIR/$unit" ]; then
        found=true
        if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
        fi
        rm -f "$SYSTEMD_DIR/$unit"
        if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
            systemctl daemon-reload || true
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
        fi
        print_success "Removed systemd unit $unit"
    fi

    # launchd (macOS)
    if [ -f "$plist" ]; then
        found=true
        launchctl bootout "system/$label" 2>/dev/null || launchctl unload -w "$plist" 2>/dev/null || true
        rm -f "$plist"
        rm -f "$LAUNCHD_LOG_DIR/$name.log"
        print_success "Removed launchd daemon $label"
    fi

    # Config, credentials and run script
    if [ -d "$CONFIG_ROOT/$name" ]; then
        found=true
        rm -rf "${CONFIG_ROOT:?}/$name"
        print_success "Removed $CONFIG_ROOT/$name"
    fi

    if [ "$found" = false ]; then
        print_warning "Nothing found for instance '$name'"
        print_info "Installed instances: $(list_instances | tr '\n' ' ')"
        return 1
    fi
}

status=0
if [ "$REMOVE_ALL" = true ]; then
    instances=$(list_instances)
    if [ -z "$instances" ]; then
        print_info "No instances installed under $CONFIG_ROOT"
    fi
    for name in $instances; do
        remove_instance "$name" || status=1
    done
elif [ -n "$INSTANCE_NAME" ]; then
    remove_instance "$INSTANCE_NAME" || status=1
fi

# Drop the now-empty shared directories
rmdir "$CONFIG_ROOT" 2>/dev/null || true
rmdir "$LAUNCHD_LOG_DIR" 2>/dev/null || true

# ─── Binary ───────────────────────────────────────────────────────────────────
# Shared by every instance, so it is only removed on request and when unused
remaining=$(list_instances)
if [ "$REMOVE_BINARY" = true ]; then
    if [ -n "$remaining" ]; then
        print_warning "Keeping $BIN_PATH: still used by $(echo "$remaining" | tr '\n' ' ')"
    elif [ -f "$BIN_PATH" ]; then
        rm -f "$BIN_PATH"
        print_success "Removed $BIN_PATH"
    else
        print_info "$BIN_PATH is not installed"
    fi
elif [ -f "$BIN_PATH" ]; then
    print_info "Kept $BIN_PATH (pass --remove-binary to delete it)"
fi

echo ""
if [ "$status" -eq 0 ]; then
    print_success "Uninstall complete"
else
    print_warning "Uninstall finished with warnings"
fi
exit "$status"
