#!/bin/bash

# Azure SQL Managed Instance / Azure SQL Database diagnostics
#   → Diagnostic Settings → Event Hubs → Azure Function → OpenObserve (azure_sql_logs)
#
# Deploys the ARM template, uploads the forwarder code, and configures
# Diagnostic Settings on each selected instance and database.

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
TEMPLATE_FILE="$SCRIPT_DIR/sql-logs-to-openobserve.json"
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
# Discover Managed Instances, their databases, and Azure SQL databases
#
# Each line of CANDIDATES is "<kind>|<location>|<resource-id>", where kind is
# `instance` (instance-level categories) or `database` (query/error categories).
# ============================================================
discover_resources() {
    CANDIDATES=()

    local mi_id mi_name mi_rg mi_loc
    while IFS=$'\t' read -r mi_id mi_name mi_rg mi_loc; do
        [ -z "$mi_id" ] && continue
        CANDIDATES+=("instance|$mi_loc|$mi_id")
        local db_id
        while IFS= read -r db_id; do
            [ -n "$db_id" ] && CANDIDATES+=("database|$mi_loc|$db_id")
        done < <(az sql midb list --resource-group "$mi_rg" --managed-instance "$mi_name" \
            --query "[].id" -o tsv 2>/dev/null || true)
    done < <(az sql mi list --query "[].[id, name, resourceGroup, location]" -o tsv 2>/dev/null || true)

    local srv_name srv_rg srv_loc
    while IFS=$'\t' read -r srv_name srv_rg srv_loc; do
        [ -z "$srv_name" ] && continue
        local db_id
        # `master` takes no query/error categories (its diagnostic settings are
        # for auditing only), and DataWarehouse-edition databases are dedicated
        # SQL pools with a different category set -- either one in the selection
        # fails the whole deployment with "Category ... is not supported".
        while IFS= read -r db_id; do
            [ -n "$db_id" ] && CANDIDATES+=("database|$srv_loc|$db_id")
        done < <(az sql db list --resource-group "$srv_rg" --server "$srv_name" \
            --query "[?name!='master' && edition!='DataWarehouse'].id" -o tsv 2>/dev/null || true)
    done < <(az sql server list --query "[].[name, resourceGroup, location]" -o tsv 2>/dev/null || true)
}

