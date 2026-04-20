#!/bin/bash

# Azure Activity Logs → Event Hubs → Azure Function → OpenObserve
# Deploys the ARM template and configures Subscription Diagnostic Settings

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
TEMPLATE_FILE="$SCRIPT_DIR/activity-logs-to-openobserve.json"

# ============================================================
# Check prerequisites
# ============================================================
check_prerequisites() {
    if ! command -v az &>/dev/null; then
        print_error "Azure CLI (az) is not installed."
        print_info "Install it from: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi

    # Verify login
    if ! az account show &>/dev/null; then
        print_error "Not logged in to Azure. Run: az login"
        exit 1
    fi

    print_success "Prerequisites OK"
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)
    ACCOUNT_NAME=$(az account show --query name -o tsv)
    print_info "Subscription: $ACCOUNT_NAME ($SUBSCRIPTION_ID)"
}

# ============================================================
# Collect configuration
# ============================================================
collect_config() {
    print_header "Configuration"

    # Location
    DEFAULT_LOCATION=$(az account list-locations --query "[?isDefault].name" -o tsv 2>/dev/null || echo "eastus")
    read -p "Azure region [$DEFAULT_LOCATION]: " input_loc
    LOCATION="${input_loc:-$DEFAULT_LOCATION}"

    # Resource Group
    DEFAULT_RG="rg-openobserve-activity-logs"
    read -p "Resource group name [$DEFAULT_RG]: " input_rg
    RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"

    # Deployment name
    DEFAULT_DEPLOY="o2-activity-logs-$(date +%Y%m%d%H%M)"
    read -p "ARM deployment name [$DEFAULT_DEPLOY]: " input_deploy
    DEPLOYMENT_NAME="${input_deploy:-$DEFAULT_DEPLOY}"

    # Name prefix
    DEFAULT_PREFIX="o2-activity"
    read -p "Resource name prefix (max 14 chars) [$DEFAULT_PREFIX]: " input_prefix
    NAME_PREFIX="${input_prefix:-$DEFAULT_PREFIX}"

    echo ""
    # OpenObserve settings
    print_info "Enter your OpenObserve connection details:"
    read -p "  OpenObserve endpoint URL (e.g. https://api.openobserve.ai/api/org/stream/_json): " OO_ENDPOINT
    if [ -z "$OO_ENDPOINT" ]; then
        print_error "OpenObserve endpoint is required."
        exit 1
    fi

    # OpenObserve credentials
    echo ""
    read -p "  OpenObserve username (email): " OO_USER
    if [ -z "$OO_USER" ]; then
        print_error "OpenObserve username is required."
        exit 1
    fi
    read -sp "  OpenObserve password: " OO_PASS
    echo ""
    if [ -z "$OO_PASS" ]; then
        print_error "OpenObserve password is required."
        exit 1
    fi

    read -p "  OpenObserve stream name [azure-activity-logs]: " input_stream
    STREAM_NAME="${input_stream:-azure-activity-logs}"

    echo ""
    # Function App Plan SKU
    print_info "Select Function App hosting plan:"
    echo "  1) Y1  — Consumption / serverless (requires Dynamic VM quota in your subscription)"
    echo "  2) B1  — Basic (always-on, ~\$13/mo, no extra quota needed)"
    echo "  3) B2  — Basic larger"
    echo "  4) S1  — Standard (auto-scale capable)"
    read -p "  Option [1]: " plan_opt
    case "${plan_opt:-1}" in
        1) FUNCTION_PLAN_SKU="Y1" ;;
        2) FUNCTION_PLAN_SKU="B1" ;;
        3) FUNCTION_PLAN_SKU="B2" ;;
        4) FUNCTION_PLAN_SKU="S1" ;;
        *) print_error "Invalid option."; exit 1 ;;
    esac
    print_info "Function plan SKU: $FUNCTION_PLAN_SKU"

    echo ""
    # Diagnostic Settings
    print_info "Select which Activity Log categories to stream (space-separated)."
    print_info "Categories: Administrative Security ServiceHealth Alert Recommendation Policy Autoscale ResourceHealth"
    echo ""
    read -p "  Categories (leave empty for ALL): " input_cats
    if [ -z "$input_cats" ]; then
        LOG_CATEGORIES=("Administrative" "Security" "ServiceHealth" "Alert" "Recommendation" "Policy" "Autoscale" "ResourceHealth")
    else
        IFS=' ' read -r -a LOG_CATEGORIES <<< "$input_cats"
    fi

    DIAG_SETTINGS_NAME="${NAME_PREFIX}-activity-to-eventhub"
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

    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --template-file "$TEMPLATE_FILE" \
        --parameters \
            openObserveEndpoint="$OO_ENDPOINT" \
            openObserveUsername="$OO_USER" \
            openObservePassword="$OO_PASS" \
            streamName="$STREAM_NAME" \
            location="$LOCATION" \
            namePrefix="$NAME_PREFIX" \
            functionPlanSku="$FUNCTION_PLAN_SKU" \
        --output table

    print_success "ARM template deployed."

    # Capture outputs
    SEND_RULE_ID=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --query "properties.outputs.sendAuthRuleId.value" -o tsv)

    EVENT_HUB_NAME=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --query "properties.outputs.eventHubName.value" -o tsv)

    FUNCTION_APP_NAME=$(az deployment group show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DEPLOYMENT_NAME" \
        --query "properties.outputs.functionAppName.value" -o tsv)

    print_info "Event Hub: $EVENT_HUB_NAME"
    print_info "Function App: $FUNCTION_APP_NAME"
}

