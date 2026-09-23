#!/bin/bash

# Azure Database for PostgreSQL Flexible Server logs
#   → Diagnostic Settings → Event Hubs → Azure Function → OpenObserve (_o2_dbm_server)
#
# Deploys the ARM template, uploads the forwarder code, configures Diagnostic
# Settings on each selected server, and (optionally) sets the Postgres server
# parameters that Database Monitoring needs.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_header()  { echo -e "\n${CYAN}══════════════════════════════════════════════${NC}\n  $1\n${CYAN}══════════════════════════════════════════════${NC}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="$SCRIPT_DIR/postgres-logs-to-openobserve.json"
FUNCTION_DIR="$SCRIPT_DIR/function"

# ============================================================
# Check prerequisites
# ============================================================
check_prerequisites() {
    if ! command -v az &>/dev/null; then
        print_error "Azure CLI (az) is not installed."
        print_info "Install it from: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! command -v zip &>/dev/null; then
        print_error "'zip' is not installed."
        exit 1
    fi

    if ! az account show &>/dev/null; then
        print_error "Not logged in to Azure. Run: az login"
        exit 1
    fi

    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "Template not found: $TEMPLATE_FILE"
        exit 1
    fi

    print_success "Prerequisites OK"
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    ACCOUNT_NAME=$(az account show --query name -o tsv)
    print_info "Subscription: $ACCOUNT_NAME ($SUBSCRIPTION_ID)"
}

