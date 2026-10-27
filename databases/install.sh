#!/bin/bash

# OpenObserve Database Collector Quick Installer
# Installs the upstream OpenTelemetry Collector Contrib (otelcol-contrib) as a
# system service that scrapes one database and ships its metrics (and, with
# --dbm, Database Monitoring events) to OpenObserve.
#
# Usage:
#   curl -sSLo o2-db-install.sh https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/install.sh \
#     && sudo bash o2-db-install.sh --db=postgres --host=localhost --port=5432 --db-user=myuser \
#        --o2-url=https://example.com --org-id=default --access-key=<base64> [--dbm]
#
# The database password is NEVER a flag. It comes from O2_DB_PASSWORD, from
# --password-file, or from a hidden prompt on the terminal (/dev/tty, so the
# prompt also works when the script itself arrives on stdin).
#
# Supported: Linux (systemd) and macOS (launchd), amd64 and arm64.
# Must stay bash 3.2 compatible (macOS /bin/bash): no associative arrays,
# no ${var,,}, no mapfile.

# Exit on any failure; -E makes the ERR trap fire inside functions too
set -Ee -o pipefail

# ─── Component Versions ───────────────────────────────────────────────────────
# Pinned to the version the OpenObserve setup cards verify the Database
# Monitoring recipes against (DBM_CONTRIB_VERSION in dbmShared.ts). v0.148.0 is
# the floor: older collectors reject the `events:` block as an unknown key.
OTELCOL_VERSION="${O2_OTELCOL_VERSION:-0.158.0}"
OTELCOL_VERSION="${OTELCOL_VERSION#v}"
OTELCOL_RELEASE_BASE="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download"

# ─── Network / Retry Settings ─────────────────────────────────────────────────
# Controls how many times failed network calls are retried and how long to wait
RETRY_COUNT="${RETRY_COUNT:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
# Seconds the service must stay up without restarting to count as healthy
HEALTH_WINDOW="${HEALTH_WINDOW:-20}"

# ─── Install Locations ────────────────────────────────────────────────────────
BIN_PATH="/usr/local/bin/otelcol-contrib"
CONFIG_ROOT="/etc/otelcol-o2"
SYSTEMD_DIR="/etc/systemd/system"
LAUNCHD_DIR="/Library/LaunchDaemons"
LAUNCHD_LOG_DIR="/var/log/otelcol-o2"
UNINSTALL_URL="https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/uninstall.sh"

# ─── Installation Defaults ────────────────────────────────────────────────────
# These are overridden by command-line flags parsed below; empty means
# "use the per-database default" (resolved after parsing)
DB=""
DB_HOST="localhost"
DB_PORT=""
DB_USER=""
DB_USER_SET=false
DB_NAME=""
O2_URL=""
ORG_ID=""
ACCESS_KEY=""
ENABLE_DBM=false
LOG_PATH=""
INSTANCE_NAME=""
PASSWORD_FILE=""
MONGO_TLS=false
NO_SERVICE=false
DRY_RUN=false
SKIP_CHECKSUM=false

# ─── Cleanup State ────────────────────────────────────────────────────────────
# Track what was created so we can report it if the install fails mid-way
RESOURCES_CREATED=()
WORK_DIR=""

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