# ============================================================
# Deploy function code via zip deploy
# ============================================================
deploy_function_code() {
    print_header "Deploying Function Code"

    TMP_DIR=$(mktemp -d)
    FUNC_DIR="$TMP_DIR/ActivityLogForwarder"
    mkdir -p "$FUNC_DIR"

    # Write function.json (binding config)
    cat > "$FUNC_DIR/function.json" <<'EOF'
{
  "scriptFile": "__init__.py",
  "bindings": [
    {
      "type": "eventHubTrigger",
      "name": "events",
      "direction": "in",
      "eventHubName": "%EVENT_HUB_NAME%",
      "connection": "EventHubConnection",
      "cardinality": "many",
      "consumerGroup": "$Default"
    }
  ]
}
EOF

    # Write __init__.py (forwarding logic)
    cat > "$FUNC_DIR/__init__.py" <<'EOF'
import logging
import json
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone


def main(events) -> None:
    endpoint = os.environ.get('OPENOBSERVE_ENDPOINT', '')
    access_key = os.environ.get('OPENOBSERVE_ACCESS_KEY', '')
    stream_name = os.environ.get('STREAM_NAME', 'azure-activity-logs')

    if not endpoint or not access_key:
        logging.error('Missing OPENOBSERVE_ENDPOINT or OPENOBSERVE_ACCESS_KEY env vars')
        return

    all_records = []
    event_list = events if isinstance(events, list) else [events]

    for event in event_list:
        try:
            if isinstance(event, (bytes, bytearray)):
                body = event.decode('utf-8')
            elif isinstance(event, str):
                body = event
            else:
                body = str(event)

            data = json.loads(body)

            if isinstance(data, dict) and 'records' in data:
                for record in data['records']:
                    record['_timestamp'] = (
                        record.get('time') or
                        record.get('eventTimestamp') or
                        datetime.now(timezone.utc).isoformat()
                    )
                    record['_source'] = 'azure-activity-log'
                    record['_stream'] = stream_name
                    all_records.append(record)
            elif isinstance(data, list):
                for item in data:
                    item['_timestamp'] = (
                        item.get('time') or
                        item.get('eventTimestamp') or
                        datetime.now(timezone.utc).isoformat()
                    )
                    item['_source'] = 'azure-activity-log'
                    item['_stream'] = stream_name
                    all_records.append(item)
            else:
                data['_timestamp'] = (
                    data.get('time') or
                    data.get('eventTimestamp') or
                    datetime.now(timezone.utc).isoformat()
                )
                data['_source'] = 'azure-activity-log'
                data['_stream'] = stream_name
                all_records.append(data)

        except Exception as exc:
            logging.error('Error parsing Event Hub message: %s', exc)

    if not all_records:
        logging.info('No records to forward')
        return

    payload = json.dumps(all_records).encode('utf-8')
    logging.info('Forwarding %d Activity Log records to OpenObserve', len(all_records))

    req = urllib.request.Request(
        endpoint,
        data=payload,
        method='POST',
        headers={
            'Content-Type': 'application/json',
            'Authorization': 'Basic ' + access_key,
        }
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            logging.info('Successfully sent %d records to OpenObserve. HTTP %s',
                         len(all_records), resp.status)
    except urllib.error.HTTPError as exc:
        logging.error('OpenObserve HTTP error %s: %s', exc.code, exc.reason)
        raise
    except Exception as exc:
        logging.error('Failed to send to OpenObserve: %s', exc)
        raise
EOF

    # Write host.json at root
    cat > "$TMP_DIR/host.json" <<'EOF'
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true
      }
    }
  }
}
EOF

    # Write requirements.txt at root
    echo "# stdlib only — no extra packages needed" > "$TMP_DIR/requirements.txt"

    # Zip everything
    ZIP_FILE=$(mktemp /tmp/function-XXXXXX.zip)
    (cd "$TMP_DIR" && zip -r "$ZIP_FILE" . -x "*.DS_Store") > /dev/null

    print_info "Waiting for Function App runtime to be ready..."
    sleep 20

    print_info "Deploying function code to $FUNCTION_APP_NAME..."
    az functionapp deployment source config-zip \
        --resource-group "$RESOURCE_GROUP" \
        --name "$FUNCTION_APP_NAME" \
        --src "$ZIP_FILE" \
        --output none

    rm -rf "$TMP_DIR" "$ZIP_FILE"
    print_success "Function code deployed."
}