# ============================================================
# Pick the PostgreSQL Flexible Servers to stream
# ============================================================
select_servers() {
    print_header "PostgreSQL Flexible Servers"

    print_info "Listing Flexible Servers in this subscription..."
    # A read loop rather than `mapfile`: macOS still ships bash 3.2, where
    # mapfile does not exist and the array would silently come back empty.
    SERVER_IDS=()
    while IFS= read -r line; do
        [ -n "$line" ] && SERVER_IDS+=("$line")
    done < <(az postgres flexible-server list --query "[].id" -o tsv 2>/dev/null || true)

    if [ ${#SERVER_IDS[@]} -eq 0 ]; then
        print_warning "No PostgreSQL Flexible Servers found in this subscription."
        print_info "You can still deploy the pipeline and attach servers later with"
        print_info "  ./configure-diagnostic-settings.sh"
        SELECTED_SERVERS=()
        return
    fi

    echo "Available servers:"
    local i=1
    for id in "${SERVER_IDS[@]}"; do
        echo "  $i) ${id##*/}   ($id)"
        i=$((i + 1))
    done
    echo ""
    print_info "Enter the numbers to stream, space-separated (or 'all', or empty to skip)."
    read -r -p "  Servers: " picks

    SELECTED_SERVERS=()
    if [ -z "$picks" ]; then
        print_warning "No servers selected — Diagnostic Settings will not be configured."
        return
    fi
    if [ "$picks" = "all" ]; then
        SELECTED_SERVERS=("${SERVER_IDS[@]}")
    else
        for n in $picks; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt ${#SERVER_IDS[@]} ]; then
                print_error "Invalid selection: $n"
                exit 1
            fi
            SELECTED_SERVERS+=("${SERVER_IDS[$((n - 1))]}")
        done
    fi

    print_info "Selected ${#SELECTED_SERVERS[@]} server(s)."
}

# ============================================================
# Collect configuration
# ============================================================
collect_config() {
    print_header "Configuration"

    # `az account list-locations` has no `isDefault` field — that belongs to
    # `az account list`. Querying it returns empty successfully, so a `||`
    # fallback never fires and the region silently ends up blank.
    DEFAULT_LOCATION=$(az config get defaults.location --query value -o tsv 2>/dev/null || true)
    DEFAULT_LOCATION="${DEFAULT_LOCATION:-eastus}"
    read -r -p "Azure region [$DEFAULT_LOCATION]: " input_loc
    LOCATION="${input_loc:-$DEFAULT_LOCATION}"

    DEFAULT_RG="rg-openobserve-postgres-logs"
    read -r -p "Resource group name [$DEFAULT_RG]: " input_rg
    RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"

    DEFAULT_DEPLOY="o2-pgflex-$(date +%Y%m%d%H%M)"
    read -r -p "ARM deployment name [$DEFAULT_DEPLOY]: " input_deploy
    DEPLOYMENT_NAME="${input_deploy:-$DEFAULT_DEPLOY}"

    DEFAULT_PREFIX="o2-pgflex"
    read -r -p "Resource name prefix (max 14 chars) [$DEFAULT_PREFIX]: " input_prefix
    NAME_PREFIX="${input_prefix:-$DEFAULT_PREFIX}"

    echo ""
    print_info "Enter your OpenObserve connection details:"
    read -r -p "  OpenObserve base URL (e.g. https://api.openobserve.ai): " OO_BASE_URL
    if [ -z "$OO_BASE_URL" ]; then
        print_error "OpenObserve base URL is required."
        exit 1
    fi
    OO_BASE_URL="${OO_BASE_URL%/}"

    read -r -p "  OpenObserve organization [default]: " input_org
    OO_ORG="${input_org:-default}"

    read -r -p "  OpenObserve username (email): " OO_USER
    if [ -z "$OO_USER" ]; then
        print_error "OpenObserve username is required."
        exit 1
    fi
    read -r -sp "  OpenObserve password: " OO_PASS
    echo ""
    if [ -z "$OO_PASS" ]; then
        print_error "OpenObserve password is required."
        exit 1
    fi

    # Not a prompt: `_o2_dbm_server` is the only stream the Database Monitoring
    # pages read, so it is fixed in the function.
    DBM_STREAM="_o2_dbm_server"

    echo ""
    print_info "Ordinary log lines (connections, checkpoints, autovacuum) are dropped by"
    print_info "default. Forwarding them to a separate stream is useful for troubleshooting"
    print_info "but multiplies ingest volume."
    read -r -p "  Also forward non-DBM log lines? (yes/no) [no]: " input_other
    if [ "${input_other:-no}" = "yes" ]; then
        FORWARD_OTHER="true"
        read -r -p "  Stream for those lines [azure_postgresql_logs]: " input_other_stream
        OTHER_STREAM="${input_other_stream:-azure_postgresql_logs}"
    else
        FORWARD_OTHER="false"
        OTHER_STREAM="azure_postgresql_logs"
    fi

    echo ""
    print_info "Select Function App hosting plan:"
    echo "  1) Y1  — Consumption / serverless (requires Dynamic VM quota in your subscription)"
    echo "  2) B1  — Basic (always-on, ~\$13/mo, no extra quota needed)"
    echo "  3) B2  — Basic larger"
    echo "  4) S1  — Standard (auto-scale capable)"
    read -r -p "  Option [1]: " plan_opt
    case "${plan_opt:-1}" in
        1) FUNCTION_PLAN_SKU="Y1" ;;
        2) FUNCTION_PLAN_SKU="B1" ;;
        3) FUNCTION_PLAN_SKU="B2" ;;
        4) FUNCTION_PLAN_SKU="S1" ;;
        *) print_error "Invalid option."; exit 1 ;;
    esac
    print_info "Function plan SKU: $FUNCTION_PLAN_SKU"

    DIAG_SETTINGS_NAME="${NAME_PREFIX}-pglogs-to-eventhub"
}

# ============================================================
# Create resource group
# ============================================================
create_resource_group() {
    print_header "Resource Group"

    if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        print_info "Resource group '$RESOURCE_GROUP' already exists."
    else
        print_info "Creating resource group '$RESOURCE_GROUP' in $LOCATION..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
        print_success "Resource group created."
    fi
}