# ─── Secret Redaction ─────────────────────────────────────────────────────────
# Masks credentials in log output, showing only first/last 4 characters
redact_secret() {
    local secret="$1"
    if [ ${#secret} -le 8 ]; then
        echo "****"
    else
        echo "${secret:0:4}****${secret: -4}"
    fi
}

# ─── Error Cleanup Handler ────────────────────────────────────────────────────
# Called automatically on ERR/INT/TERM; lists what was created before the failure.
# The work directory (downloads, staged configs) is removed by the EXIT trap.
cleanup_on_error() {
    trap - ERR INT TERM
    print_error "Installation failed."
    if [ ${#RESOURCES_CREATED[@]} -gt 0 ]; then
        print_warning "These were created or changed before the failure. Review and clean up if needed:"
        for resource in "${RESOURCES_CREATED[@]}"; do
            print_info "  - $resource"
        done
    fi
    exit 1
}

# Removes the temporary work directory; runs on every exit, success or failure
cleanup_work_dir() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

# Register the handlers to run on script error, user interrupt and exit
trap cleanup_on_error ERR INT TERM
trap cleanup_work_dir EXIT

# ─── Network Retry Wrapper ────────────────────────────────────────────────────
# Retries a command up to RETRY_COUNT times with RETRY_DELAY seconds between attempts.
# Takes the command as separate arguments (no eval), so values are never re-parsed.
retry_command() {
    local attempt=1
    while [ "$attempt" -le "$RETRY_COUNT" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$RETRY_COUNT" ]; then
            print_warning "Attempt $attempt failed. Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
        attempt=$((attempt + 1))
    done
    print_error "Command failed after $RETRY_COUNT attempts: $1 ..."
    return 1
}

# ─── Terminal Prompts ─────────────────────────────────────────────────────────
# Under `curl ... | bash` stdin is the script itself, so every prompt reads from
# /dev/tty. In containers / CI there may be no terminal at all.
have_tty() {
    { : < /dev/tty; } 2>/dev/null
}

# Asks a yes/no question (default No). With no terminal, continues with a
# warning so unattended installs are not blocked by a transient check.
confirm_or_exit() {
    local question="$1"
    local reply=""
    if ! have_tty; then
        print_warning "No terminal available to ask \"$question\"; continuing."
        return 0
    fi
    read -r -p "$question (y/N): " reply < /dev/tty
    if [[ ! "$reply" =~ ^[Yy] ]]; then
        print_info "Installation cancelled"
        trap - ERR INT TERM
        exit 1
    fi
}

# ─── Usage / Help Text ────────────────────────────────────────────────────────
usage() {
    cat << EOF
OpenObserve Database Collector Installer

Usage:
    sudo bash $0 --db=DB --o2-url=URL --org-id=ID --access-key=KEY [OPTIONS]

Required Options:
    --db=DB                  postgres | mysql | mariadb | sqlserver | mongodb | redis
    --o2-url=URL             OpenObserve instance URL (e.g., https://cloud.openobserve.ai)
    --org-id=ID              OpenObserve organization ID
    --access-key=KEY         Base64 encoded access key (email:passcode)

Database Connection:
    --host=HOST              Database host (default: localhost)
    --port=PORT              Database port (default: 5432 postgres, 3306 mysql/mariadb,
                             1433 sqlserver, 27017 mongodb, 6379 redis)
    --db-user=USER           Monitoring user (default: myuser postgres, otel for
                             mysql/mariadb/sqlserver/mongodb; redis: unused)
    --database=NAME          Database to connect to (default: postgres for postgres,
                             mysql for mysql/mariadb, master for sqlserver DBM)
    --password-file=PATH     Read the database password from the first line of PATH
    --tls                    mongodb: connect with verified TLS (default: no TLS)

Database Monitoring:
    --dbm                    Also install the Database Monitoring config
                             (postgres, mysql, mariadb, sqlserver only)
    --log-path=GLOB          Server log the deadlock recipe tails
                             (default: /var/log/postgresql/postgresql*.log for postgres,
                             /var/log/mysql/error.log for mysql/mariadb)

Installation:
    --name=NAME              Instance name (default: <db>-<host>-<port>, sanitized)
    --no-service             Write config + credentials and print the foreground run
                             command instead of installing a service (containers, no systemd)
    --skip-checksum          Install the collector even if its sha256 cannot be fetched
    --dry-run                Validate and render the config without installing anything
    --help                   Show this help message

Password Source (first match wins; never a flag):
    1. O2_DB_PASSWORD environment variable (use: sudo O2_DB_PASSWORD=... bash $0 ...)
    2. --password-file=PATH
    3. Hidden prompt on the terminal (redis: may be left empty for no AUTH)

Environment Variables:
    O2_OTELCOL_VERSION       otelcol-contrib version (default: 0.158.0)
    RETRY_COUNT              Number of retries for network operations (default: 3)
    RETRY_DELAY              Delay between retries in seconds (default: 5)
    HEALTH_WINDOW            Seconds the service must run without restarting (default: 20)
    HTTP_PROXY / HTTPS_PROXY / NO_PROXY   Honoured by curl and the collector

Examples:
    # PostgreSQL with Database Monitoring
    curl -sSLo o2-db-install.sh https://raw.githubusercontent.com/openobserve/o2-datasource/main/databases/install.sh \\
      && sudo bash o2-db-install.sh --db=postgres --host=localhost --port=5432 --db-user=myuser \\
         --o2-url=https://cloud.openobserve.ai --org-id=default \\
         --access-key=\$(echo -n "user@example.com:passcode" | base64) --dbm

    # Redis inside a container (no systemd): print the foreground command instead
    sudo bash o2-db-install.sh --db=redis --o2-url=https://cloud.openobserve.ai \\
      --org-id=default --access-key=base64key --no-service

    # Remove it again
    curl -sSLo o2-db-uninstall.sh $UNINSTALL_URL \\
      && sudo bash o2-db-uninstall.sh --name=postgres-localhost-5432

EOF
}

# ─── Input Validators ─────────────────────────────────────────────────────────
# Checks that the access key is valid base64; prevents silent auth failures later.
# The regex rejects whitespace/newlines that `base64 -d` would quietly skip.
validate_base64() {
    local input="$1"
    if [[ ! "$input" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || [ $(( ${#input} % 4 )) -ne 0 ]; then
        return 1
    fi
    # GNU and modern macOS accept -d; older macOS only -D
    if printf '%s' "$input" | base64 -d &>/dev/null; then
        return 0
    fi
    printf '%s' "$input" | base64 -D &>/dev/null
}

# Checks that a URL starts with http:// or https:// and has no characters that
# would break the YAML it is written into
validate_url() {
    local url="$1"
    local pattern='^https?://[^][:space:]"'\''`\\{}[]+$'
    [[ "$url" =~ $pattern ]]
}

# Lower-cases and replaces anything outside [a-z0-9-] so the name is safe as a
# directory, a systemd unit and a launchd label
sanitize_name() {
    local name
    name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | tr -s '-')
    name="${name#-}"
    name="${name%-}"
    printf '%s' "$name"
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────
# Map each --flag=value argument to its corresponding variable
for arg in "$@"; do
    case $arg in
        --db=*)
            DB="${arg#*=}"
            ;;
        --host=*)
            DB_HOST="${arg#*=}"
            ;;
        --port=*)
            DB_PORT="${arg#*=}"
            ;;
        --db-user=*)
            DB_USER="${arg#*=}"
            DB_USER_SET=true
            ;;
        --database=*)
            DB_NAME="${arg#*=}"
            ;;
        --o2-url=*)
            O2_URL="${arg#*=}"
            ;;
        --org-id=*)
            ORG_ID="${arg#*=}"
            ;;
        --access-key=*)
            ACCESS_KEY="${arg#*=}"
            ;;
        --dbm)
            ENABLE_DBM=true
            ;;
        --log-path=*)
            LOG_PATH="${arg#*=}"
            ;;
        --name=*)
            INSTANCE_NAME="${arg#*=}"
            ;;
        --password-file=*)
            PASSWORD_FILE="${arg#*=}"
            ;;
        --password=*|--db-password=*)
            print_error "Passwords are never accepted as a flag (they leak into shell history and ps)."
            print_info "Use O2_DB_PASSWORD, --password-file=PATH, or answer the prompt."
            exit 1
            ;;
        --tls)
            MONGO_TLS=true
            ;;
        --no-service)
            NO_SERVICE=true
            ;;
        --skip-checksum)
            SKIP_CHECKSUM=true
            ;;
        --dry-run)
            DRY_RUN=true
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

# ─── Required Parameter Validation ────────────────────────────────────────────
# Fail fast with a clear message if any required flag was not provided
print_info "Validating parameters..."
for required in DB O2_URL ORG_ID ACCESS_KEY; do
    if [ -z "${!required}" ]; then
        flag=$(printf '%s' "$required" | tr '[:upper:]_' '[:lower:]-')
        [ "$required" = "O2_URL" ] && flag="o2-url"
        print_error "Missing required parameter: --$flag"
        usage
        exit 1
    fi
done

# ─── Per-Database Defaults ────────────────────────────────────────────────────
# Defaults match the OpenObserve setup cards so the card's prepare SQL works as-is.
#   DEFAULT_*      : connection defaults
#   DB_CLIENT      : CLI used for the optional login check
#   DBM_SUPPORTED  : whether a Database Monitoring recipe exists for this engine
case "$DB" in
    postgres)
        DEFAULT_PORT=5432; DEFAULT_USER="myuser"; DEFAULT_DATABASE="postgres"
        DEFAULT_LOG_PATH="/var/log/postgresql/postgresql*.log"; DB_CLIENT="psql"; DBM_SUPPORTED=true
        ;;
    mysql)
        # Database "mysql", not the card's literal "otel": the card's prepare SQL
        # never creates an "otel" database, so connecting to it fails every
        # scrape with "Unknown database". "mysql" always exists, the grant's
        # SELECT ON *.* covers it, and it is the card's own DBM default.
        DEFAULT_PORT=3306; DEFAULT_USER="otel"; DEFAULT_DATABASE="mysql"
        DEFAULT_LOG_PATH="/var/log/mysql/error.log"; DB_CLIENT="mysql"; DBM_SUPPORTED=true
        ;;
    mariadb)
        DEFAULT_PORT=3306; DEFAULT_USER="otel"; DEFAULT_DATABASE="mysql"
        DEFAULT_LOG_PATH="/var/log/mysql/error.log"; DB_CLIENT="mariadb"; DBM_SUPPORTED=true
        ;;
    sqlserver)
        DEFAULT_PORT=1433; DEFAULT_USER="otel"; DEFAULT_DATABASE="master"
        DEFAULT_LOG_PATH=""; DB_CLIENT="sqlcmd"; DBM_SUPPORTED=true
        ;;
    mongodb)
        DEFAULT_PORT=27017; DEFAULT_USER="otel"; DEFAULT_DATABASE=""
        DEFAULT_LOG_PATH=""; DB_CLIENT="mongosh"; DBM_SUPPORTED=false
        ;;
    redis)
        DEFAULT_PORT=6379; DEFAULT_USER=""; DEFAULT_DATABASE=""
        DEFAULT_LOG_PATH=""; DB_CLIENT="redis-cli"; DBM_SUPPORTED=false
        ;;
    *)
        print_error "Unsupported --db=$DB. Choose one of: postgres, mysql, mariadb, sqlserver, mongodb, redis"
        exit 1
        ;;
esac

DB_PORT="${DB_PORT:-$DEFAULT_PORT}"
DB_USER="${DB_USER:-$DEFAULT_USER}"
DB_NAME="${DB_NAME:-$DEFAULT_DATABASE}"
LOG_PATH="${LOG_PATH:-$DEFAULT_LOG_PATH}"

# ─── Flag Combination Checks ──────────────────────────────────────────────────
if [ "$ENABLE_DBM" = true ] && [ "$DBM_SUPPORTED" != true ]; then
    print_error "--dbm is only available for postgres, mysql, mariadb and sqlserver (not $DB)"
    exit 1
fi

if [ "$MONGO_TLS" = true ] && [ "$DB" != "mongodb" ]; then
    print_warning "--tls only applies to mongodb; ignoring it for $DB"
fi

if [ "$DB" = "redis" ] && [ "$DB_USER_SET" = true ]; then
    print_warning "The redis receiver authenticates with a password only; ignoring --db-user"
fi

# ─── Value Format Checks ──────────────────────────────────────────────────────
# Every value below is written into YAML (and some into DSNs), so restrict them
# to characters that cannot break out of either
if [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || [ "$DB_PORT" -lt 1 ] || [ "$DB_PORT" -gt 65535 ]; then
    print_error "Invalid --port=$DB_PORT. Must be a number between 1 and 65535."
    exit 1
fi

if [[ ! "$DB_HOST" =~ ^[A-Za-z0-9._-]+$ ]]; then
    print_error "Invalid --host=$DB_HOST. Use a hostname or IPv4 address (letters, digits, '.', '-', '_')."
    exit 1
fi

if [ -n "$DB_USER" ] && [[ ! "$DB_USER" =~ ^[A-Za-z0-9._@+-]+$ ]]; then
    print_error "Invalid --db-user=$DB_USER. Allowed characters: letters, digits, '.', '_', '@', '+', '-'."
    exit 1
fi

if [ -n "$DB_NAME" ] && [[ ! "$DB_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    print_error "Invalid --database=$DB_NAME. Allowed characters: letters, digits, '.', '_', '-'."
    exit 1
fi

if [ -n "$LOG_PATH" ] && [[ ! "$LOG_PATH" =~ ^/[A-Za-z0-9._/*?+-]+$ ]]; then
    print_error "Invalid --log-path=$LOG_PATH. Must be an absolute path or glob without spaces, quotes or commas."
    exit 1
fi

if [[ ! "$ORG_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    print_error "Invalid --org-id=$ORG_ID. Allowed characters: letters, digits, '.', '_', '-'."
    exit 1
fi

# Validate the access key is properly base64-encoded before attempting install
if ! validate_base64 "$ACCESS_KEY"; then
    print_error "Invalid ACCESS_KEY format. Must be valid base64 encoded string."
    print_info "Generate with: echo -n 'email:passcode' | base64"
    exit 1
fi

# Reject malformed URLs early to avoid cryptic failures during data export
if ! validate_url "$O2_URL"; then
    print_error "Invalid URL format for --o2-url. Must start with http:// or https:// and contain no spaces or quotes."
    exit 1
fi
# Strip trailing slash so URL concatenation (e.g. /api/org) is consistent
ENDPOINT="${O2_URL%/}"

# ─── Instance Name ────────────────────────────────────────────────────────────
# One collector per database instance; the name keys the config dir and service
if [ -z "$INSTANCE_NAME" ]; then
    INSTANCE_NAME="$DB-$DB_HOST-$DB_PORT"
fi
SANITIZED_NAME=$(sanitize_name "$INSTANCE_NAME")
if [ -z "$SANITIZED_NAME" ]; then
    print_error "Invalid --name=$INSTANCE_NAME (nothing left after sanitizing)"
    exit 1
fi
if [ "$SANITIZED_NAME" != "$INSTANCE_NAME" ] && [ "$SANITIZED_NAME" != "$(sanitize_name "$DB-$DB_HOST-$DB_PORT")" ]; then
    print_warning "Instance name sanitized to: $SANITIZED_NAME"
fi
INSTANCE_NAME="$SANITIZED_NAME"

INSTANCE_DIR="$CONFIG_ROOT/$INSTANCE_NAME"
CONFIG_FILE="$INSTANCE_DIR/config.yaml"
DBM_CONFIG_FILE="$INSTANCE_DIR/dbm-config.yaml"
ENV_FILE="$INSTANCE_DIR/env"
RUN_SCRIPT="$INSTANCE_DIR/run.sh"
SYSTEMD_UNIT="otelcol-o2-$INSTANCE_NAME.service"
LAUNCHD_LABEL="ai.openobserve.otelcol-o2.$INSTANCE_NAME"
LAUNCHD_PLIST="$LAUNCHD_DIR/$LAUNCHD_LABEL.plist"
LAUNCHD_LOG="$LAUNCHD_LOG_DIR/$INSTANCE_NAME.log"

# ─── Platform Detection ───────────────────────────────────────────────────────
# Map uname output onto the collector release's os/arch asset names
case "$(uname -s)" in
    Linux) OS="linux" ;;
    Darwin) OS="darwin" ;;
    *)
        print_error "Unsupported OS: $(uname -s). This installer supports Linux and macOS."
        exit 1
        ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        print_error "Unsupported architecture: $(uname -m). Supported: amd64, arm64."
        exit 1
        ;;
esac

# Pick the service manager; --no-service skips this entirely
SERVICE_MANAGER="none"
if [ "$NO_SERVICE" = false ]; then
    if [ "$OS" = "darwin" ]; then
        SERVICE_MANAGER="launchd"
    elif [ -d /run/systemd/system ] && command -v systemctl &>/dev/null; then
        SERVICE_MANAGER="systemd"
    elif [ "$DRY_RUN" = false ]; then
        print_error "systemd is not running on this host (common in containers)."
        print_info "Re-run with --no-service to write the config and get a foreground run command."
        exit 1
    fi
fi

# ─── Prerequisites: Privileges and Tools ──────────────────────────────────────
# Writing /usr/local/bin and /etc needs root; a dry run touches neither
print_info "Checking prerequisites..."
if [ "$DRY_RUN" = false ] && [ "$(id -u)" -ne 0 ]; then
    print_error "This installer writes to /usr/local/bin and $CONFIG_ROOT; run it with sudo."
    exit 1
fi

for tool in curl tar; do
    if ! command -v "$tool" &>/dev/null; then
        print_error "$tool is not installed. Please install $tool first."
        exit 1
    fi
done

if command -v sha256sum &>/dev/null; then
    SHA256_CMD="sha256sum"
elif command -v shasum &>/dev/null; then
    SHA256_CMD="shasum -a 256"
else
    SHA256_CMD=""
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/o2-db-install.XXXXXX")
chmod 700 "$WORK_DIR"

# ─── Database Password ────────────────────────────────────────────────────────
# Source order: O2_DB_PASSWORD env, --password-file, hidden prompt on /dev/tty.
# A dry run renders configs only and never needs the password.
DB_PASSWORD=""
PASSWORD_SOURCE="none"
if [ "$DRY_RUN" = true ]; then
    PASSWORD_SOURCE="not needed for --dry-run"
elif [ -n "${O2_DB_PASSWORD+x}" ]; then
    DB_PASSWORD="$O2_DB_PASSWORD"
    PASSWORD_SOURCE="O2_DB_PASSWORD"
elif [ -n "$PASSWORD_FILE" ]; then
    if [ ! -r "$PASSWORD_FILE" ]; then
        print_error "Cannot read --password-file=$PASSWORD_FILE"
        exit 1
    fi
    # First line only; strip a trailing CR from files edited on Windows
    IFS= read -r DB_PASSWORD < "$PASSWORD_FILE" || true
    DB_PASSWORD="${DB_PASSWORD%$'\r'}"
    PASSWORD_SOURCE="--password-file"
elif have_tty; then
    if [ "$DB" = "redis" ]; then
        prompt_text="Redis password for $DB_HOST:$DB_PORT (Enter for none): "
    else
        prompt_text="Password for $DB user '$DB_USER' on $DB_HOST:$DB_PORT: "
    fi
    read -r -s -p "$prompt_text" DB_PASSWORD < /dev/tty
    echo
    PASSWORD_SOURCE="prompt"
elif [ "$DB" != "redis" ]; then
    print_error "No database password: set O2_DB_PASSWORD, pass --password-file, or run from a terminal."
    exit 1
fi

if [ "$DRY_RUN" = false ] && [ -z "$DB_PASSWORD" ] && [ "$DB" != "redis" ]; then
    print_error "The $DB password is empty."
    exit 1
fi

# The env file must stay one value per line for both systemd and bash
case "$DB_PASSWORD" in
    *$'\n'*|*$'\r'*)
        print_error "The database password contains a newline, which is not supported."
        exit 1
        ;;
esac

# DSN formats used by the Database Monitoring recipes break on a few characters.
# Warn rather than fail: the metrics pipeline is unaffected.
if [ "$ENABLE_DBM" = true ]; then
    case "$DB" in
        postgres)
            if [[ "$DB_PASSWORD" =~ [[:space:]\'\\] ]]; then
                print_warning "Password contains a space, quote or backslash; the DBM key=value DSN (host=... password=...) will fail to parse it."
            fi
            ;;
        sqlserver)
            if [[ "$DB_PASSWORD" == *";"* ]]; then
                print_warning "Password contains ';'; the DBM DSN (server=...;password=...) will fail to parse it."
            fi
            ;;
    esac
fi

# ─── Preflight: Database Reachability ─────────────────────────────────────────
# Portable TCP connect with a timeout (macOS has no `timeout` command)
tcp_check() {
    local host="$1" port="$2" seconds="${3:-5}" ticks=0 pid
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$ticks" -ge $((seconds * 10)) ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        sleep 0.1
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

print_info "Checking database reachability: $DB_HOST:$DB_PORT"
if tcp_check "$DB_HOST" "$DB_PORT" 5; then
    print_success "TCP connection to $DB_HOST:$DB_PORT succeeded"
    DB_REACHABLE=true
else
    DB_REACHABLE=false
    print_warning "Cannot open a TCP connection to $DB_HOST:$DB_PORT."
    print_info "Please verify the database is running and reachable from this host (firewall, bind address)."
    if [ "$DRY_RUN" = false ]; then
        confirm_or_exit "Continue anyway?"
    fi
fi

# ─── Preflight: Database Login ────────────────────────────────────────────────
# Optional: only when the engine's CLI is installed. Credentials are passed via
# the client's own environment variable, never on the command line (ps-visible).
# A failure here only warns; the collector reports the same error in its logs.
login_check() {
    case "$DB" in
        postgres)
            env PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
                psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -tAc "SELECT 1"
            ;;
        mysql|mariadb)
            env MYSQL_PWD="$DB_PASSWORD" "$DB_CLIENT" --protocol=TCP --connect-timeout=5 \
                -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -e "SELECT 1" "$DB_NAME"
            ;;
        sqlserver)
            env SQLCMDPASSWORD="$DB_PASSWORD" \
                sqlcmd -S "$DB_HOST,$DB_PORT" -U "$DB_USER" -C -l 5 -Q "SELECT 1"
            ;;
        mongodb)
            # Build the URI inside mongosh from env vars so the password never hits argv
            env O2_CHECK_PASSWORD="$DB_PASSWORD" O2_CHECK_USER="$DB_USER" \
                O2_CHECK_HOSTPORT="$DB_HOST:$DB_PORT" O2_CHECK_TLS="$MONGO_TLS" \
                mongosh --nodb --quiet --eval '
                    const e = process.env;
                    const uri = "mongodb://" + encodeURIComponent(e.O2_CHECK_USER) + ":" +
                        encodeURIComponent(e.O2_CHECK_PASSWORD) + "@" + e.O2_CHECK_HOSTPORT +
                        "/admin?serverSelectionTimeoutMS=5000" + (e.O2_CHECK_TLS === "true" ? "&tls=true" : "");
                    const r = new Mongo(uri).getDB("admin").runCommand({ serverStatus: 1 });
                    if (r.ok !== 1) { quit(1); }'
            ;;
        redis)
            # An empty REDISCLI_AUTH still sends AUTH, so only set it with a password
            local reply
            if [ -n "$DB_PASSWORD" ]; then
                reply=$(env REDISCLI_AUTH="$DB_PASSWORD" redis-cli -h "$DB_HOST" -p "$DB_PORT" PING 2>&1)
            else
                reply=$(redis-cli -h "$DB_HOST" -p "$DB_PORT" PING 2>&1)
            fi
            echo "$reply"
            [ "$reply" = "PONG" ]
            ;;
    esac
}

if [ "$DRY_RUN" = true ]; then
    print_info "Skipping login check (--dry-run)"
elif [ "$DB_REACHABLE" = true ] && command -v "$DB_CLIENT" &>/dev/null; then
    print_info "Checking login with $DB_CLIENT..."
    if login_output=$(login_check 2>&1); then
        print_success "Logged in to $DB as ${DB_USER:-default user}"
    else
        print_warning "Login check with $DB_CLIENT failed; the collector will likely fail the same way:"
        printf '%s\n' "$login_output" | tail -n 3 | sed 's/^/    /'
        print_info "Run the prepare SQL from databases/README.md for $DB, then re-run this installer."
    fi
else
    print_info "$DB_CLIENT not found; skipping login check"
fi

# ─── Preflight: OpenObserve Endpoint Reachability ─────────────────────────────
# Probe the OpenObserve endpoint before installing so data export issues surface early
print_info "Checking endpoint reachability: $ENDPOINT"
endpoint_reachable=false

# Try the base URL plus common health/API paths
# 2xx = success, 401/403 = endpoint exists but requires auth (expected), 404/5xx = bad endpoint
for test_path in "" "/healthz" "/api/$ORG_ID"; do
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 "$ENDPOINT$test_path" 2>/dev/null || true)

    # Treat 2xx, 401, and 403 as reachable
    if [[ "$http_code" =~ ^(2[0-9][0-9]|401|403)$ ]]; then
        endpoint_reachable=true
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            print_success "Endpoint is reachable (HTTP $http_code - requires authentication)"
        else
            print_success "Endpoint is reachable (HTTP $http_code)"
        fi
        break
    fi
done

if [ "$endpoint_reachable" = false ]; then
    print_warning "Cannot reach endpoint $ENDPOINT. Installation will proceed but data export may fail."
    print_info "Please verify:"
    print_info "  1. The endpoint URL is correct"
    print_info "  2. Network connectivity from this host to the endpoint"
    print_info "  3. Firewall rules / proxy settings allow outbound connections"
    if [ "$DRY_RUN" = false ]; then
        confirm_or_exit "Continue anyway?"
    fi
fi

# ─── Installation Summary ─────────────────────────────────────────────────────
# Print resolved configuration so the user can confirm what will be installed
print_success "Prerequisites check passed"
echo ""
print_info "Installation configuration:"
print_info "  Database:          $DB at $DB_HOST:$DB_PORT"
[ -n "$DB_USER" ] && [ "$DB" != "redis" ] && print_info "  Monitoring user:   $DB_USER"
[ -n "$DB_NAME" ] && print_info "  Database name:     $DB_NAME"
print_info "  Password:          $([ -n "$DB_PASSWORD" ] && echo "******** (hidden)" || echo "(none)") from $PASSWORD_SOURCE"
print_info "  Database Monitor:  $ENABLE_DBM"
[ "$ENABLE_DBM" = true ] && [ -n "$LOG_PATH" ] && print_info "  Deadlock log:      $LOG_PATH"
print_info "  Endpoint:          $ENDPOINT"
print_info "  Organization ID:   $ORG_ID"
print_info "  Access Key:        $(redact_secret "$ACCESS_KEY")"
print_info "  Instance name:     $INSTANCE_NAME"
print_info "  Collector:         otelcol-contrib $OTELCOL_VERSION ($OS/$ARCH)"
print_info "  Service:           $([ "$NO_SERVICE" = true ] && echo "none (--no-service)" || echo "$SERVICE_MANAGER")"
echo ""

# ─── Config Templates ─────────────────────────────────────────────────────────
# Each template is a VERBATIM copy of the matching OpenObserve setup card, so a
# diff against the card shows any drift. Placeholders ({host}, {port}, {url},
# {org}, {token}, {database}, {logpath}, {server}) and the card's literal demo
# credentials are substituted by render_config below, never edited in here.
#
# The Database Monitoring recipes are a PARSER CONTRACT with the OpenObserve
# ingest side (src/core/src/traces/db_monitoring/server_vantage.rs): field
# names, SQL aliases and regex capture groups must stay byte-for-byte.
#
# To re-sync: evaluate the *_DBM_CONFIG_YAML exports of dbmShared.ts (they are
# assembled from several template literals) and copy CONFIG_YAML from each card,
# then paste them between the markers unchanged.

# Source: openobserve web/src/components/ingestion/setupCard/content/postgres.ts (CONFIG_YAML)
tpl_metrics_postgres() {
    cat << '__O2_TPL_EOF__'
receivers:
  postgresql:
    endpoint: {host}:{port}
    transport: tcp
    username: myuser
    password: ${env:POSTGRESQL_PASSWORD}
    databases:
      - postgres
    connection_pool:
      max_idle_time: 10m
      max_lifetime: 0
      max_idle: 2
      max_open: 5

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 15
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [postgresql]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/mysql.ts (CONFIG_YAML)
tpl_metrics_mysql() {
    cat << '__O2_TPL_EOF__'
receivers:
  mysql:
    endpoint: "{host}:{port}"
    username: otel
    password: ${env:MYSQL_PASSWORD}
    database: otel
    collection_interval: 10s
    initial_delay: 1s
  sqlquery/mysql_limits:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 60s
    queries:
      - sql: "SELECT @@max_connections AS max_connections, '{host}:{port}' AS mysql_instance_endpoint"
        metrics:
          - metric_name: mysql.connection.max
            value_column: max_connections
            attribute_columns: [mysql_instance_endpoint]
            value_type: int
            data_type: gauge

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [mysql, sqlquery/mysql_limits]
      processors: [batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/mariadb.ts (CONFIG_YAML)
tpl_metrics_mariadb() {
    cat << '__O2_TPL_EOF__'
receivers:
  mysql:
    endpoint: "{host}:{port}"
    username: otel
    password: ${env:MYSQL_PASSWORD}
    database: otel
    collection_interval: 10s
    initial_delay: 1s

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [mysql]
      processors: [batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/sqlServer.ts (CONFIG_YAML)
tpl_metrics_sqlserver() {
    cat << '__O2_TPL_EOF__'
receivers:
  sqlserver:
    collection_interval: 10s
    username: otel
    password: "YourStrong@Passw0rd"
    server: {server}
    port: {port}

processors:
  batch:

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [sqlserver]
      processors: [batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/mongodb.ts (CONFIG_YAML)
tpl_metrics_mongodb() {
    cat << '__O2_TPL_EOF__'
receivers:
  mongodb:
    hosts:
      - endpoint: {host}:{port}
    username: otel
    password: password123
    collection_interval: 60s
    initial_delay: 1s
    tls:
      insecure: true
      insecure_skip_verify: true

processors:
  batch:
    send_batch_size: 10000
    timeout: 10s

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [mongodb]
      processors: [batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/redis.ts (CONFIG_YAML)
tpl_metrics_redis() {
    cat << '__O2_TPL_EOF__'
receivers:
  redis:
    endpoint: "{host}:{port}"
    collection_interval: 10s
    password: ${env:REDIS_PASSWORD}

processors:
  batch:
    send_batch_size: 10000
    send_batch_max_size: 11000
    timeout: 10s

exporters:
  otlphttp/openobserve:
    endpoint: {url}/api/{org}
    headers:
      Authorization: Basic {token}
      stream-name: default

service:
  pipelines:
    metrics:
      receivers: [redis]
      processors: [batch]
      exporters: [otlphttp/openobserve]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/dbmShared.ts (PG_DBM_CONFIG_YAML)
tpl_dbm_postgres() {
    cat << '__O2_TPL_EOF__'
receivers:
  sqlquery/pg_blocking:
    driver: postgres
    datasource: "host={host} port={port} user=${env:PGUSER} password=${env:PGPASS} dbname={database} sslmode=require"
    collection_interval: 10s
    # max_open_conn is SINGULAR. The plural max_open_conns is not a key
    # sqlqueryreceiver knows, and an unknown key here is silently ignored
    # rather than rejected -- the misspelling reads like a bound and enforces
    # nothing. Unset means 0, which means UNLIMITED.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT
            blocked.pid::text                                          AS blocked_pid,
            -- PER-SESSION datname, NOT current_database(). pg_stat_activity
            -- spans every database on the cluster while the scrape connects to
            -- one, so current_database() would stamp the scrape's database onto
            -- a lock convoy that happened in a different one -- silently
            -- misattributed rows, and a ?database= filter confidently wrong.
            coalesce(blocked.datname,'')                               AS pg_db,
            coalesce(blocked.usename,'')                               AS blocked_user,
            coalesce(blocked.application_name,'')                      AS blocked_app,
            coalesce(blocked.query,'')                                 AS blocked_query,
            coalesce(blocked.wait_event_type,'')                       AS wait_event_type,
            coalesce(blocked.wait_event,'')                            AS wait_event,
            coalesce(round(EXTRACT(EPOCH FROM (now()-blocked.query_start))::numeric,3),0)::text AS blocked_wait_s,
            blocking.pid::text                                         AS blocking_pid,
            coalesce(blocking.state,'')                                AS blocking_state,
            coalesce(blocking.application_name,'')                     AS blocking_app,
            coalesce(blocking.query,'')                                AS blocking_query,
            '{host}'                                                   AS server_address,
            'pg_blocking_chain'                                        AS o2_recipe
          FROM pg_stat_activity blocked
          JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
          JOIN pg_stat_activity blocking ON blocking.pid = b.pid
          -- Output-identical: only a Lock waiter can have blockers, so this
          -- removes only rows the LATERAL join drops anyway, and stops
          -- pg_blocking_pids() taking lock-manager state for every session.
          WHERE blocked.wait_event_type = 'Lock'
        logs:
          - body_column: blocked_query
            attribute_columns:
              [blocked_pid, pg_db, blocked_user, blocked_app, wait_event_type, wait_event,
               blocked_wait_s, blocking_pid, blocking_state, blocking_app,
               blocking_query, server_address, o2_recipe]
  filelog/pg_deadlocks:
    include: [{logpath}]
    start_at: end
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+ \['
    operators:
      - type: regex_parser
        regex: '^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \w+) \[(?P<pg_pid>\d+)\] (?:(?P<pg_user>[^@ ]+)@(?P<pg_db>\S+) app=(?P<pg_app>\S*) vxid=(?P<pg_vxid>\S*) txid=(?P<pg_txid>\S*) line=(?P<pg_line>\d+) (?:qid=(?P<pg_query_id>-?\d+) )?)?(?P<pg_severity>[A-Z][A-Z0-9]*):\s+(?P<pg_message>(?s).*)$'
        on_error: send
        timestamp:
          parse_from: attributes.ts
          layout: "%Y-%m-%d %H:%M:%S.%L %Z"
      # Already the record timestamp; left in place it lands as a stray ts column.
      - type: remove
        if: 'attributes.ts != nil'
        field: attributes.ts
      - type: add
        field: attributes.o2_pg_event
        value: other
      # IDENTITY. Without this every host reporting into _o2_dbm_server looks like
      # the same server: the read-time deadlock stitch groups on
      # (engine, instance, database), so untagged sides from two different hosts
      # could fuse into one fabricated multi-participant deadlock.
      - type: add
        field: attributes.server_address
        value: "{host}"
      - type: router
        routes:
          - expr: 'attributes.pg_message matches "^deadlock detected"'
            output: mark_deadlock
          - expr: 'attributes.pg_severity == "DETAIL" and attributes.pg_message matches "waits for .* blocked by process"'
            output: mark_deadlock
          # auto_explain entries (optional PG_DBM_AUTO_EXPLAIN_CONF step).
          # MUST route before the default: an unrouted entry keeps o2_pg_event
          # = "other" and filter/dbm silently drops it while the collector
          # reports healthy.
          - expr: 'attributes.pg_message matches "^duration: [\\d.]+ ms\\s+plan:"'
            output: mark_explain
          # Completed-statement durations (log_min_duration_statement). MUST
          # stay AFTER the explain route: an auto_explain entry begins
          # "duration:" too, and this route would otherwise steal every plan.
          - expr: 'attributes.pg_message matches "^duration:"'
            output: mark_duration
        default: emit
      - type: add
        id: mark_deadlock
        field: attributes.o2_pg_event
        value: deadlock
      - type: copy
        from: attributes.pg_pid
        to: attributes.deadlock_victim_pid
      - type: regex_parser
        parse_from: attributes.pg_message
        regex: 'Process (?P<dl_waiter_pid>\d+) waits for (?P<dl_lock_mode>\S+) on (?P<dl_lock_target>[^;]+); blocked by process (?P<dl_blocker_pid>\d+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.pg_message
        regex: '(?s)blocked by process \d+\.\s*\n\s*Process (?P<dl_waiter2_pid>\d+) waits for (?P<dl_lock_mode2>\S+) on (?P<dl_lock_target2>[^;]+); blocked by process (?P<dl_blocker2_pid>\d+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.pg_message
        regex: '(?s)Process (?P<dl_p1>\d+): (?P<dl_query_1>[^\n]+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.pg_message
        regex: '(?s)Process \d+: [^\n]+\n\s*Process (?P<dl_p2>\d+): (?P<dl_query_2>[^\n]+)'
        on_error: send
      - type: move
        from: attributes.pg_message
        to: attributes.o2_deadlock_raw
        output: emit
      # ---- AUTO_EXPLAIN (real executed plan) ----------------------------
      # The tag value MUST NOT be "other": filter/dbm drops on that value.
      - type: add
        id: mark_explain
        field: attributes.o2_pg_event
        value: explain
      # Header: the executed wall-clock duration, ahead of the plan document.
      - type: regex_parser
        if: 'attributes.pg_message != nil and attributes.pg_message matches "^duration: [\\d.]+ ms\\s+plan:"'
        parse_from: attributes.pg_message
        regex: '^duration: (?P<ae_duration_ms>[\d.]+) ms\s+plan:'
        on_error: send
      # Body: the whole JSON document, captured as ONE STRING attribute. Never
      # expand it into a nested object with a JSON-parsing operator: a nested
      # value in a canonicalized record rejects the ENTIRE ingest batch
      # (server_vantage.rs O2_DBM_PLAN).
      - type: regex_parser
        if: 'attributes.pg_message != nil and attributes.pg_message matches "plan:\\s*\\{"'
        parse_from: attributes.pg_message
        regex: '(?s)plan:\s*(?P<ae_plan_json>\{.*\})\s*$'
        on_error: send
      # DROP the message: the regex_parser above already lifted the plan into
      # ae_plan_json, which is what canonicalize_pg_auto_explain reads.
      #
      # A remove operator, not a bare deletion of this step -- the "output:
      # emit" routing is load-bearing. Without it an explain entry falls
      # through into the mark_duration branch below, whose ^duration: route
      # also matches an auto_explain line, and every plan is re-tagged
      # statement_duration.
      - type: remove
        field: attributes.pg_message
        output: emit
      # ---- STATEMENT DURATION (log_min_duration_statement) ---------------
      # The tag value MUST NOT stay "other": filter/dbm drops on that value,
      # and the backend canonicalizer dispatches on statement_duration. The
      # parser captures the phase word too (statement/execute/parse/bind) —
      # the backend keeps only completed EXECUTIONS, so the extended
      # protocol's parse/bind phase lines cannot triple-count a call.
      - type: add
        id: mark_duration
        field: attributes.o2_pg_event
        value: statement_duration
      - type: regex_parser
        parse_from: attributes.pg_message
        regex: '(?s)^duration: (?P<stmt_duration_ms>[\d.]+) ms\s+(?P<stmt_kind>statement|execute [^:]*|parse [^:]*|bind [^:]*):\s+(?P<stmt_text>.*)$'
        on_error: send
        output: emit
      - type: noop
        id: emit
  sqlquery/pg_table_stats:
    driver: postgres
    datasource: "host={host} port={port} user=${env:PGUSER} password=${env:PGPASS} dbname={database} sslmode=require"
    # 300s, not 60s: pg_total_relation_size() walks the catalog and filesystem
    # metadata for every fork of every relation once per table per tick, so
    # cost is O(your schema).
    collection_interval: 300s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT n.nspname                                    AS schema_name,
                 c.relname                                    AS table_name,
                 pg_total_relation_size(c.oid)::text          AS total_bytes,
                 pg_relation_size(c.oid)::text                AS heap_bytes,
                 coalesce(s.seq_scan,0)::text                 AS seq_scan,
                 coalesce(s.seq_tup_read,0)::text             AS seq_tup_read,
                 coalesce(s.idx_scan,0)::text                 AS idx_scan,
                 coalesce(s.n_live_tup,0)::text               AS n_live_tup,
                 coalesce(s.n_dead_tup,0)::text               AS n_dead_tup,
                 coalesce(s.n_mod_since_analyze,0)::text      AS n_mod_since_analyze,
                 coalesce(s.last_vacuum::text,'')             AS last_vacuum,
                 coalesce(s.last_autovacuum::text,'')         AS last_autovacuum,
                 coalesce(s.last_analyze::text,'')            AS last_analyze,
                 coalesce(s.autovacuum_count,0)::text         AS autovacuum_count,
                 age(c.relfrozenxid)::text                    AS frozen_xid_age,
                 CASE WHEN coalesce(s.n_live_tup,0) > 0
                      THEN round(100.0*s.n_dead_tup/(s.n_live_tup+s.n_dead_tup),2)::text
                      ELSE '0' END                            AS dead_tup_pct,
                 '{host}'                                     AS server_address,
                 'pg_table_stats'                             AS o2_recipe
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
          WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema')
            -- The bound. Deliberately NOT a LIMIT: a LIMIT with no stable
            -- ORDER BY drops a different set of tables each tick and the tab
            -- flickers; this drops the same ones.
            --
            -- n_live_tup ALONE IS NOT THE TEST. It is a statistics estimate
            -- that stays 0 until autovacuum or a manual ANALYZE first runs, so
            -- gating on it hid every table on a freshly loaded database —
            -- measured: 5 populated tables, 0 rows returned, and Postgres
            -- absent from Table health until ANALYZE was run by hand. That is
            -- precisely when someone opens the tab to look at a new database.
            -- Size comes from the catalog and needs no ANALYZE, so a relation
            -- that occupies pages is real whatever the estimator has recorded.
            AND (coalesce(s.n_live_tup, 0) > 0
                 OR pg_total_relation_size(c.oid) > 0)
        logs:
          - body_column: table_name
            attribute_columns:
              [schema_name, total_bytes, heap_bytes, seq_scan, seq_tup_read,
               idx_scan, n_live_tup, n_dead_tup, n_mod_since_analyze,
               last_vacuum, last_autovacuum, last_analyze, autovacuum_count,
               frozen_xid_age, dead_tup_pct, server_address, o2_recipe]
  sqlquery/pg_index_stats:
    driver: postgres
    datasource: "host={host} port={port} user=${env:PGUSER} password=${env:PGPASS} dbname={database} sslmode=require"
    # 300s, matching pg_table_stats and for the same reason: one
    # pg_relation_size() plus one pg_get_indexdef() per INDEX per tick.
    collection_interval: 300s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT s.schemaname                                  AS schema_name,
                 s.relname                                     AS table_name,
                 s.indexrelname                                AS index_name,
                 coalesce(s.idx_scan,0)::text                  AS idx_scan,
                 coalesce(s.idx_tup_read,0)::text              AS idx_tup_read,
                 coalesce(s.idx_tup_fetch,0)::text             AS idx_tup_fetch,
                 pg_relation_size(s.indexrelid)::text          AS index_bytes,
                 (i.indisunique OR i.indisprimary)::text       AS is_unique,
                 coalesce(pg_get_indexdef(s.indexrelid),'')    AS index_def,
                 '{host}'                                      AS server_address,
                 'pg_index_stats'                              AS o2_recipe
          FROM pg_stat_user_indexes s
          JOIN pg_index i ON i.indexrelid = s.indexrelid
          WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
        logs:
          - body_column: index_def
            attribute_columns:
              [schema_name, table_name, index_name, idx_scan, idx_tup_read,
               idx_tup_fetch, index_bytes, is_unique, server_address, o2_recipe]
  postgresql/dbm_events:
    endpoint: "{host}:{port}"
    transport: tcp
    username: ${env:PGUSER}
    password: ${env:PGPASS}
    databases: [{database}]
    tls:
      insecure: true
    collection_interval: 10s
    query_sample_collection:
      max_rows_per_query: 1000
    top_query_collection:
      top_n_query: 200
      max_explain_each_interval: 200
      query_plan_cache_size: 1000
      # DELIBERATE DEVIATION FROM UPSTREAM, WHICH DEFAULTS TO 60s, so an
      # "align with upstream" pass does not revert it silently. It multiplies
      # every per-cycle cost, including the EXPLAIN pass
      # max_explain_each_interval bounds: the ceiling is 200 x 240 = 48,000
      # EXPLAINs/hour against a measured real rate of 1,775. So do NOT cut the
      # budget, and do NOT shorten query_plan_cache_ttl to catch plan
      # regressions sooner -- a shorter TTL pushes more queries back through
      # the cycle and multiplies the one cost here that is real.
      collection_interval: 15s
    # ON. These two events fill the Activity tab and the server-side Top
    # queries. Upstream has shipped them default-OFF since v0.148.0, so without
    # this block the collector looks healthy and emits ZERO events. Set one to
    # false to trim cost, but the block itself must STAY -- and events: must
    # stay a TOP-LEVEL receiver key, never nested inside the blocks above.
    events:
      db.server.query_sample: { enabled: true }
      db.server.top_query: { enabled: true }

processors:
  # Keep ONLY the records the Database Monitoring pages read. Load-bearing, not
  # tidiness: the filelog receivers tail the WHOLE database log, so without
  # this every ordinary log line lands in _o2_dbm_server too and swamps the tagged
  # rows. A record is ours if a recipe tagged it -- sqlquery rows carry
  # o2_recipe, filelog rows carry o2_pg_event / o2_my_event / o2_maria_event.
  filter/dbm:
    error_mode: ignore
    logs:
      log_record:
        # Tests the VALUE, not just presence. Every filelog pipeline stamps its
        # o2_*_event = "other" on EVERY line before routing (so the router has a
        # default), which means a nil-check keeps the whole error log — the exact
        # noise this filter exists to drop. Only the classified events, and the
        # sqlquery recipes' o2_recipe rows, are ours.
        #
        # o2_maria_event MUST be listed here. It is a separate key from
        # o2_my_event by design (see MARIADB_DEADLOG_RECEIVER), so omitting it
        # would drop every MariaDB deadlock while the pipeline looked healthy.
        - 'attributes["o2_recipe"] == nil and (attributes["o2_pg_event"] == nil or attributes["o2_pg_event"] == "other") and (attributes["o2_my_event"] == nil or attributes["o2_my_event"] == "other") and (attributes["o2_maria_event"] == nil or attributes["o2_maria_event"] == "other")'
  # SELF-PROTECTION. This collector usually runs on the CUSTOMER'S DATABASE
  # HOST: the filelog receivers read the database log as fast as it grows, so
  # with nothing between them and a stalled exporter the heap absorbs the
  # difference until the OOM killer ends it -- and the stall is most likely
  # during exactly the incident that produced the volume.
  #
  # MUST BE FIRST in every pipeline's processors list: memory_limiter applies
  # back-pressure to whatever is UPSTREAM of it, so a processor listed before
  # it is outside the guard. When over the soft limit it refuses batches, which
  # propagates back into the receivers and makes the collector SHED rather than
  # grow.
  memory_limiter:
    check_interval: 1s
    limit_mib: 768
    spike_limit_mib: 192
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  otlphttp/openobserve_dbm:
    logs_endpoint: {url}/api/{org}/v1/logs
    headers:
      Authorization: Basic {token}
      stream-name: _o2_dbm_server
    # THE OTHER HALF OF THE OOM GUARD (see memory_limiter above). Left at its
    # defaults the sending queue is effectively an unbounded in-memory buffer,
    # and retry_on_failure with no deadline re-queues batches that will never
    # succeed. Beyond the queue the collector DROPS, which is correct here: a
    # gap in the Deadlocks timeline beats a dead collector on a database host.
    # The queue is IN MEMORY and deliberately not persistent -- persistence
    # needs a storage: extension and a writable state directory on the database
    # host.
    sending_queue:
      enabled: true
      queue_size: 500
    retry_on_failure:
      enabled: true
      max_elapsed_time: 300s

service:
  pipelines:
    logs:
      receivers: [sqlquery/pg_blocking, filelog/pg_deadlocks, sqlquery/pg_table_stats, sqlquery/pg_index_stats]
      # memory_limiter FIRST — it back-pressures what is upstream of it, so
      # anything listed before it runs outside the guard.
      processors: [memory_limiter, filter/dbm, batch]
      exporters: [otlphttp/openobserve_dbm]
    logs/dbm_events:
      receivers: [postgresql/dbm_events]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/openobserve_dbm]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/dbmShared.ts (MYSQL_DBM_CONFIG_YAML)
tpl_dbm_mysql() {
    cat << '__O2_TPL_EOF__'
receivers:
  sqlquery/mysql_locks:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 10s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT CAST(w.REQUESTING_ENGINE_TRANSACTION_ID AS CHAR) AS waiting_trx,
                 -- PER-SESSION database, from PROCESSLIST joined on the
                 -- transaction's thread id. innodb_trx has NO database column
                 -- of its own, so the waiting session's current schema is the
                 -- only per-row database this source can supply.
                 COALESCE(rp.DB, '')                              AS my_db,
                 CAST(w.BLOCKING_ENGINE_TRANSACTION_ID AS CHAR)   AS blocking_trx,
                 COALESCE(rt.trx_mysql_thread_id, 0)              AS waiting_thread,
                 COALESCE(bt.trx_mysql_thread_id, 0)              AS blocking_thread,
                 COALESCE(LEFT(rt.trx_query,500), '')             AS waiting_query,
                 COALESCE(LEFT(bt.trx_query,500), '')             AS blocking_query,
                 COALESCE(rt.trx_state,'')                        AS waiting_state,
                 COALESCE(bt.trx_state,'')                        AS blocking_state,
                 CAST(COALESCE(TIMESTAMPDIFF(SECOND, rt.trx_wait_started, NOW()),0) AS CHAR) AS wait_secs,
                 '{host}'                                         AS server_address,
                 'mysql_lock_waits'                               AS o2_recipe
          FROM performance_schema.data_lock_waits w
          LEFT JOIN information_schema.innodb_trx rt
                 ON rt.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID
          LEFT JOIN information_schema.innodb_trx bt
                 ON bt.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
          LEFT JOIN information_schema.PROCESSLIST rp
                 ON rp.ID = rt.trx_mysql_thread_id
        logs:
          - body_column: waiting_query
            attribute_columns:
              [waiting_trx, blocking_trx, my_db, waiting_thread, blocking_thread,
               blocking_query, waiting_state, blocking_state, wait_secs, server_address, o2_recipe]
  filelog/mysql_deadlocks:
    include: [{logpath}]
    start_at: end
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    operators:
      - type: regex_parser
        regex: '^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z) (?P<my_thread>\d+) \[(?P<my_severity>\w+)\] \[(?P<my_code>[^\]]+)\] \[(?P<my_subsys>[^\]]+)\] (?P<my_message>(?s).*)$'
        on_error: send
        timestamp:
          parse_from: attributes.ts
          layout: "%Y-%m-%dT%H:%M:%S.%fZ"
      # Already the record timestamp; left in place it lands as a stray ts column.
      - type: remove
        if: 'attributes.ts != nil'
        field: attributes.ts
      - type: add
        field: attributes.o2_my_event
        value: other
      # IDENTITY. Without this every host reporting into _o2_dbm_server looks like
      # the same server: the read-time deadlock stitch groups on
      # (engine, instance, database), so untagged sides from two different hosts
      # could fuse into one fabricated multi-participant deadlock.
      - type: add
        field: attributes.server_address
        value: "{host}"
      - type: router
        routes:
          - expr: 'attributes.my_code == "MY-012468" or attributes.my_code == "MY-012469"'
            output: my_dl
          # Anchored on the markers InnoDB actually writes, NOT on the word
          # "deadlock": a bare substring stamps ordinary notes that merely
          # mention it (e.g. "deadlock avoidance is deprecated") as deadlocks
          # carrying no transaction, query or victim.
          - expr: 'attributes.my_message != nil and attributes.my_message matches "TRANSACTION|Transactions deadlock detected|WE ROLL BACK TRANSACTION"'
            output: my_dl
        default: my_emit
      - type: add
        id: my_dl
        field: attributes.o2_my_event
        value: deadlock
      - type: regex_parser
        parse_from: attributes.my_message
        regex: '(?s)\*\*\* \((?P<my_trx_side>\d+)\) TRANSACTION:\s*\nTRANSACTION (?P<my_trx_id>\d+).*?MySQL thread id (?P<my_trx_thread>\d+),[^\n]*?query id \d+ (?P<my_trx_host>\S+) (?P<my_trx_user>\S+)[^\n]*\n(?P<my_trx_query>[^\n]+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.my_message
        # my_db is captured from the SCHEMA HALF of the qualified table name:
        # InnoDB writes the locked object as db.table, and this is the ONLY
        # place the MySQL error log states the database. detect_database reads
        # my_db.
        #
        # THIS IS A DIFFERENT RECORD FROM THE PARTICIPANT, which is why the two
        # extra captures exist. `line_start_pattern` splits on the timestamp, so
        # the RECORD LOCKS line can never share a record with the
        # `*** (N) TRANSACTION:` block above it. `my_lock_side` and
        # `my_lock_trx_id` are what make the two joinable at merge time --
        # without them the lock detail is thrown away and the database comes
        # back null, so the Deadlocks tab's `?database=` filter cannot work.
        regex: '(?s)\*\*\* \((?P<my_lock_side>\d+)\) (?:HOLDS THE LOCK|WAITING FOR THIS LOCK).*?RECORD LOCKS space id \d+ page no \d+ n bits \d+ index (?P<my_lock_index>\S+) of table (?P<my_lock_table>`?(?P<my_db>[^`. ]+)`?\.\S+) trx id (?P<my_lock_trx_id>\d+) (?P<my_lock_mode>lock_mode \S+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.my_message
        regex: '\*\*\* WE ROLL BACK TRANSACTION \((?P<my_victim_side>\d+)\)'
        on_error: send
        output: my_emit
      - type: noop
        id: my_emit
  sqlquery/mysql_table_stats:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 60s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT t.TABLE_SCHEMA                                        AS schema_name,
                 t.TABLE_NAME                                          AS table_name,
                 CAST(COALESCE(t.DATA_LENGTH,0) + COALESCE(t.INDEX_LENGTH,0) AS CHAR) AS total_bytes,
                 CAST(COALESCE(t.DATA_LENGTH,0) AS CHAR)               AS heap_bytes,
                 CAST(COALESCE(s.n_rows, t.TABLE_ROWS, 0) AS CHAR)     AS n_live_tup,
                 COALESCE(CAST(s.last_update AS CHAR), '')             AS last_analyze,
                 '{host}'                                              AS server_address,
                 'mysql_table_stats'                                   AS o2_recipe
          FROM information_schema.TABLES t
          LEFT JOIN mysql.innodb_table_stats s
                 ON s.database_name = t.TABLE_SCHEMA AND s.table_name = t.TABLE_NAME
          WHERE t.TABLE_TYPE = 'BASE TABLE'
            AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
        logs:
          - body_column: table_name
            attribute_columns:
              [schema_name, total_bytes, heap_bytes, n_live_tup, last_analyze,
               server_address, o2_recipe]
  sqlquery/mysql_index_stats:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 60s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT st.TABLE_SCHEMA                                       AS schema_name,
                 st.TABLE_NAME                                         AS table_name,
                 st.INDEX_NAME                                         AS index_name,
                 CAST(COALESCE(io.COUNT_READ, 0) AS CHAR)              AS idx_scan,
                 CAST(COALESCE(sz.stat_value, 0) * @@innodb_page_size AS CHAR) AS index_bytes,
                 CASE WHEN MIN(st.NON_UNIQUE) = 0 THEN 'true' ELSE 'false' END AS is_unique,
                 CONCAT('INDEX ', st.INDEX_NAME, ' ON ', st.TABLE_SCHEMA, '.', st.TABLE_NAME,
                        ' (', GROUP_CONCAT(COALESCE(st.COLUMN_NAME, CONCAT('(', st.EXPRESSION, ')'))
                                           ORDER BY st.SEQ_IN_INDEX SEPARATOR ', '), ')') AS index_def,
                 '{host}'                                              AS server_address,
                 'mysql_index_stats'                                   AS o2_recipe
          FROM information_schema.STATISTICS st
          LEFT JOIN performance_schema.table_io_waits_summary_by_index_usage io
                 ON io.OBJECT_SCHEMA = st.TABLE_SCHEMA AND io.OBJECT_NAME = st.TABLE_NAME
                AND io.INDEX_NAME = st.INDEX_NAME
          LEFT JOIN mysql.innodb_index_stats sz
                 ON sz.database_name = st.TABLE_SCHEMA AND sz.table_name = st.TABLE_NAME
                AND sz.index_name = st.INDEX_NAME AND sz.stat_name = 'size'
          WHERE st.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
          GROUP BY st.TABLE_SCHEMA, st.TABLE_NAME, st.INDEX_NAME, io.COUNT_READ, sz.stat_value
        logs:
          - body_column: index_def
            attribute_columns:
              [schema_name, table_name, index_name, idx_scan, index_bytes,
               is_unique, server_address, o2_recipe]
  mysql/dbm_events:
    endpoint: "{host}:{port}"
    username: ${env:MYSQL_USER}
    password: ${env:MYSQL_PASSWORD}
    database: {database}
    collection_interval: 10s
    query_sample_collection:
      # mysqlreceiver's OWN default -- NOT Postgres's 1000; the two receivers
      # diverge deliberately (see the spelling asymmetry noted above).
      max_rows_per_query: 100
    top_query_collection:
      top_query_count: 200
      # DELIBERATE DEVIATION FROM UPSTREAM, WHICH DEFAULTS TO 60s -- the same
      # call the Postgres receiver makes. It multiplies every per-cycle cost,
      # so an "align with upstream" pass must not revert it silently alongside
      # the block's other knobs.
      collection_interval: 15s
      lookback_time: 120
      query_plan_cache_size: 1000
    # ON. These two events fill the Activity tab and the server-side Top
    # queries. Upstream has shipped them default-OFF since v0.148.0, so without
    # this block the collector looks healthy and emits ZERO events. Set one to
    # false to trim cost, but the block itself must STAY -- and events: must
    # stay a TOP-LEVEL receiver key, never nested inside the blocks above.
    events:
      db.server.query_sample: { enabled: true }
      db.server.top_query: { enabled: true }

processors:
  # Keep ONLY the records the Database Monitoring pages read. Load-bearing, not
  # tidiness: the filelog receivers tail the WHOLE database log, so without
  # this every ordinary log line lands in _o2_dbm_server too and swamps the tagged
  # rows. A record is ours if a recipe tagged it -- sqlquery rows carry
  # o2_recipe, filelog rows carry o2_pg_event / o2_my_event / o2_maria_event.
  filter/dbm:
    error_mode: ignore
    logs:
      log_record:
        # Tests the VALUE, not just presence. Every filelog pipeline stamps its
        # o2_*_event = "other" on EVERY line before routing (so the router has a
        # default), which means a nil-check keeps the whole error log — the exact
        # noise this filter exists to drop. Only the classified events, and the
        # sqlquery recipes' o2_recipe rows, are ours.
        #
        # o2_maria_event MUST be listed here. It is a separate key from
        # o2_my_event by design (see MARIADB_DEADLOG_RECEIVER), so omitting it
        # would drop every MariaDB deadlock while the pipeline looked healthy.
        - 'attributes["o2_recipe"] == nil and (attributes["o2_pg_event"] == nil or attributes["o2_pg_event"] == "other") and (attributes["o2_my_event"] == nil or attributes["o2_my_event"] == "other") and (attributes["o2_maria_event"] == nil or attributes["o2_maria_event"] == "other")'
  # SELF-PROTECTION. This collector usually runs on the CUSTOMER'S DATABASE
  # HOST: the filelog receivers read the database log as fast as it grows, so
  # with nothing between them and a stalled exporter the heap absorbs the
  # difference until the OOM killer ends it -- and the stall is most likely
  # during exactly the incident that produced the volume.
  #
  # MUST BE FIRST in every pipeline's processors list: memory_limiter applies
  # back-pressure to whatever is UPSTREAM of it, so a processor listed before
  # it is outside the guard. When over the soft limit it refuses batches, which
  # propagates back into the receivers and makes the collector SHED rather than
  # grow.
  memory_limiter:
    check_interval: 1s
    limit_mib: 768
    spike_limit_mib: 192
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  otlphttp/openobserve_dbm:
    logs_endpoint: {url}/api/{org}/v1/logs
    headers:
      Authorization: Basic {token}
      stream-name: _o2_dbm_server
    # THE OTHER HALF OF THE OOM GUARD (see memory_limiter above). Left at its
    # defaults the sending queue is effectively an unbounded in-memory buffer,
    # and retry_on_failure with no deadline re-queues batches that will never
    # succeed. Beyond the queue the collector DROPS, which is correct here: a
    # gap in the Deadlocks timeline beats a dead collector on a database host.
    # The queue is IN MEMORY and deliberately not persistent -- persistence
    # needs a storage: extension and a writable state directory on the database
    # host.
    sending_queue:
      enabled: true
      queue_size: 500
    retry_on_failure:
      enabled: true
      max_elapsed_time: 300s

service:
  pipelines:
    logs:
      receivers: [sqlquery/mysql_locks, filelog/mysql_deadlocks, sqlquery/mysql_table_stats, sqlquery/mysql_index_stats]
      # memory_limiter FIRST — it back-pressures what is upstream of it, so
      # anything listed before it runs outside the guard.
      processors: [memory_limiter, filter/dbm, batch]
      exporters: [otlphttp/openobserve_dbm]
    logs/dbm_events:
      receivers: [mysql/dbm_events]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/openobserve_dbm]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/dbmShared.ts (MARIADB_DBM_CONFIG_YAML)
tpl_dbm_mariadb() {
    cat << '__O2_TPL_EOF__'
receivers:
  sqlquery/mariadb_locks:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 10s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT CAST(w.requesting_trx_id AS CHAR)                AS waiting_trx,
                 -- PER-SESSION database, from PROCESSLIST joined on the
                 -- transaction's thread id. innodb_trx has NO database column
                 -- of its own, so the waiting session's current schema is the
                 -- only per-row database this source can supply.
                 COALESCE(rp.DB, '')                              AS my_db,
                 CAST(w.blocking_trx_id AS CHAR)                  AS blocking_trx,
                 COALESCE(rt.trx_mysql_thread_id, 0)              AS waiting_thread,
                 COALESCE(bt.trx_mysql_thread_id, 0)              AS blocking_thread,
                 COALESCE(LEFT(rt.trx_query,500), '')             AS waiting_query,
                 COALESCE(LEFT(bt.trx_query,500), '')             AS blocking_query,
                 COALESCE(rt.trx_state,'')                        AS waiting_state,
                 COALESCE(bt.trx_state,'')                        AS blocking_state,
                 CAST(COALESCE(TIMESTAMPDIFF(SECOND, rt.trx_wait_started, NOW()),0) AS CHAR) AS wait_secs,
                 '{host}'                                         AS server_address,
                 'mariadb_lock_waits'                             AS o2_recipe
          FROM information_schema.INNODB_LOCK_WAITS w
          LEFT JOIN information_schema.INNODB_TRX rt
                 ON rt.trx_id = w.requesting_trx_id
          LEFT JOIN information_schema.INNODB_TRX bt
                 ON bt.trx_id = w.blocking_trx_id
          LEFT JOIN information_schema.PROCESSLIST rp
                 ON rp.ID = rt.trx_mysql_thread_id
        logs:
          - body_column: waiting_query
            attribute_columns:
              [waiting_trx, blocking_trx, my_db, waiting_thread, blocking_thread,
               blocking_query, waiting_state, blocking_state, wait_secs, server_address, o2_recipe]
  filelog/mariadb_deadlocks:
    include: [{logpath}]
    start_at: end
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2} +\d{1,2}:\d{2}:\d{2} '
    operators:
      - type: regex_parser
        regex: '^(?P<ts>\d{4}-\d{2}-\d{2} +\d{1,2}:\d{2}:\d{2}) (?P<maria_thread>\d+) \[(?P<maria_severity>\w+)\] (?P<maria_message>(?s).*)$'
        on_error: send
        timestamp:
          parse_from: attributes.ts
          layout: "%Y-%m-%d %H:%M:%S"
      # Already the record timestamp; left in place it lands as a stray ts column.
      - type: remove
        if: 'attributes.ts != nil'
        field: attributes.ts
      - type: add
        field: attributes.o2_maria_event
        value: other
      # IDENTITY. Without this every host reporting into _o2_dbm_server looks like
      # the same server: the read-time deadlock stitch groups on
      # (engine, instance, database), so untagged sides from two different hosts
      # could fuse into one fabricated multi-participant deadlock.
      - type: add
        field: attributes.server_address
        value: "{host}"
      # MariaDB has no [MY-nnnnnn] error code to route on, so the deadlock text
      # IS the only signal. Anchored to InnoDB's own markers rather than a bare
      # "deadlock" match so ordinary notes mentioning the word do not qualify.
      #
      # THE "*** (N) TRANSACTION:" ROUTE IS THE LOAD-BEARING ONE. MariaDB writes
      # the per-side blocks under an entry whose own text is a bare "InnoDB:",
      # containing neither "Transactions deadlock detected" (the banner, a
      # separate entry) nor "WE ROLL BACK TRANSACTION" (the verdict, another).
      # Routing on only those two phrases captures the verdict and drops BOTH
      # sides -- deadlocks with no participants.
      - type: router
        routes:
          - expr: 'attributes.maria_message != nil and attributes.maria_message matches "\\*\\*\\* \\(\\d+\\) TRANSACTION:"'
            output: maria_dl
          - expr: 'attributes.maria_message != nil and attributes.maria_message matches "Transactions deadlock detected"'
            output: maria_dl
          - expr: 'attributes.maria_message != nil and attributes.maria_message matches "WE ROLL BACK TRANSACTION"'
            output: maria_dl
        default: maria_emit
      - type: add
        id: maria_dl
        field: attributes.o2_maria_event
        value: deadlock
      # ONE side per record — see the split-entry note above. Identical to the
      # MySQL pattern except the vendor literal "MariaDB thread id".
      - type: regex_parser
        parse_from: attributes.maria_message
        regex: '(?s)\*\*\* \((?P<maria_trx_side>\d+)\) TRANSACTION:\s*\nTRANSACTION (?P<maria_trx_id>\d+).*?MariaDB thread id (?P<maria_trx_thread>\d+),[^\n]*?query id \d+ (?P<maria_trx_host>\S+) (?P<maria_trx_user>\S+)[^\n]*\n(?P<maria_trx_query>[^\n]+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.maria_message
        # See the MySQL receiver above: the schema half of the qualified table
        # name is the database the deadlock occurred in. MariaDB tags its rows
        # maria_*, but the DATABASE alias stays my_db on purpose --
        # detect_database reads my_db and has no maria_db alias, and the engine
        # is already distinguished by o2_maria_event, so this cannot make a
        # MariaDB row look like MySQL.
        #
        # Side and transaction id are captured for the same reason as the MySQL
        # recipe above: InnoDB writes the RECORD LOCKS line as a SEPARATE entry
        # from the `*** (N) TRANSACTION:` block, so the lock detail has to be
        # joined back by side + trx id or it is thrown away.
        regex: '(?s)\*\*\* \((?P<maria_lock_side>\d+)\) (?:HOLDS THE LOCK|WAITING FOR THIS LOCK).*?RECORD LOCKS space id \d+ page no \d+ n bits \d+ index (?P<maria_lock_index>\S+) of table (?P<maria_lock_table>`?(?P<my_db>[^`. ]+)`?\.\S+) trx id (?P<maria_lock_trx_id>\d+) (?P<maria_lock_mode>lock_mode \S+)'
        on_error: send
      - type: regex_parser
        parse_from: attributes.maria_message
        regex: '\*\*\* WE ROLL BACK TRANSACTION \((?P<maria_victim_side>\d+)\)'
        on_error: send
        output: maria_emit
      - type: noop
        id: maria_emit
  sqlquery/mariadb_table_stats:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 60s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT t.TABLE_SCHEMA                                        AS schema_name,
                 t.TABLE_NAME                                          AS table_name,
                 CAST(COALESCE(t.DATA_LENGTH,0) + COALESCE(t.INDEX_LENGTH,0) AS CHAR) AS total_bytes,
                 CAST(COALESCE(t.DATA_LENGTH,0) AS CHAR)               AS heap_bytes,
                 CAST(COALESCE(s.n_rows, t.TABLE_ROWS, 0) AS CHAR)     AS n_live_tup,
                 COALESCE(CAST(s.last_update AS CHAR), '')             AS last_analyze,
                 '{host}'                                              AS server_address,
                 'mariadb_table_stats'                                 AS o2_recipe
          FROM information_schema.TABLES t
          LEFT JOIN mysql.innodb_table_stats s
                 ON s.database_name = t.TABLE_SCHEMA AND s.table_name = t.TABLE_NAME
          WHERE t.TABLE_TYPE = 'BASE TABLE'
            AND t.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
        logs:
          - body_column: table_name
            attribute_columns:
              [schema_name, total_bytes, heap_bytes, n_live_tup, last_analyze,
               server_address, o2_recipe]
  sqlquery/mariadb_index_stats:
    driver: mysql
    datasource: "${env:MYSQL_USER}:${env:MYSQL_PASSWORD}@tcp({host}:{port})/{database}"
    collection_interval: 60s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT st.TABLE_SCHEMA                                       AS schema_name,
                 st.TABLE_NAME                                         AS table_name,
                 st.INDEX_NAME                                         AS index_name,
                 CAST(COALESCE(sz.stat_value, 0) * @@innodb_page_size AS CHAR) AS index_bytes,
                 CASE WHEN MIN(st.NON_UNIQUE) = 0 THEN 'true' ELSE 'false' END AS is_unique,
                 CONCAT('INDEX ', st.INDEX_NAME, ' ON ', st.TABLE_SCHEMA, '.', st.TABLE_NAME,
                        ' (', GROUP_CONCAT(st.COLUMN_NAME ORDER BY st.SEQ_IN_INDEX SEPARATOR ', '), ')') AS index_def,
                 '{host}'                                              AS server_address,
                 'mariadb_index_stats'                                 AS o2_recipe
          FROM information_schema.STATISTICS st
          LEFT JOIN mysql.innodb_index_stats sz
                 ON sz.database_name = st.TABLE_SCHEMA AND sz.table_name = st.TABLE_NAME
                AND sz.index_name = st.INDEX_NAME AND sz.stat_name = 'size'
          WHERE st.TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
          GROUP BY st.TABLE_SCHEMA, st.TABLE_NAME, st.INDEX_NAME, sz.stat_value
        logs:
          - body_column: index_def
            attribute_columns:
              [schema_name, table_name, index_name, index_bytes,
               is_unique, server_address, o2_recipe]
  mysql/dbm_events:
    endpoint: "{host}:{port}"
    username: ${env:MYSQL_USER}
    password: ${env:MYSQL_PASSWORD}
    database: {database}
    collection_interval: 10s
    query_sample_collection:
      # mysqlreceiver's OWN default, matching the MySQL card.
      max_rows_per_query: 100
    top_query_collection:
      top_query_count: 200
      collection_interval: 15s
      lookback_time: 120
      query_plan_cache_size: 1000
    # ON. These two events fill the Activity tab and the server-side Top
    # queries. Upstream has shipped them default-OFF since v0.148.0, so without
    # this block the collector looks healthy and emits ZERO events. Set one to
    # false to trim cost, but the block itself must STAY -- and events: must
    # stay a TOP-LEVEL receiver key, never nested inside the blocks above.
    events:
      db.server.query_sample: { enabled: true }
      db.server.top_query: { enabled: true }

processors:
  # Keep ONLY the records the Database Monitoring pages read. Load-bearing, not
  # tidiness: the filelog receivers tail the WHOLE database log, so without
  # this every ordinary log line lands in _o2_dbm_server too and swamps the tagged
  # rows. A record is ours if a recipe tagged it -- sqlquery rows carry
  # o2_recipe, filelog rows carry o2_pg_event / o2_my_event / o2_maria_event.
  filter/dbm:
    error_mode: ignore
    logs:
      log_record:
        # Tests the VALUE, not just presence. Every filelog pipeline stamps its
        # o2_*_event = "other" on EVERY line before routing (so the router has a
        # default), which means a nil-check keeps the whole error log — the exact
        # noise this filter exists to drop. Only the classified events, and the
        # sqlquery recipes' o2_recipe rows, are ours.
        #
        # o2_maria_event MUST be listed here. It is a separate key from
        # o2_my_event by design (see MARIADB_DEADLOG_RECEIVER), so omitting it
        # would drop every MariaDB deadlock while the pipeline looked healthy.
        - 'attributes["o2_recipe"] == nil and (attributes["o2_pg_event"] == nil or attributes["o2_pg_event"] == "other") and (attributes["o2_my_event"] == nil or attributes["o2_my_event"] == "other") and (attributes["o2_maria_event"] == nil or attributes["o2_maria_event"] == "other")'
  # SELF-PROTECTION. This collector usually runs on the CUSTOMER'S DATABASE
  # HOST: the filelog receivers read the database log as fast as it grows, so
  # with nothing between them and a stalled exporter the heap absorbs the
  # difference until the OOM killer ends it -- and the stall is most likely
  # during exactly the incident that produced the volume.
  #
  # MUST BE FIRST in every pipeline's processors list: memory_limiter applies
  # back-pressure to whatever is UPSTREAM of it, so a processor listed before
  # it is outside the guard. When over the soft limit it refuses batches, which
  # propagates back into the receivers and makes the collector SHED rather than
  # grow.
  memory_limiter:
    check_interval: 1s
    limit_mib: 768
    spike_limit_mib: 192
  # The borrowed receiver stamps its OWN engine name; this server is not that
  # engine. Runs on the events pipeline only — the sqlquery recipes on the main
  # pipeline already carry this engine's own tags.
  transform/mariadb_engine:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - set(attributes["db.system.name"], "mariadb")
          - set(resource.attributes["db.system.name"], "mariadb")
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  otlphttp/openobserve_dbm:
    logs_endpoint: {url}/api/{org}/v1/logs
    headers:
      Authorization: Basic {token}
      stream-name: _o2_dbm_server
    # THE OTHER HALF OF THE OOM GUARD (see memory_limiter above). Left at its
    # defaults the sending queue is effectively an unbounded in-memory buffer,
    # and retry_on_failure with no deadline re-queues batches that will never
    # succeed. Beyond the queue the collector DROPS, which is correct here: a
    # gap in the Deadlocks timeline beats a dead collector on a database host.
    # The queue is IN MEMORY and deliberately not persistent -- persistence
    # needs a storage: extension and a writable state directory on the database
    # host.
    sending_queue:
      enabled: true
      queue_size: 500
    retry_on_failure:
      enabled: true
      max_elapsed_time: 300s

service:
  pipelines:
    logs:
      receivers: [sqlquery/mariadb_locks, filelog/mariadb_deadlocks, sqlquery/mariadb_table_stats, sqlquery/mariadb_index_stats]
      # memory_limiter FIRST — it back-pressures what is upstream of it, so
      # anything listed before it runs outside the guard.
      processors: [memory_limiter, filter/dbm, batch]
      exporters: [otlphttp/openobserve_dbm]
    logs/dbm_events:
      receivers: [mysql/dbm_events]
      processors: [memory_limiter, transform/mariadb_engine, batch]
      exporters: [otlphttp/openobserve_dbm]
__O2_TPL_EOF__
}

# Source: openobserve web/src/components/ingestion/setupCard/content/dbmShared.ts (MSSQL_DBM_CONFIG_YAML)
tpl_dbm_sqlserver() {
    cat << '__O2_TPL_EOF__'
receivers:
  sqlquery/mssql_blocking:
    driver: sqlserver
    # KEY-VALUE DSN, NEVER the sqlserver:// URL form, on all four mssql
    # receivers. A URL parses the password as part of the authority, so any
    # password containing '#' truncates at the fragment and every scrape fails
    # with: parse "sqlserver://sa:dbm_Passw0rd": invalid port ":dbm_Passw0rd"
    # after host -- once per collection_interval, while the collector's own
    # health stays green. '#' is common in generated SA passwords.
    datasource: "server={host};port={port};user id=${env:MSSQL_USER};password=${env:MSSQL_PASSWORD};database={database}"
    collection_interval: 10s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SELECT CAST(r.session_id AS VARCHAR(20))            AS blocked_pid,
                 -- PER-REQUEST database, from the request's own database_id
                 -- rather than the connection's: a blocking chain on SQL Server
                 -- can span databases, so DB_NAME(r.database_id) names where
                 -- the contention actually is. BRACKETED because database is a
                 -- RESERVED KEYWORD in T-SQL: written bare, the whole
                 -- collection fails with "Incorrect syntax near the keyword
                 -- 'database'" and the blocking receiver silently stops
                 -- producing rows while the collector still looks healthy. The
                 -- brackets are quoting only -- the emitted column name is
                 -- still database, which is what detect_database reads.
                 COALESCE(DB_NAME(r.database_id), '')         AS [database],
                 COALESCE(s.login_name, '')                   AS blocked_user,
                 COALESCE(s.program_name, '')                 AS blocked_app,
                 COALESCE(SUBSTRING(t.text, 1, 500), '')      AS blocked_query,
                 COALESCE(r.wait_type, '')                    AS wait_event_type,
                 COALESCE(r.wait_resource, '')                AS wait_event,
                 CAST(r.wait_time / 1000.0 AS VARCHAR(20))    AS blocked_wait_s,
                 CAST(r.blocking_session_id AS VARCHAR(20))   AS blocking_pid,
                 COALESCE(bs.status, '')                      AS blocking_state,
                 COALESCE(bs.program_name, '')                AS blocking_app,
                 COALESCE(SUBSTRING(bt.text, 1, 500), '')     AS blocking_query,
                 '{host}'                                     AS server_address,
                 'mssql_blocking_chain'                       AS o2_recipe
          FROM sys.dm_exec_requests r
          JOIN sys.dm_exec_sessions s  ON s.session_id  = r.session_id
          LEFT JOIN sys.dm_exec_sessions bs ON bs.session_id = r.blocking_session_id
          OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
          LEFT JOIN sys.dm_exec_connections bc ON bc.session_id = r.blocking_session_id
          OUTER APPLY sys.dm_exec_sql_text(bc.most_recent_sql_handle) bt
          WHERE r.blocking_session_id <> 0
        logs:
          - body_column: blocked_query
            attribute_columns:
              [blocked_pid, database, blocked_user, blocked_app, wait_event_type, wait_event,
               blocked_wait_s, blocking_pid, blocking_state, blocking_app,
               blocking_query, server_address, o2_recipe]
  sqlquery/mssql_deadlocks:
    driver: sqlserver
    datasource: "server={host};port={port};user id=${env:MSSQL_USER};password=${env:MSSQL_PASSWORD};database={database}"
    collection_interval: 30s
    # max_open_conn is SINGULAR; the plural is an unknown key that is
    # silently ignored, and unset means unlimited.
    max_open_conn: 2
    queries:
      - sql: |
          SET QUOTED_IDENTIFIER ON;
          SET NOCOUNT ON;
          WITH src AS (
            SELECT CAST(event_data AS XML) AS x
            FROM sys.fn_xe_file_target_read_file('system_health*.xel', NULL, NULL, NULL)
          ),
          dl AS (
            SELECT x.value('(event/@timestamp)[1]','datetime2') AS dl_ts,
                   x.query('(event/data/value/deadlock)[1]')    AS g
            FROM src
            WHERE x.value('(event/@name)[1]','varchar(50)') = 'xml_deadlock_report'
          ),
          v AS (
            SELECT dl_ts, g,
                   g.value('(deadlock/victim-list/victimProcess/@id)[1]','varchar(64)') AS victim_id
            FROM dl
            WHERE dl_ts > DATEADD(minute, -5, SYSUTCDATETIME())
          )
          SELECT CONVERT(VARCHAR(30), v.dl_ts, 126)                                      AS mssql_dl_ts,
                 CAST(p.value('@spid','int') AS VARCHAR(20))                             AS mssql_spid,
                 CAST(CASE WHEN p.value('@id','varchar(64)') = v.victim_id
                           THEN 1 ELSE 0 END AS VARCHAR(1))                              AS mssql_is_victim,
                 COALESCE(p.value('@lockMode','varchar(32)'),'')                         AS mssql_lock_mode,
                 COALESCE(p.value('@clientapp','varchar(128)'),'')                       AS mssql_app,
                 COALESCE(p.value('@loginname','varchar(128)'),'')                       AS mssql_user,
                 COALESCE(p.value('@currentdbname','varchar(128)'),'')                   AS mssql_db,
                 COALESCE(p.value('(../../resource-list/keylock/@objectname)[1]','varchar(256)'),'') AS mssql_lock_target,
                 LTRIM(RTRIM(REPLACE(REPLACE(COALESCE(p.value('(inputbuf/text())[1]','varchar(500)'),''), CHAR(13), ' '), CHAR(10), ' '))) AS mssql_query,
                 '{host}'                                                                AS server_address,
                 'mssql_deadlock'                                                        AS o2_recipe
          FROM v
          CROSS APPLY v.g.nodes('deadlock/process-list/process') AS t(p)
        logs:
          - body_column: mssql_query
            attribute_columns:
              [mssql_dl_ts, mssql_spid, mssql_is_victim, mssql_lock_mode, mssql_app,
               mssql_user, mssql_db, mssql_lock_target, server_address, o2_recipe]
  sqlquery/mssql_table_stats:
    driver: sqlserver
    datasource: "server={host};port={port};user id=${env:MSSQL_USER};password=${env:MSSQL_PASSWORD};database={database}"
    collection_interval: 60s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT SCHEMA_NAME(t.schema_id)                              AS schema_name,
                 t.name                                                AS table_name,
                 CAST(SUM(a.total_pages) * 8192 AS VARCHAR(32))        AS total_bytes,
                 -- index_id 0 = heap, 1 = clustered: the TABLE's own pages, so
                 -- this means what heap_bytes means on every other engine
                 -- rather than folding every index into the table figure.
                 CAST(SUM(CASE WHEN i.index_id IN (0,1) THEN a.data_pages ELSE 0 END) * 8192 AS VARCHAR(32)) AS heap_bytes,
                 -- MAX, not SUM: sys.partitions holds one row per index, so a
                 -- SUM counts the same rows once per index.
                 CAST(MAX(p.rows) AS VARCHAR(32))                      AS n_live_tup,
                 '{host}'                                              AS server_address,
                 'mssql_table_stats'                                   AS o2_recipe
          FROM sys.tables t
          JOIN sys.indexes i          ON i.object_id = t.object_id
          JOIN sys.partitions p       ON p.object_id = i.object_id AND p.index_id = i.index_id
          JOIN sys.allocation_units a ON a.container_id = p.partition_id
          GROUP BY SCHEMA_NAME(t.schema_id), t.name
        logs:
          - body_column: table_name
            attribute_columns:
              [schema_name, total_bytes, heap_bytes, n_live_tup, server_address, o2_recipe]
  sqlquery/mssql_index_stats:
    driver: sqlserver
    datasource: "server={host};port={port};user id=${env:MSSQL_USER};password=${env:MSSQL_PASSWORD};database={database}"
    collection_interval: 60s
    max_open_conn: 2
    queries:
      - sql: |
          SELECT SCHEMA_NAME(t.schema_id)                              AS schema_name,
                 t.name                                                AS table_name,
                 i.name                                                AS index_name,
                 -- Seeks + scans + lookups folded into one figure: all three
                 -- are the index being USED, and the unused-index rule asks
                 -- only whether anything touched it.
                 CAST(ISNULL(us.user_seeks,0) + ISNULL(us.user_scans,0) + ISNULL(us.user_lookups,0) AS VARCHAR(32)) AS idx_scan,
                 CAST(SUM(a.total_pages) * 8192 AS VARCHAR(32))        AS index_bytes,
                 CASE WHEN i.is_unique = 1 THEN 'true' ELSE 'false' END AS is_unique,
                 '{host}'                                              AS server_address,
                 'mssql_index_stats'                                   AS o2_recipe
          FROM sys.indexes i
          JOIN sys.tables t           ON t.object_id = i.object_id
          JOIN sys.partitions p       ON p.object_id = i.object_id AND p.index_id = i.index_id
          JOIN sys.allocation_units a ON a.container_id = p.partition_id
          -- LEFT JOIN, scoped to THIS database: the DMV holds no row for an
          -- index nothing has touched since the last restart, and that index is
          -- precisely the one the unused-index rule exists to surface. An inner
          -- join would hide it.
          LEFT JOIN sys.dm_db_index_usage_stats us
                 ON us.object_id = i.object_id AND us.index_id = i.index_id
                AND us.database_id = DB_ID()
          WHERE i.name IS NOT NULL
          GROUP BY SCHEMA_NAME(t.schema_id), t.name, i.name,
                   us.user_seeks, us.user_scans, us.user_lookups, i.is_unique
        logs:
          # index_name is BOTH the body and an attribute, and the duplication is
          # load-bearing. The canonicalizer reads index_name as a required
          # ATTRIBUTE and never from the body, so listing it only as body_column
          # drops every row: measured, 54 mssql_index_stats records arrived with
          # o2_dbm_kind null and SQL Server index health never reached the page.
          # Postgres hides this because it has an index_def to put in the body;
          # SQL Server has no equivalent, so the name serves as both.
          - body_column: index_name
            attribute_columns:
              [schema_name, table_name, index_name, idx_scan, index_bytes, is_unique,
               server_address, o2_recipe]
  sqlserver/dbm_events:
    server: "{host}"
    port: {port}
    username: ${env:MSSQL_USER}
    password: ${env:MSSQL_PASSWORD}
    collection_interval: 10s
    query_sample_collection:
      max_rows_per_query: 1000
    top_query_collection:
      top_query_count: 200
    # ON. These two events fill the Activity tab, the server-side Top queries,
    # and the EXECUTION PLANS on a query's detail page -- the plans ride on
    # db.server.top_query. Upstream has shipped both default-OFF since
    # v0.148.0, so without this block the collector looks healthy and emits
    # ZERO events. Set one to false to trim cost, but the block itself must
    # STAY -- and events: must stay a TOP-LEVEL receiver key, never nested
    # inside the blocks above.
    events:
      db.server.query_sample: { enabled: true }
      db.server.top_query: { enabled: true }

processors:
  # Keep ONLY the records the Database Monitoring pages read. Load-bearing, not
  # tidiness: the filelog receivers tail the WHOLE database log, so without
  # this every ordinary log line lands in _o2_dbm_server too and swamps the tagged
  # rows. A record is ours if a recipe tagged it -- sqlquery rows carry
  # o2_recipe, filelog rows carry o2_pg_event / o2_my_event / o2_maria_event.
  filter/dbm:
    error_mode: ignore
    logs:
      log_record:
        # Tests the VALUE, not just presence. Every filelog pipeline stamps its
        # o2_*_event = "other" on EVERY line before routing (so the router has a
        # default), which means a nil-check keeps the whole error log — the exact
        # noise this filter exists to drop. Only the classified events, and the
        # sqlquery recipes' o2_recipe rows, are ours.
        #
        # o2_maria_event MUST be listed here. It is a separate key from
        # o2_my_event by design (see MARIADB_DEADLOG_RECEIVER), so omitting it
        # would drop every MariaDB deadlock while the pipeline looked healthy.
        - 'attributes["o2_recipe"] == nil and (attributes["o2_pg_event"] == nil or attributes["o2_pg_event"] == "other") and (attributes["o2_my_event"] == nil or attributes["o2_my_event"] == "other") and (attributes["o2_maria_event"] == nil or attributes["o2_maria_event"] == "other")'
  # SELF-PROTECTION. This collector usually runs on the CUSTOMER'S DATABASE
  # HOST: the filelog receivers read the database log as fast as it grows, so
  # with nothing between them and a stalled exporter the heap absorbs the
  # difference until the OOM killer ends it -- and the stall is most likely
  # during exactly the incident that produced the volume.
  #
  # MUST BE FIRST in every pipeline's processors list: memory_limiter applies
  # back-pressure to whatever is UPSTREAM of it, so a processor listed before
  # it is outside the guard. When over the soft limit it refuses batches, which
  # propagates back into the receivers and makes the collector SHED rather than
  # grow.
  memory_limiter:
    check_interval: 1s
    limit_mib: 768
    spike_limit_mib: 192
  batch:
    timeout: 5s
    send_batch_size: 512

exporters:
  otlphttp/openobserve_dbm:
    logs_endpoint: {url}/api/{org}/v1/logs
    headers:
      Authorization: Basic {token}
      stream-name: _o2_dbm_server
    # THE OTHER HALF OF THE OOM GUARD (see memory_limiter above). Left at its
    # defaults the sending queue is effectively an unbounded in-memory buffer,
    # and retry_on_failure with no deadline re-queues batches that will never
    # succeed. Beyond the queue the collector DROPS, which is correct here: a
    # gap in the Deadlocks timeline beats a dead collector on a database host.
    # The queue is IN MEMORY and deliberately not persistent -- persistence
    # needs a storage: extension and a writable state directory on the database
    # host.
    sending_queue:
      enabled: true
      queue_size: 500
    retry_on_failure:
      enabled: true
      max_elapsed_time: 300s

service:
  pipelines:
    logs:
      receivers: [sqlquery/mssql_blocking, sqlquery/mssql_deadlocks, sqlquery/mssql_table_stats, sqlquery/mssql_index_stats]
      # memory_limiter FIRST — it back-pressures what is upstream of it, so
      # anything listed before it runs outside the guard.
      processors: [memory_limiter, filter/dbm, batch]
      exporters: [otlphttp/openobserve_dbm]
    logs/dbm_events:
      receivers: [sqlserver/dbm_events]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/openobserve_dbm]
__O2_TPL_EOF__
}

# ─── Config Rendering ─────────────────────────────────────────────────────────
# Replaces every occurrence of $2 with $3 in $1. Both are quoted so bash 5.2's
# patsub_replacement never treats '&' in a value as "the matched text".
replace_all() {
    local text="$1" from="$2" to="$3"
    printf '%s' "${text//"$from"/"$to"}"
}

# Replaces exactly one known line from a card template, failing loudly if the
# card text changed and the line is no longer there
replace_line() {
    local text="$1" from="$2" to="$3"
    if [[ "$text" != *"$from"* ]]; then
        print_error "Template drift: expected line not found: $from" >&2
        return 1
    fi
    replace_all "$text" "$from" "$to"
}

# Renders a template: card placeholders -> flag values, the access key ->
# an env reference (so config.yaml holds no secret), and the cards' literal
# demo usernames/passwords -> the --db-user value and env references.
render_config() {
    local text="$1"
    # The single quotes are intentional: these must reach the YAML literally
    # shellcheck disable=SC2016
    local token_ref='${env:O2_ACCESS_KEY}'

    text=$(replace_all "$text" "{url}" "$ENDPOINT")
    text=$(replace_all "$text" "{org}" "$ORG_ID")
    text=$(replace_all "$text" "{token}" "$token_ref")
    text=$(replace_all "$text" "{host}" "$DB_HOST")
    text=$(replace_all "$text" "{server}" "$DB_HOST")
    text=$(replace_all "$text" "{port}" "$DB_PORT")
    text=$(replace_all "$text" "{database}" "$DB_NAME")
    text=$(replace_all "$text" "{logpath}" "$LOG_PATH")
    printf '%s\n' "$text"
}

# Metrics config, with the card's hardcoded identities replaced
render_metrics_config() {
    local text
    text=$("tpl_metrics_$DB")
    # shellcheck disable=SC2016
    case "$DB" in
        postgres)
            text=$(replace_line "$text" "    username: myuser" "    username: $DB_USER")
            text=$(replace_line "$text" "      - postgres" "      - $DB_NAME")
            ;;
        mysql|mariadb)
            text=$(replace_line "$text" "    username: otel" "    username: $DB_USER")
            text=$(replace_line "$text" "    database: otel" "    database: $DB_NAME")
            ;;
        sqlserver)
            text=$(replace_line "$text" "    username: otel" "    username: $DB_USER")
            text=$(replace_line "$text" '    password: "YourStrong@Passw0rd"' '    password: ${env:MSSQL_PASSWORD}')
            ;;
        mongodb)
            text=$(replace_line "$text" "    username: otel" "    username: $DB_USER")
            text=$(replace_line "$text" "    password: password123" '    password: ${env:MONGODB_PASSWORD}')
            if [ "$MONGO_TLS" = true ]; then
                text=$(replace_line "$text" "      insecure: true" "      insecure: false")
                text=$(replace_line "$text" "      insecure_skip_verify: true" "      insecure_skip_verify: false")
            fi
            ;;
    esac
    render_config "$text"
}

render_dbm_config() {
    render_config "$("tpl_dbm_$DB")"
}

# Escapes a value for a double-quoted KEY="value" line. The escape set
# (\ " $ `) is the one both bash and systemd's EnvironmentFile parser honour,
# so the same file is read identically by systemd and by run.sh.
env_quote() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '"%s"' "$v"
}

# Writes the credentials env file: O2_ACCESS_KEY plus the variables the card's
# run step names for this engine
write_env_file() {
    local file="$1"
    {
        echo "# OpenObserve database collector credentials for $INSTANCE_NAME. Keep mode 600."
        echo "O2_ACCESS_KEY=$(env_quote "$ACCESS_KEY")"
        case "$DB" in
            postgres)
                # POSTGRESQL_PASSWORD feeds the metrics config; PGUSER/PGPASS the DBM one
                echo "POSTGRESQL_PASSWORD=$(env_quote "$DB_PASSWORD")"
                echo "PGUSER=$(env_quote "$DB_USER")"
                echo "PGPASS=$(env_quote "$DB_PASSWORD")"
                ;;
            mysql|mariadb)
                echo "MYSQL_USER=$(env_quote "$DB_USER")"
                echo "MYSQL_PASSWORD=$(env_quote "$DB_PASSWORD")"
                ;;
            sqlserver)
                echo "MSSQL_USER=$(env_quote "$DB_USER")"
                echo "MSSQL_PASSWORD=$(env_quote "$DB_PASSWORD")"
                ;;
            mongodb)
                echo "MONGODB_PASSWORD=$(env_quote "$DB_PASSWORD")"
                ;;
            redis)
                echo "REDIS_PASSWORD=$(env_quote "$DB_PASSWORD")"
                ;;
        esac
    } > "$file"
}

# Writes the wrapper launchd and --no-service use: load the env file, then exec
# the collector so it receives signals directly
write_run_script() {
    local file="$1"
    local dbm_arg=""
    if [ "$ENABLE_DBM" = true ]; then
        dbm_arg=" --config=file:$DBM_CONFIG_FILE"
    fi
    cat > "$file" << EOF
#!/bin/bash
# OpenObserve database collector for $INSTANCE_NAME ($DB). Generated by databases/install.sh.
set -e
set -a
. "$ENV_FILE"
set +a
exec "$BIN_PATH" --config=file:$CONFIG_FILE$dbm_arg
EOF
}

# ─── Staged Rendering ─────────────────────────────────────────────────────────
# Everything is rendered and validated in the work dir first, so a failed
# re-run never breaks an already-running collector
STAGE_DIR="$WORK_DIR/stage"
mkdir -p "$STAGE_DIR"
print_info "Rendering collector config for $DB..."
render_metrics_config > "$STAGE_DIR/config.yaml"
if [ "$ENABLE_DBM" = true ]; then
    render_dbm_config > "$STAGE_DIR/dbm-config.yaml"
fi
if [ "$DRY_RUN" = false ]; then
    (umask 077 && write_env_file "$STAGE_DIR/env")
fi
print_success "Config rendered"

# Runs `otelcol-contrib validate` on the staged configs with the staged env loaded
validate_configs() {
    local bin="$1"
    local args=(validate "--config=file:$STAGE_DIR/config.yaml")
    if [ "$ENABLE_DBM" = true ]; then
        args+=("--config=file:$STAGE_DIR/dbm-config.yaml")
    fi
    (
        if [ -f "$STAGE_DIR/env" ]; then
            set -a
            # shellcheck disable=SC1091
            . "$STAGE_DIR/env"
            set +a
        else
            # Dry run: no secrets on disk. Load placeholder values instead, since
            # some receivers (sqlserver, mongodb) reject an empty password.
            set -a
            # eval, not `. <(...)`: bash 3.2 (macOS) cannot source a pipe
            eval "$(ACCESS_KEY="dry-run" DB_PASSWORD="dry-run" write_env_file /dev/stdout)"
            set +a
        fi
        "$bin" "${args[@]}"
    )
}

# ─── Dry Run Mode ─────────────────────────────────────────────────────────────
# When --dry-run is set, validate the rendered config with an already-installed
# collector (if any), keep the rendered files for inspection, then exit
if [ "$DRY_RUN" = true ]; then
    DRY_RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/o2-db-dryrun.XXXXXX")
    cp "$STAGE_DIR"/*.yaml "$DRY_RUN_DIR/"
    STAGE_DIR="$DRY_RUN_DIR"
    existing_bin=""
    if [ -x "$BIN_PATH" ]; then
        existing_bin="$BIN_PATH"
    elif command -v otelcol-contrib &>/dev/null; then
        existing_bin=$(command -v otelcol-contrib)
    fi
    if [ -n "$existing_bin" ]; then
        print_info "Validating rendered config with $existing_bin..."
        if validate_configs "$existing_bin"; then
            print_success "otelcol-contrib validate passed"
        else
            print_error "otelcol-contrib validate failed for the rendered config"
            trap - ERR INT TERM
            exit 1
        fi
    else
        print_warning "otelcol-contrib is not installed; skipping 'otelcol-contrib validate'"
    fi
    print_success "Dry run mode: Configuration validated successfully"
    print_info "Rendered config (no secrets): $DRY_RUN_DIR"
    print_info "Would install:"
    print_info "  - otelcol-contrib $OTELCOL_VERSION ($OS/$ARCH) to $BIN_PATH"
    print_info "  - $CONFIG_FILE$([ "$ENABLE_DBM" = true ] && echo " and $DBM_CONFIG_FILE")"
    print_info "  - $ENV_FILE (mode 600)"
    case "$SERVICE_MANAGER" in
        systemd) print_info "  - systemd unit $SYSTEMD_UNIT" ;;
        launchd) print_info "  - launchd daemon $LAUNCHD_LABEL" ;;
        *) print_info "  - no service (foreground run command: sudo $RUN_SCRIPT)" ;;
    esac
    trap - ERR INT TERM
    exit 0
fi

# ─── Step 1: Install otelcol-contrib ──────────────────────────────────────────
# Download the pinned upstream release for this OS/arch, verify its sha256
# against the release's published checksum, then install it
echo ""
print_info "[Step 1/4] Installing otelcol-contrib $OTELCOL_VERSION..."

installed_version=""
if [ -x "$BIN_PATH" ]; then
    installed_version=$("$BIN_PATH" --version 2>/dev/null || true)
fi

if [[ "$installed_version" == *" $OTELCOL_VERSION"* ]]; then
    print_success "otelcol-contrib $OTELCOL_VERSION already installed at $BIN_PATH"
else
    if [ -n "$installed_version" ]; then
        print_info "Replacing existing collector ($installed_version)"
    fi
    asset="otelcol-contrib_${OTELCOL_VERSION}_${OS}_${ARCH}.tar.gz"
    asset_url="$OTELCOL_RELEASE_BASE/v$OTELCOL_VERSION/$asset"
    tarball="$WORK_DIR/$asset"

    print_info "Downloading $asset_url"
    retry_command curl -fsSL --connect-timeout 20 -o "$tarball" "$asset_url"

    # The release publishes one <asset>.sha256 per archive (the GitHub API that
    # would list assets is not needed)
    print_info "Verifying sha256 checksum..."
    expected_sha=""
    if checksum_body=$(retry_command curl -fsSL --connect-timeout 20 "$asset_url.sha256" 2>/dev/null); then
        expected_sha=$(printf '%s' "$checksum_body" | awk '{print $1; exit}')
    fi
    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        if [ "$SKIP_CHECKSUM" = true ]; then
            print_warning "Could not fetch the checksum for $asset; continuing because of --skip-checksum"
        else
            print_error "Could not fetch the published checksum $asset_url.sha256"
            print_info "Re-run with --skip-checksum to install without verification (not recommended)."
            exit 1
        fi
    else
        if [ -z "$SHA256_CMD" ]; then
            print_error "Neither sha256sum nor shasum is available to verify the download."
            exit 1
        fi
        actual_sha=$($SHA256_CMD "$tarball" | awk '{print $1}')
        if [ "$actual_sha" != "$expected_sha" ]; then
            print_error "Checksum mismatch for $asset"
            print_info "  expected: $expected_sha"
            print_info "  actual:   $actual_sha"
            exit 1
        fi
        print_success "Checksum verified ($expected_sha)"
    fi

    # Extract only the binary into its own directory
    mkdir -p "$WORK_DIR/extract"
    tar -xzf "$tarball" -C "$WORK_DIR/extract" otelcol-contrib
    mkdir -p "$(dirname "$BIN_PATH")"
    # Install via a temp name + mv so a running collector is never half-overwritten
    cp "$WORK_DIR/extract/otelcol-contrib" "$BIN_PATH.new"
    chmod 755 "$BIN_PATH.new"
    mv -f "$BIN_PATH.new" "$BIN_PATH"
    RESOURCES_CREATED+=("Binary: $BIN_PATH")
    print_success "Installed $("$BIN_PATH" --version)"
fi

# ─── Step 2: Validate and Install Config ──────────────────────────────────────
echo ""
print_info "[Step 2/4] Validating and installing config in $INSTANCE_DIR..."
if ! validate_output=$(validate_configs "$BIN_PATH" 2>&1); then
    print_error "otelcol-contrib validate rejected the rendered config:"
    printf '%s\n' "$validate_output" | tail -n 20 | sed 's/^/    /'
    exit 1
fi
print_success "otelcol-contrib validate passed"

# Directory 750, config 640 (no secrets in it), env 600 (credentials)
if [ ! -d "$INSTANCE_DIR" ]; then
    RESOURCES_CREATED+=("Config dir: $INSTANCE_DIR")
fi
mkdir -p "$INSTANCE_DIR"
chmod 755 "$CONFIG_ROOT"
chmod 750 "$INSTANCE_DIR"
install -m 640 "$STAGE_DIR/config.yaml" "$CONFIG_FILE"
if [ "$ENABLE_DBM" = true ]; then
    install -m 640 "$STAGE_DIR/dbm-config.yaml" "$DBM_CONFIG_FILE"
elif [ -f "$DBM_CONFIG_FILE" ]; then
    # Re-run without --dbm turns Database Monitoring back off
    rm -f "$DBM_CONFIG_FILE"
    print_info "Removed previous $DBM_CONFIG_FILE (re-run without --dbm)"
fi
install -m 600 "$STAGE_DIR/env" "$ENV_FILE"
write_run_script "$RUN_SCRIPT"
chmod 750 "$RUN_SCRIPT"
print_success "Wrote $CONFIG_FILE$([ "$ENABLE_DBM" = true ] && echo ", $DBM_CONFIG_FILE")"
print_success "Wrote credentials to $ENV_FILE (mode 600)"

CONFIG_ARGS="--config=file:$CONFIG_FILE"
if [ "$ENABLE_DBM" = true ]; then
    CONFIG_ARGS="$CONFIG_ARGS --config=file:$DBM_CONFIG_FILE"
fi

# ─── Step 3: Install Service ──────────────────────────────────────────────────
echo ""
print_info "[Step 3/4] Installing service..."

install_systemd_service() {
    local unit_path="$SYSTEMD_DIR/$SYSTEMD_UNIT"
    cat > "$unit_path" << EOF
# OpenObserve database collector for $INSTANCE_NAME ($DB). Generated by databases/install.sh.
[Unit]
Description=OpenObserve collector for $DB ($INSTANCE_NAME)
Documentation=https://github.com/openobserve/o2-datasource/tree/main/databases
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH $CONFIG_ARGS
Restart=on-failure
RestartSec=5
# Runs as root so --dbm can tail the database's server log; keep it contained
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit_path"
    RESOURCES_CREATED+=("systemd unit: $unit_path")
    systemctl daemon-reload
    systemctl enable "$SYSTEMD_UNIT" >/dev/null 2>&1
    # restart (not start) so a re-run picks up the new config
    systemctl restart "$SYSTEMD_UNIT"
    print_success "Started $SYSTEMD_UNIT"
}

install_launchd_service() {
    mkdir -p "$LAUNCHD_LOG_DIR"
    cat > "$LAUNCHD_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- OpenObserve database collector for $INSTANCE_NAME ($DB). Generated by databases/install.sh. -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCHD_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUN_SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LAUNCHD_LOG</string>
    <key>StandardErrorPath</key>
    <string>$LAUNCHD_LOG</string>
</dict>
</plist>
EOF
    chmod 644 "$LAUNCHD_PLIST"
    RESOURCES_CREATED+=("launchd daemon: $LAUNCHD_PLIST")
    # bootout first so a re-run reloads the plist and restarts the collector
    launchctl bootout "system/$LAUNCHD_LABEL" 2>/dev/null || true
    if ! launchctl bootstrap system "$LAUNCHD_PLIST" 2>/dev/null; then
        launchctl load -w "$LAUNCHD_PLIST"
    fi
    launchctl enable "system/$LAUNCHD_LABEL" 2>/dev/null || true
    launchctl kickstart -k "system/$LAUNCHD_LABEL" 2>/dev/null || true
    print_success "Started $LAUNCHD_LABEL"
}

case "$SERVICE_MANAGER" in
    systemd) install_systemd_service ;;
    launchd) install_launchd_service ;;
    *) print_info "Skipping service installation (--no-service)" ;;
esac

# ─── Step 4: Health Check ─────────────────────────────────────────────────────
# Healthy = still running after HEALTH_WINDOW seconds with no restarts. A bad
# credential does NOT fail this (the receivers retry and log the error), so the
# summary also points at the logs.
echo ""
if [ "$SERVICE_MANAGER" = "none" ]; then
    print_info "[Step 4/4] Skipping health check (no service)"
else
    print_info "[Step 4/4] Checking collector health (${HEALTH_WINDOW}s)..."
fi

systemd_restarts() {
    systemctl show -p NRestarts --value "$SYSTEMD_UNIT" 2>/dev/null || echo 0
}

launchd_runs() {
    local out
    out=$(launchctl print "system/$LAUNCHD_LABEL" 2>/dev/null || true)
    printf '%s\n' "$out" | awk -F'= ' '/^[[:space:]]*runs = /{print $2; exit}'
}

launchd_running() {
    local out
    out=$(launchctl print "system/$LAUNCHD_LABEL" 2>/dev/null || true)
    [[ "$out" == *"state = running"* ]]
}

healthy=true
case "$SERVICE_MANAGER" in
    systemd)
        sleep 2
        restarts_before=$(systemd_restarts)
        sleep "$HEALTH_WINDOW"
        restarts_after=$(systemd_restarts)
        if ! systemctl is-active --quiet "$SYSTEMD_UNIT" || [ "$restarts_after" != "$restarts_before" ]; then
            healthy=false
            print_error "$SYSTEMD_UNIT is not healthy (restarts: $restarts_before -> $restarts_after). Last logs:"
            journalctl -u "$SYSTEMD_UNIT" -n 40 --no-pager 2>/dev/null || true
        fi
        ;;
    launchd)
        sleep 2
        runs_before=$(launchd_runs)
        sleep "$HEALTH_WINDOW"
        runs_after=$(launchd_runs)
        if ! launchd_running || [ "$runs_after" != "$runs_before" ]; then
            healthy=false
            print_error "$LAUNCHD_LABEL is not healthy (runs: ${runs_before:-?} -> ${runs_after:-?}). Last logs:"
            tail -n 40 "$LAUNCHD_LOG" 2>/dev/null || true
        fi
        ;;
esac

if [ "$healthy" = true ] && [ "$SERVICE_MANAGER" != "none" ]; then
    print_success "Collector is running"
    # Surface receiver errors (bad password, missing grant) that do not crash it
    case "$SERVICE_MANAGER" in
        systemd) recent_logs=$(journalctl -u "$SYSTEMD_UNIT" --since "-$((HEALTH_WINDOW + 5))s" --no-pager 2>/dev/null || true) ;;
        launchd) recent_logs=$(tail -n 200 "$LAUNCHD_LOG" 2>/dev/null || true) ;;
    esac
    error_lines=$(printf '%s\n' "$recent_logs" | grep -E $'\terror\t|"level":"error"' | tail -n 5 || true)
    if [ -n "$error_lines" ]; then
        print_warning "The collector is up but logged errors (check credentials and grants):"
        printf '%s\n' "$error_lines" | sed 's/^/    /'
    fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
if [ "$healthy" = true ]; then
    print_success "Installation complete!"
else
    print_warning "Installation finished, but the collector is not healthy yet (see logs above)."
fi
echo ""
print_info "Instance:      $INSTANCE_NAME"
print_info "Config:        $CONFIG_FILE"
[ "$ENABLE_DBM" = true ] && print_info "DBM config:    $DBM_CONFIG_FILE"
print_info "Credentials:   $ENV_FILE (mode 600)"
case "$SERVICE_MANAGER" in
    systemd)
        print_info "Status:        sudo systemctl status $SYSTEMD_UNIT"
        print_info "Logs:          sudo journalctl -u $SYSTEMD_UNIT -f"
        print_info "Restart:       sudo systemctl restart $SYSTEMD_UNIT"
        ;;
    launchd)
        print_info "Status:        sudo launchctl print system/$LAUNCHD_LABEL"
        print_info "Logs:          tail -f $LAUNCHD_LOG"
        print_info "Restart:       sudo launchctl kickstart -k system/$LAUNCHD_LABEL"
        ;;
    *)
        print_info "Run it in the foreground (no service installed):"
        echo "    sudo $RUN_SCRIPT"
        ;;
esac
print_info "Uninstall:     curl -sSLo o2-db-uninstall.sh $UNINSTALL_URL && sudo bash o2-db-uninstall.sh --name=$INSTANCE_NAME"
echo ""
if [ "$ENABLE_DBM" = true ] && [ "$DB" = "postgres" ]; then
    print_info "Database Monitoring needs server-side settings (log_line_prefix, logging_collector,"
    print_info "pg_stat_statements) from databases/README.md; deadlock capture reads $LOG_PATH"
    print_info "and is not available on managed Postgres (RDS, Aurora, Cloud SQL)."
    echo ""
fi
print_success "Check your OpenObserve dashboard for incoming data: $ENDPOINT"

# Deregister the error trap now that the script completed successfully
trap - ERR INT TERM
