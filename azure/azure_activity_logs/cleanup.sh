#!/bin/bash

# Azure Activity Logs → Event Hubs → OpenObserve Cleanup Script
# Removes the ARM deployment, associated resources, and Subscription Diagnostic Settings

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

# ============================================================
# Check prerequisites
# ============================================================
check_prerequisites() {
    if ! command -v az &>/dev/null; then
        print_error "Azure CLI (az) is not installed."
        print_info "Install it from: https://docs.microsoft.com/cli/azure/install-azure-cli"
        exit 1
    fi

    if ! az account show &>/dev/null; then
        print_error "Not logged in to Azure. Run: az login"
        exit 1
    fi

    print_success "Prerequisites OK"
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    ACCOUNT_NAME=$(az account show --query name -o tsv)
    print_info "Subscription: $ACCOUNT_NAME ($SUBSCRIPTION_ID)"
}

# ============================================================
# Collect target resource group
# ============================================================
collect_config() {
    print_header "Configuration"

    DEFAULT_RG="rg-openobserve-activity-logs"
    read -p "Resource group to clean up [$DEFAULT_RG]: " input_rg
    RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"

    DEFAULT_PREFIX="o2-activity"
    read -p "Resource name prefix used during deploy [$DEFAULT_PREFIX]: " input_prefix
    NAME_PREFIX="${input_prefix:-$DEFAULT_PREFIX}"

    DIAG_SETTINGS_NAME="${NAME_PREFIX}-activity-to-eventhub"
}

# ============================================================
# Remove Subscription Diagnostic Settings
# ============================================================
remove_diagnostic_settings() {
    print_header "Removing Subscription Diagnostic Settings"

    print_info "Looking for diagnostic settings: $DIAG_SETTINGS_NAME"

    if az monitor diagnostic-settings subscription show \
        --name "$DIAG_SETTINGS_NAME" &>/dev/null 2>&1; then

        read -p "Delete diagnostic settings '$DIAG_SETTINGS_NAME'? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            az monitor diagnostic-settings subscription delete \
                --name "$DIAG_SETTINGS_NAME" \
                --yes \
                --output none
            print_success "Diagnostic settings '$DIAG_SETTINGS_NAME' deleted."
        else
            print_warning "Skipping diagnostic settings deletion."
        fi
    else
        print_info "Diagnostic settings '$DIAG_SETTINGS_NAME' not found (already deleted or different name)."
    fi
}

# ============================================================
# List ARM deployments in the resource group
# ============================================================
list_deployments() {
    print_header "ARM Deployments in '$RESOURCE_GROUP'"

    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        print_warning "Resource group '$RESOURCE_GROUP' does not exist."
        DEPLOYMENTS=()
        return
    fi

    mapfile -t DEPLOYMENTS < <(az deployment group list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?starts_with(name, 'o2-activity')].name" \
        -o tsv 2>/dev/null || true)

    if [ ${#DEPLOYMENTS[@]} -eq 0 ]; then
        print_info "No matching ARM deployments found (prefix 'o2-activity')."
    else
        echo "Found deployments:"
        for d in "${DEPLOYMENTS[@]}"; do
            echo "  - $d"
        done
    fi
    echo ""
}

# ============================================================
# Delete the resource group (all resources)
# ============================================================
delete_resource_group() {
    print_header "Deleting Resource Group"

    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        print_info "Resource group '$RESOURCE_GROUP' does not exist. Nothing to delete."
        return
    fi

    echo "  The following resources will be deleted:"
    az resource list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[].{Type:type, Name:name}" \
        -o table 2>/dev/null || true
    echo ""

    print_warning "This will permanently delete ALL resources in '$RESOURCE_GROUP'."
    read -p "Proceed with deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        print_warning "Resource group deletion cancelled."
        return
    fi

    print_info "Deleting resource group '$RESOURCE_GROUP'..."
    az group delete \
        --name "$RESOURCE_GROUP" \
        --yes \
        --no-wait

    print_info "Deletion initiated (running in background)."
    print_info "Monitor progress: az group show --name $RESOURCE_GROUP --query properties.provisioningState"

    # Optionally wait
    read -p "Wait for deletion to complete? (yes/no) [no]: " wait_confirm
    if [ "${wait_confirm:-no}" = "yes" ]; then
        print_info "Waiting for resource group deletion..."
        az group wait --name "$RESOURCE_GROUP" --deleted 2>/dev/null && \
            print_success "Resource group '$RESOURCE_GROUP' deleted." || \
            print_warning "Resource group deletion may still be in progress."
    fi
}

# ============================================================
# Check for orphaned resources across the subscription
# ============================================================
check_orphaned_resources() {
    print_header "Checking for Orphaned Resources"

    print_info "Scanning for Event Hubs namespaces with prefix '$NAME_PREFIX'..."
    orphaned=$(az eventhubs namespace list \
        --query "[?starts_with(name, '${NAME_PREFIX}')].{Name:name, RG:resourceGroup, Location:location}" \
        -o table 2>/dev/null || true)

    if [ -n "$orphaned" ]; then
        echo ""
        echo "Found Event Hubs namespaces:"
        echo "$orphaned"
        echo ""
        print_info "These may be orphaned if the resource group was partially deleted."
        print_info "Delete them with: az eventhubs namespace delete --name <name> --resource-group <rg>"
    else
        print_info "No orphaned Event Hubs namespaces found."
    fi
}

# ============================================================
# Summary
# ============================================================
show_summary() {
    print_header "Cleanup Complete"
    echo "  Resource Group:      $RESOURCE_GROUP"
    echo "  Diagnostic Settings: $DIAG_SETTINGS_NAME"
    echo ""
    print_success "Azure Activity Logs pipeline removed."
    print_info "Activity Logs will no longer stream to OpenObserve."
    echo ""
    print_info "To verify cleanup:"
    echo "  az group show --name $RESOURCE_GROUP"
    echo "  az monitor diagnostic-settings subscription list"
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Azure Activity Logs → OpenObserve  Cleanup         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script removes:"
    print_info "  • Subscription Diagnostic Settings (stops log streaming)"
    print_info "  • Event Hubs Namespace + Event Hub"
    print_info "  • Azure Function App + App Service Plan"
    print_info "  • Storage Account"
    print_info "  • (Optionally) the entire Resource Group"
    echo ""

    check_prerequisites
    collect_config
    list_deployments
    remove_diagnostic_settings
    delete_resource_group
    check_orphaned_resources
    show_summary
}

main
