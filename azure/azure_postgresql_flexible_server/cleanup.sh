#!/bin/bash

# Azure PostgreSQL Flexible Server → OpenObserve Cleanup Script
# Removes the Diagnostic Settings from each streamed server, then the ARM
# deployment's resources.
#
# Server parameters (auto_explain, log_min_duration_statement, ...) are NOT
# reverted: they are the customer's own Postgres configuration, and silently
# changing a running database's logging behaviour is not this script's call.

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

    DEFAULT_RG="rg-openobserve-postgres-logs"
    read -r -p "Resource group to clean up [$DEFAULT_RG]: " input_rg
    RESOURCE_GROUP="${input_rg:-$DEFAULT_RG}"

    DEFAULT_PREFIX="o2-pgflex"
    read -r -p "Resource name prefix used during deploy [$DEFAULT_PREFIX]: " input_prefix
    NAME_PREFIX="${input_prefix:-$DEFAULT_PREFIX}"

    DIAG_SETTINGS_NAME="${NAME_PREFIX}-pglogs-to-eventhub"
}

# ============================================================
# Remove Diagnostic Settings from every PostgreSQL Flexible Server
#
# Done FIRST and independently of the resource group: deleting the Event Hub
# out from under a live Diagnostic Setting leaves the server writing into a
# destination that no longer exists.
# ============================================================
remove_diagnostic_settings() {
    print_header "Removing PostgreSQL Diagnostic Settings"

    print_info "Scanning Flexible Servers for setting '$DIAG_SETTINGS_NAME'..."
    # A read loop rather than `mapfile`: macOS still ships bash 3.2, where
    # mapfile does not exist and the array would silently come back empty.
    SERVER_IDS=()
    while IFS= read -r line; do
        [ -n "$line" ] && SERVER_IDS+=("$line")
    done < <(az postgres flexible-server list --query "[].id" -o tsv 2>/dev/null || true)

    if [ ${#SERVER_IDS[@]} -eq 0 ]; then
        print_info "No PostgreSQL Flexible Servers found in this subscription."
        return
    fi

    local found=0
    for server_id in "${SERVER_IDS[@]}"; do
        if az monitor diagnostic-settings show \
            --name "$DIAG_SETTINGS_NAME" --resource "$server_id" &>/dev/null; then
            found=$((found + 1))
            echo ""
            read -r -p "Delete '$DIAG_SETTINGS_NAME' from ${server_id##*/}? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                az monitor diagnostic-settings delete \
                    --name "$DIAG_SETTINGS_NAME" --resource "$server_id" --output none
                print_success "Removed from ${server_id##*/}."
            else
                print_warning "Left in place on ${server_id##*/}."
            fi
        fi
    done

    if [ "$found" -eq 0 ]; then
        print_info "No matching diagnostic settings found."
        print_info "Servers in other subscriptions must be cleaned up separately:"
        print_info "  az monitor diagnostic-settings delete --name $DIAG_SETTINGS_NAME --resource <server-id>"
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

    DEPLOYMENTS=()
    while IFS= read -r line; do
        [ -n "$line" ] && DEPLOYMENTS+=("$line")
    done < <(az deployment group list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?starts_with(name, '${NAME_PREFIX}')].name" \
        -o tsv 2>/dev/null || true)

    if [ ${#DEPLOYMENTS[@]} -eq 0 ]; then
        print_info "No matching ARM deployments found (prefix '$NAME_PREFIX')."
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
    read -r -p "Proceed with deletion? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        print_warning "Resource group deletion cancelled."
        return
    fi

    print_info "Deleting resource group '$RESOURCE_GROUP'..."
    az group delete --name "$RESOURCE_GROUP" --yes --no-wait

    print_info "Deletion initiated (running in background)."
    print_info "Monitor progress: az group show --name $RESOURCE_GROUP --query properties.provisioningState"

    read -r -p "Wait for deletion to complete? (yes/no) [no]: " wait_confirm
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
    print_success "PostgreSQL log pipeline removed."
    echo ""
    print_warning "Postgres server parameters were NOT reverted. If you want the"
    print_warning "logging overhead back off, reset them yourself, for example:"
    echo "  az postgres flexible-server parameter set -g <rg> -s <server> \\"
    echo "    --name auto_explain.log_min_duration --value -1"
    echo "  az postgres flexible-server parameter set -g <rg> -s <server> \\"
    echo "    --name log_min_duration_statement --value -1"
    echo ""
    print_info "To verify cleanup:"
    echo "  az group show --name $RESOURCE_GROUP"
}

# ============================================================
# Main
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Azure PostgreSQL Flexible Server → OpenObserve      ║${NC}"
    echo -e "${CYAN}║  Cleanup                                             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    print_info "This script removes:"
    print_info "  • Diagnostic Settings on each PostgreSQL Flexible Server"
    print_info "  • Event Hubs Namespace + Event Hub"
    print_info "  • Azure Function App + App Service Plan"
    print_info "  • Storage Account"
    print_info "  • (Optionally) the entire Resource Group"
    echo ""

    check_prerequisites
    collect_config
    remove_diagnostic_settings
    list_deployments
    delete_resource_group
    check_orphaned_resources
    show_summary
}

main