# ============================================================
# Deploy ARM template
# ============================================================
deploy_arm_template() {
    print_header "Deploying ARM Template"
    print_info "Deploying Event Hubs + Azure Function + Storage..."
    echo ""

    # The template creates Diagnostic Settings itself when server IDs are passed,
    # which keeps them in the deployment's own lifecycle.
    local servers_json="[]"
    if [ ${#SELECTED_SERVERS[@]} -gt 0 ]; then
        servers_json=$(printf '%s\n' "${SELECTED_SERVERS[@]}" \
            | awk 'BEGIN{printf "["} {printf "%s\"%s\"", (NR>1 ? "," : ""), $0} END{printf "]"}')
    fi

    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$TEMPLATE_FILE" \
        --parameters \
            openObserveBaseUrl="$OO_BASE_URL" \
            openObserveOrganization="$OO_ORG" \
            openObserveUsername="$OO_USER" \
            openObservePassword="$OO_PASS" \
            forwardNonDbmLogs="$FORWARD_OTHER" \
            otherLogsStreamName="$OTHER_STREAM" \
            postgresServerResourceIds="$servers_json" \
            location="$LOCATION" \
            namePrefix="$NAME_PREFIX" \
            functionPlanSku="$FUNCTION_PLAN_SKU" \
        --output table

    print_success "ARM template deployed."

    # `|| true` is load-bearing: under `set -e` a failing az call aborts the
    # script at the assignment, so the "could not read outputs" check below
    # would never run and the user would get a bare non-zero exit.
    read_output() {
        az deployment group show \
            --resource-group "$RESOURCE_GROUP" \
            --name "$DEPLOYMENT_NAME" \
            --query "properties.outputs.$1.value" -o tsv 2>/dev/null || true
    }

    EVENT_HUB_NAME=$(read_output eventHubName)
    FUNCTION_APP_NAME=$(read_output functionAppName)
    SEND_RULE_ID=$(read_output sendAuthRuleId)
    CONSUMER_GROUP=$(read_output eventHubConsumerGroup)
    DBM_INGEST_URL=$(read_output dbmIngestUrl)

    if [ -z "$FUNCTION_APP_NAME" ]; then
        print_error "Could not read deployment outputs — cannot continue."
        exit 1
    fi

    print_info "Event Hub:      $EVENT_HUB_NAME (consumer group: $CONSUMER_GROUP)"
    print_info "Function App:   $FUNCTION_APP_NAME"
    print_info "Ingest URL:     $DBM_INGEST_URL"
}

# ============================================================
# Deploy function code via zip deploy
# ============================================================
deploy_function_code() {
    print_header "Deploying Function Code"

    if [ ! -f "$FUNCTION_DIR/PostgresLogForwarder/__init__.py" ]; then
        print_error "Function source not found under $FUNCTION_DIR"
        exit 1
    fi

    ZIP_DIR=$(mktemp -d)
    ZIP_FILE="$ZIP_DIR/function.zip"
    (cd "$FUNCTION_DIR" && zip -r "$ZIP_FILE" . -x "*.DS_Store" "*__pycache__*") > /dev/null
    print_info "Packaged $(du -h "$ZIP_FILE" | cut -f1) function bundle"

    print_info "Waiting for Function App runtime to be ready..."
    sleep 20

    print_info "Deploying function code to $FUNCTION_APP_NAME..."
    az functionapp deployment source config-zip \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP_NAME" \
        --src "$ZIP_FILE" \
        --output none

    rm -rf "$ZIP_DIR"
    print_success "Function code deployed."
}

# ============================================================
# Postgres server parameters
#
# Without these the pipeline runs and delivers nothing interesting: auto_explain
# is what produces executed plans, and it must log JSON for OpenObserve to read
# the plan document.
# ============================================================
configure_server_parameters() {
    if [ ${#SELECTED_SERVERS[@]} -eq 0 ]; then
        return
    fi

    print_header "PostgreSQL Server Parameters"

    cat <<'EOF'
  Database Monitoring needs these parameters on each server:

    shared_preload_libraries      += auto_explain   (REQUIRES A SERVER RESTART)
    log_line_prefix                = '%m [%p] %q[user=%u,db=%d,app=%a] '
    auto_explain.log_format        = json
    auto_explain.log_analyze       = on
    auto_explain.log_min_duration  = 1000           (ms; lower = more plans)
    auto_explain.log_timing        = off            (cheaper; keep off unless needed)
    log_min_duration_statement     = 1000           (ms; per-execution durations)
    log_lock_waits                 = on             (lock waits and deadlock detail)
    compute_query_id               = on             (stable cross-vantage join key)

  log_line_prefix is NOT optional. Azure's default is '%t-%c-', which carries no
  user, database or application name — and the Azure log envelope has no other
  source for them, so the Database Monitoring "database" filter would match
  nothing on every row while the pipeline looked perfectly healthy.

  The auto_explain.* parameters only exist once the library is preloaded AND the
  server has restarted. On a first-time setup this script sets what it can now,
  then tells you to restart and re-run.

  Statement logging has real overhead on a busy server. Start at 1000 ms and
  lower it once you have seen the ingest volume.
EOF
    echo ""
    read -r -p "Apply these to the selected server(s) now? (yes/no) [no]: " apply_params
    if [ "${apply_params:-no}" != "yes" ]; then
        print_warning "Skipped. Set them in the portal or with 'az postgres flexible-server parameter set'."
        return
    fi

    read -r -p "  auto_explain.log_min_duration in ms [1000]: " input_ae
    AE_MIN_DURATION="${input_ae:-1000}"
    read -r -p "  log_min_duration_statement in ms [1000]: " input_stmt
    STMT_MIN_DURATION="${input_stmt:-1000}"

    for server_id in "${SELECTED_SERVERS[@]}"; do
        local name rg
        name="${server_id##*/}"
        rg=$(echo "$server_id" | awk -F'/resourceGroups/' '{print $2}' | cut -d'/' -f1)
        print_info "Configuring $name (resource group $rg)..."

        # shared_preload_libraries is additive: read the current value so an
        # existing entry (pg_stat_statements, pg_cron, ...) is not dropped.
        local current preload_changed="no"
        current=$(az postgres flexible-server parameter show \
            --resource-group "$rg" --server-name "$name" \
            --name shared_preload_libraries --query value -o tsv 2>/dev/null || echo "")
        if [[ ",$current," != *",auto_explain,"* ]]; then
            preload_changed="yes"
            local updated
            if [ -z "$current" ]; then updated="auto_explain"; else updated="$current,auto_explain"; fi
            az postgres flexible-server parameter set \
                --resource-group "$rg" --server-name "$name" \
                --name shared_preload_libraries --value "$updated" --output none
            print_warning "  shared_preload_libraries -> $updated (restart required)"
            RESTART_NEEDED+=("$rg/$name")
        else
            print_info "  auto_explain already in shared_preload_libraries"
        fi

        local failed=0
        set_param() {
            if az postgres flexible-server parameter set \
                --resource-group "$rg" --server-name "$name" \
                --name "$1" --value "$2" --output none 2>/dev/null; then
                return 0
            fi
            print_warning "  could not set $1"
            failed=$((failed + 1))
        }

        # Always settable — these exist on a stock server.
        set_param log_line_prefix '%m [%p] %q[user=%u,db=%d,app=%a] '
        set_param log_min_duration_statement "$STMT_MIN_DURATION"
        set_param log_lock_waits on
        set_param compute_query_id on

        # Only exist once auto_explain is actually preloaded. Attempting them
        # before the restart is what made this step report success for
        # parameters it had not applied.
        if [ "$preload_changed" = "yes" ]; then
            print_warning "  auto_explain.* deferred until after the restart — re-run this script then"
        else
            set_param auto_explain.log_format json
            set_param auto_explain.log_analyze on
            set_param auto_explain.log_timing off
            set_param auto_explain.log_min_duration "$AE_MIN_DURATION"
        fi

        if [ "$failed" -eq 0 ]; then
            print_success "  parameters applied to $name"
        else
            print_warning "  $failed parameter(s) could NOT be applied on $name"
        fi
    done
}

# ============================================================
# Summary
# ============================================================
show_summary() {
    print_header "Deployment Complete"

    echo "  Resource Group:      $RESOURCE_GROUP"
    echo "  Event Hub:           $EVENT_HUB_NAME"
    echo "  Consumer Group:      $CONSUMER_GROUP"
    echo "  Function App:        $FUNCTION_APP_NAME"
    echo "  OpenObserve Stream:  $DBM_STREAM"
    echo "  Diagnostic Settings: $DIAG_SETTINGS_NAME"
    echo "  Servers streamed:    ${#SELECTED_SERVERS[@]}"
    echo ""

    if [ ${#RESTART_NEEDED[@]} -gt 0 ]; then
        print_warning "auto_explain was added to shared_preload_libraries on:"
        for s in "${RESTART_NEEDED[@]}"; do echo "    - $s"; done
        print_warning "These servers must be RESTARTED before any plan is captured:"
        for s in "${RESTART_NEEDED[@]}"; do
            echo "    az postgres flexible-server restart --resource-group ${s%%/*} --name ${s##*/}"
        done
        echo ""
    fi

    if [ ${#SELECTED_SERVERS[@]} -eq 0 ]; then
        print_warning "No Diagnostic Settings were created. Attach servers with:"
        echo "    ./configure-diagnostic-settings.sh \\"
        echo "      --resource-group $RESOURCE_GROUP \\"
        echo "      --deployment-name $DEPLOYMENT_NAME \\"
        echo "      --server-id <postgres-server-resource-id>"
        echo ""
    fi

    print_success "PostgreSQL Flexible Server logs are streaming to OpenObserve."
    print_info "Allow 5–15 minutes for the first records to appear."
    echo ""
    print_info "Watch the forwarder:"
    echo "  az webapp log tail --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
    echo ""
    print_info "Verify in OpenObserve — records should carry o2_dbm_kind:"
    echo "  SELECT o2_dbm_kind, count(*) FROM \"$DBM_STREAM\" GROUP BY o2_dbm_kind"
}

# ============================================================
# Main
# ============================================================
main() {
    RESTART_NEEDED=()

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Azure PostgreSQL Flexible Server → OpenObserve DBM  ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script deploys:"
    print_info "  • Event Hubs Namespace + Event Hub + consumer group"
    print_info "  • Azure Function App (normalizes Postgres log records)"
    print_info "  • Diagnostic Settings on each selected Flexible Server"
    print_info "  • (Optionally) the auto_explain server parameters DBM needs"
    echo ""

    check_prerequisites
    select_servers
    collect_config

    echo ""
    echo "══════════════════════════════════════════════"
    echo "  Deployment Summary"
    echo "══════════════════════════════════════════════"
    echo "  Location:          $LOCATION"
    echo "  Resource Group:    $RESOURCE_GROUP"
    echo "  Name Prefix:       $NAME_PREFIX"
    echo "  OpenObserve URL:   $OO_BASE_URL"
    echo "  Organization:      $OO_ORG"
    echo "  OpenObserve User:  $OO_USER"
    echo "  Function Plan SKU: $FUNCTION_PLAN_SKU"
    echo "  DBM Stream:        $DBM_STREAM"
    echo "  Forward other:     $FORWARD_OTHER"
    echo "  Servers:           ${#SELECTED_SERVERS[@]}"
    echo "══════════════════════════════════════════════"
    echo ""
    read -r -p "Proceed with deployment? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_warning "Deployment cancelled."
        exit 0
    fi

    create_resource_group
    deploy_arm_template
    deploy_function_code
    configure_server_parameters
    show_summary
}

main