# ============================================================
# Configure Subscription Diagnostic Settings
# ============================================================
configure_diagnostic_settings() {
    print_header "Configuring Subscription Diagnostic Settings"
    print_info "Connecting Azure Activity Logs → Event Hub..."

    # Build the --logs JSON array
    LOGS_JSON="["
    FIRST=true
    for cat in "${LOG_CATEGORIES[@]}"; do
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            LOGS_JSON+=","
        fi
        LOGS_JSON+="{\"category\": \"$cat\", \"enabled\": true}"
    done
    LOGS_JSON+="]"

    # Remove existing diagnostic settings with the same name (if any)
    if az monitor diagnostic-settings subscription show \
        --name "$DIAG_SETTINGS_NAME" &>/dev/null 2>&1; then
        print_warning "Diagnostic settings '$DIAG_SETTINGS_NAME' already exist — updating..."
        az monitor diagnostic-settings subscription delete \
            --name "$DIAG_SETTINGS_NAME" \
            --yes \
            --output none
    fi

    az monitor diagnostic-settings subscription create \
        --name "$DIAG_SETTINGS_NAME" \
        --location "$LOCATION" \
        --event-hub "$EVENT_HUB_NAME" \
        --event-hub-auth-rule "$SEND_RULE_ID" \
        --logs "$LOGS_JSON" \
        --output none

    print_success "Diagnostic settings '$DIAG_SETTINGS_NAME' configured."
    print_info "Categories enabled: ${LOG_CATEGORIES[*]}"
}

# ============================================================
# Summary
# ============================================================
show_summary() {
    print_header "Deployment Complete"

    echo "  Resource Group:      $RESOURCE_GROUP"
    echo "  Event Hub:           $EVENT_HUB_NAME"
    echo "  Function App:        $FUNCTION_APP_NAME"
    echo "  OpenObserve Stream:  $STREAM_NAME"
    echo "  Diagnostic Settings: $DIAG_SETTINGS_NAME"
    echo ""
    print_success "Azure Activity Logs are now streaming to OpenObserve!"
    print_info "It may take 5–15 minutes for the first events to appear."
    echo ""
    print_info "Monitor the Function App logs:"
    echo "  az webapp log tail --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"
    echo ""
    print_info "View events in OpenObserve stream: $STREAM_NAME"
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Azure Activity Logs → Event Hubs → OpenObserve     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script deploys:"
    print_info "  • Event Hubs Namespace + Event Hub (streaming layer)"
    print_info "  • Azure Function App (processes + forwards logs)"
    print_info "  • Subscription Diagnostic Settings (connects Activity Logs → Event Hub)"
    echo ""

    check_prerequisites
    collect_config

    echo ""
    echo "══════════════════════════════════════════════"
    echo "  Deployment Summary"
    echo "══════════════════════════════════════════════"
    echo "  Location:          $LOCATION"
    echo "  Resource Group:    $RESOURCE_GROUP"
    echo "  Name Prefix:       $NAME_PREFIX"
    echo "  OpenObserve URL:   $OO_ENDPOINT"
    echo "  OpenObserve User:  $OO_USER"
    echo "  Function Plan SKU: $FUNCTION_PLAN_SKU"
    echo "  Stream Name:       $STREAM_NAME"
    echo "  Log Categories:    ${LOG_CATEGORIES[*]}"
    echo "══════════════════════════════════════════════"
    echo ""
    read -p "Proceed with deployment? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        print_warning "Deployment cancelled."
        exit 0
    fi

    create_resource_group
    deploy_arm_template
    deploy_function_code
    configure_diagnostic_settings
    show_summary
}

main