# ============================================================
# Pick what to stream
# ============================================================
select_resources() {
    print_header "Azure SQL Instances and Databases"

    print_info "Listing Managed Instances and Azure SQL databases in this subscription..."
    discover_resources

    SELECTED_INSTANCES=()
    SELECTED_DATABASES=()
    SELECTED_LOCATION=""

    if [ ${#CANDIDATES[@]} -eq 0 ]; then
        print_warning "No SQL Managed Instances or Azure SQL databases found in this subscription."
        print_info "You can still deploy the pipeline and attach resources later with"
        print_info "  ./configure-diagnostic-settings.sh"
        return
    fi

    echo "Available resources:"
    local i=1 entry kind loc id
    for entry in "${CANDIDATES[@]}"; do
        kind="${entry%%|*}"
        loc="${entry#*|}"; loc="${loc%%|*}"
        id="${entry##*|}"
        if [ "$kind" = "instance" ]; then
            printf "  %2d) [instance] %s   (%s)\n" "$i" "${id##*/}" "$loc"
        else
            printf "  %2d) [database] %s   (%s)\n" "$i" "$(echo "$id" | awk -F/ '{print $(NF-2)"/"$NF}')" "$loc"
        fi
        i=$((i + 1))
    done
    echo ""
    print_info "Instances get ResourceUsageStats; databases get Query Store, SQLInsights and Errors."
    print_info "Enter the numbers to stream, space-separated (or 'all', or empty to skip)."
    read -r -p "  Resources: " picks

    if [ -z "$picks" ]; then
        print_warning "Nothing selected — Diagnostic Settings will not be configured."
        return
    fi

    local chosen=()
    if [ "$picks" = "all" ]; then
        chosen=("${CANDIDATES[@]}")
    else
        local n
        for n in $picks; do
            if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt ${#CANDIDATES[@]} ]; then
                print_error "Invalid selection: $n"
                exit 1
            fi
            # The same ID twice in the template's copy loop is a duplicate
            # resource, which fails the deployment.
            case " ${chosen[*]-} " in
                *" ${CANDIDATES[$((n - 1))]} "*) continue ;;
            esac
            chosen+=("${CANDIDATES[$((n - 1))]}")
        done
    fi

    for entry in "${chosen[@]}"; do
        kind="${entry%%|*}"
        loc="${entry#*|}"; loc="${loc%%|*}"
        id="${entry##*|}"
        if [ "$kind" = "instance" ]; then
            SELECTED_INSTANCES+=("$id")
        else
            SELECTED_DATABASES+=("$id")
        fi
        if [ -z "$SELECTED_LOCATION" ]; then
            SELECTED_LOCATION="$loc"
        elif [ "$SELECTED_LOCATION" != "$loc" ]; then
            # Azure Monitor only streams to an Event Hub in the resource's own
            # region, and one off-region resource fails the whole deployment.
            print_error "Selected resources span regions ($SELECTED_LOCATION, $loc)."
            print_info "Run this script once per region, selecting only that region's resources"
            print_info "and giving each run its own resource group (resource names derive from it)."
            exit 1
        fi
    done

    print_info "Selected ${#SELECTED_INSTANCES[@]} instance(s) and ${#SELECTED_DATABASES[@]} database(s)."
}

# ============================================================
# Collect configuration
# ============================================================
collect_config() {
    print_header "Configuration"

    # Default to the selected resources' region: the Event Hub must be there.
    DEFAULT_LOCATION="$SELECTED_LOCATION"
    if [ -z "$DEFAULT_LOCATION" ]; then
        DEFAULT_LOCATION=$(az config get defaults.location --query value -o tsv 2>/dev/null || true)
    fi
    DEFAULT_LOCATION="${DEFAULT_LOCATION:-eastus}"
    read -r -p "Azure region [$DEFAULT_LOCATION]: " input_loc
    LOCATION="${input_loc:-$DEFAULT_LOCATION}"
    if [ -n "$SELECTED_LOCATION" ] && [ "$LOCATION" != "$SELECTED_LOCATION" ]; then
        print_error "The selected resources are in $SELECTED_LOCATION; the Event Hub must be too."
        exit 1
    fi

    DEFAULT_RG="rg-openobserve-sql-logs"
    read -r -p "Resource group name [$DEFAULT_RG]: " input_rg
    RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"

    DEFAULT_DEPLOY="o2-azsql-$(date +%Y%m%d%H%M)"
    read -r -p "ARM deployment name [$DEFAULT_DEPLOY]: " input_deploy
    DEPLOYMENT_NAME="${input_deploy:-$DEFAULT_DEPLOY}"

    DEFAULT_PREFIX="o2-azsql"
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

    read -r -p "  OpenObserve stream [azure_sql_logs]: " input_stream
    STREAM_NAME="${input_stream:-azure_sql_logs}"

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

    DIAG_SETTINGS_NAME="${NAME_PREFIX}-sql-to-eventhub"
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

# Render bash array arguments as a JSON array of strings.
to_json_array() {
    if [ $# -eq 0 ]; then
        printf '[]'
        return
    fi
    printf '%s\n' "$@" \
        | awk 'BEGIN{printf "["} {printf "%s\"%s\"", (NR>1 ? "," : ""), $0} END{printf "]"}'
}

# ============================================================
# Deploy ARM template
# ============================================================
deploy_arm_template() {
    print_header "Deploying ARM Template"
    print_info "Deploying Event Hubs + Azure Function + Storage..."
    echo ""

    # The template creates Diagnostic Settings itself when resource IDs are
    # passed, which keeps them in the deployment's own lifecycle.
    local instances_json databases_json
    instances_json=$(to_json_array ${SELECTED_INSTANCES[@]+"${SELECTED_INSTANCES[@]}"})
    databases_json=$(to_json_array ${SELECTED_DATABASES[@]+"${SELECTED_DATABASES[@]}"})

    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$TEMPLATE_FILE" \
        --parameters \
            o2Endpoint="$OO_BASE_URL" \
            o2Organization="$OO_ORG" \
            o2Username="$OO_USER" \
            o2Password="$OO_PASS" \
            streamName="$STREAM_NAME" \
            instanceResourceIds="$instances_json" \
            databaseResourceIds="$databases_json" \
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
    CONSUMER_GROUP=$(read_output eventHubConsumerGroup)
    INGEST_URL=$(read_output ingestUrl)

    if [ -z "$FUNCTION_APP_NAME" ]; then
        print_error "Could not read deployment outputs — cannot continue."
        exit 1
    fi

    print_info "Event Hub:      $EVENT_HUB_NAME (consumer group: $CONSUMER_GROUP)"
    print_info "Function App:   $FUNCTION_APP_NAME"
    print_info "Ingest URL:     $INGEST_URL"
}

# ============================================================
# Deploy function code via zip deploy
# ============================================================
deploy_function_code() {
    print_header "Deploying Function Code"

    if [ ! -f "$FUNCTION_DIR/SqlLogForwarder/__init__.py" ]; then
        print_error "Function source not found under $FUNCTION_DIR"
        exit 1
    fi

    ZIP_DIR=$(mktemp -d)
    ZIP_FILE="$ZIP_DIR/function.zip"
    (cd "$FUNCTION_DIR" && zip -r "$ZIP_FILE" . -x "*.DS_Store" "*__pycache__*") > /dev/null
    print_info "Packaged $(du -h "$ZIP_FILE" | cut -f1) function bundle"

    print_info "Waiting for Function App runtime to be ready..."
    sleep 20

    # The template points WEBSITE_RUN_FROM_PACKAGE at the published S3 package.
    # On a dedicated (B/S) plan, zip deploy refuses to run while that setting
    # is a remote URL, so it is removed in favour of the local code.
    az functionapp config appsettings delete \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP_NAME" \
        --setting-names WEBSITE_RUN_FROM_PACKAGE \
        --output none

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
# Summary
# ============================================================
show_summary() {
    print_header "Deployment Complete"

    echo "  Resource Group:      $RESOURCE_GROUP"
    echo "  Event Hub:           $EVENT_HUB_NAME"
    echo "  Consumer Group:      $CONSUMER_GROUP"
    echo "  Function App:        $FUNCTION_APP_NAME"
    echo "  OpenObserve Stream:  $STREAM_NAME"
    echo "  Diagnostic Settings: $DIAG_SETTINGS_NAME"
    echo "  Instances streamed:  ${#SELECTED_INSTANCES[@]}"
    echo "  Databases streamed:  ${#SELECTED_DATABASES[@]}"
    echo ""

    if [ $((${#SELECTED_INSTANCES[@]} + ${#SELECTED_DATABASES[@]})) -eq 0 ]; then
        print_warning "No Diagnostic Settings were created. Attach resources with:"
        echo "    ./configure-diagnostic-settings.sh \\"
        echo "      --resource-group $RESOURCE_GROUP \\"
        echo "      --deployment-name $DEPLOYMENT_NAME \\"
        echo "      --resource-id <instance-or-database-resource-id>"
        echo ""
    fi

    print_success "Azure SQL diagnostics are streaming to OpenObserve."
    print_info "Allow 5–15 minutes for the first records to appear."
    echo ""
    print_info "Function logs need Application Insights, which this template does not create;"
    print_info "turn it on under Function App → Application Insights if you need them."
    echo ""
    print_info "Verify in OpenObserve:"
    echo "  SELECT az_category, count(*) FROM \"$STREAM_NAME\" GROUP BY az_category"
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Azure SQL (Managed Instance / Database) → OpenObserve ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script deploys:"
    print_info "  • Event Hubs Namespace + Event Hub + consumer group"
    print_info "  • Azure Function App (flattens Azure SQL diagnostic records)"
    print_info "  • Diagnostic Settings on each selected instance and database"
    echo ""

    check_prerequisites
    select_resources
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
    echo "  Stream:            $STREAM_NAME"
    echo "  Function Plan SKU: $FUNCTION_PLAN_SKU"
    echo "  Instances:         ${#SELECTED_INSTANCES[@]}"
    echo "  Databases:         ${#SELECTED_DATABASES[@]}"
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
    show_summary
}

main
