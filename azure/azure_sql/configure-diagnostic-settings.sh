#!/bin/bash
# OpenObserve — attach an Azure SQL Managed Instance or database to the Event
# Hub created by sql-logs-to-openobserve.json.
#
# Use this when resources were not selected at deploy time, or when they live
# in a different subscription than the pipeline (the ARM template can only reach
# resources in its own subscription).
#
# Categories are picked per resource type (override each list with
# --instance-categories / --database-categories):
#   .../managedInstances/<mi>                 -> ResourceUsageStats
#   .../managedInstances/<mi>/databases/<db>  -> SQLInsights, QueryStoreRuntimeStatistics,
#   .../servers/<srv>/databases/<db>             QueryStoreWaitStatistics, Errors
#
# Usage:
#   ./configure-diagnostic-settings.sh \
#     --resource-group "rg-openobserve-sql-logs" \
#     --deployment-name "o2-azsql-202610061200" \
#     --resource-id "/subscriptions/.../managedInstances/mymi/databases/appdb" \
#     [--resource-id "..."] \
#     [--instance-categories "ResourceUsageStats"] \
#     [--database-categories "QueryStoreRuntimeStatistics,Errors"] \
#     [--setting-name "o2-azsql-sql-to-eventhub"]

set -e

# ── Defaults ────────────────────────────────────────────────────────────────
SETTING_NAME=""
INSTANCE_CATEGORIES="ResourceUsageStats"
DATABASE_CATEGORIES="SQLInsights,QueryStoreRuntimeStatistics,QueryStoreWaitStatistics,Errors"
RESOURCE_GROUP=""
DEPLOYMENT_NAME=""
RESOURCE_IDS=()

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
    --deployment-name)  DEPLOYMENT_NAME="$2";  shift 2 ;;
    --resource-id)      RESOURCE_IDS+=("$2");  shift 2 ;;
    --instance-categories) INSTANCE_CATEGORIES="$2"; shift 2 ;;
    --database-categories) DATABASE_CATEGORIES="$2"; shift 2 ;;
    --setting-name)     SETTING_NAME="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate required args ───────────────────────────────────────────────────
if [[ -z "$RESOURCE_GROUP" || -z "$DEPLOYMENT_NAME" || ${#RESOURCE_IDS[@]} -eq 0 ]]; then
  echo ""
  echo "Error: --resource-group, --deployment-name and at least one --resource-id are required."
  echo ""
  echo "Usage:"
  echo "  ./configure-diagnostic-settings.sh \\"
  echo "    --resource-group \"rg-openobserve-sql-logs\" \\"
  echo "    --deployment-name \"o2-azsql-202610061200\" \\"
  echo "    --resource-id \"/subscriptions/.../managedInstances/mymi/databases/appdb\""
  echo ""
  exit 1
fi

if ! command -v az &>/dev/null; then
  echo "Error: Azure CLI (az) is not installed."
  echo "Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

# ── Read the pipeline's Event Hub coordinates from the deployment ───────────
echo ""
echo "→ Reading deployment outputs..."

# `|| true` is load-bearing under `set -e`: without it a wrong deployment name
# aborts the script right here, and the friendly error below never prints.
read_output() {
  az deployment group show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$DEPLOYMENT_NAME" \
    --query "properties.outputs.$1.value" -o tsv 2>/dev/null || true
}

EVENT_HUB_NAME=$(read_output eventHubName)
SEND_RULE_ID=$(read_output sendAuthRuleId)
if [[ -z "$SETTING_NAME" ]]; then
  SETTING_NAME=$(read_output diagnosticSettingName)
fi

if [[ -z "$EVENT_HUB_NAME" || -z "$SEND_RULE_ID" || -z "$SETTING_NAME" ]]; then
  echo ""
  echo "Error: Could not read deployment outputs."
  echo "  Check the resource group and deployment name, and that the ARM"
  echo "  deployment completed successfully."
  exit 1
fi

echo "  Event Hub      : $EVENT_HUB_NAME"
echo "  Auth Rule ID   : $SEND_RULE_ID"
echo "  Setting name   : $SETTING_NAME"
echo ""

# ── Build the logs JSON from a comma-separated category list ────────────────
logs_json() {
  local out="[" first=true cat cats
  IFS=',' read -ra cats <<< "$1"
  for cat in "${cats[@]}"; do
    cat=$(echo "$cat" | tr -d '[:space:]')
    if [[ -n "$cat" ]]; then
      if [[ "$first" == true ]]; then first=false; else out+=","; fi
      out+="{\"category\":\"$cat\",\"enabled\":true}"
    fi
  done
  printf '%s]' "$out"
}

# ── Create one diagnostic setting per resource ──────────────────────────────
FAILED=()
for RESOURCE_ID in "${RESOURCE_IDS[@]}"; do
  RESOURCE_NAME="${RESOURCE_ID##*/}"
  lower=$(echo "$RESOURCE_ID" | tr '[:upper:]' '[:lower:]')

  if [[ "$lower" =~ /providers/microsoft\.sql/(servers|managedinstances)/[^/]+/databases/[^/]+$ ]]; then
    cats="$DATABASE_CATEGORIES"
  elif [[ "$lower" =~ /providers/microsoft\.sql/managedinstances/[^/]+$ ]]; then
    cats="$INSTANCE_CATEGORIES"
  else
    # An Azure SQL Database *server* has no query/error categories of its own;
    # they live on each database.
    echo "→ '$RESOURCE_NAME' is not a Managed Instance or a database — skipping."
    echo "  For Azure SQL Database, pass each database's resource ID."
    FAILED+=("$RESOURCE_NAME")
    echo ""
    continue
  fi

  echo "→ Configuring '$RESOURCE_NAME' ($cats)..."

  # `create` is a create-or-update (PUT): an existing setting of this name is
  # replaced in full, and if the call fails the old one is left intact.
  if az monitor diagnostic-settings create \
      --name "$SETTING_NAME" \
      --resource "$RESOURCE_ID" \
      --event-hub "$EVENT_HUB_NAME" \
      --event-hub-rule "$SEND_RULE_ID" \
      --logs "$(logs_json "$cats")" \
      --output none; then
    echo "  ✓ $RESOURCE_NAME connected"
  else
    echo "  ✗ $RESOURCE_NAME failed"
    FAILED+=("$RESOURCE_NAME")
  fi
  echo ""
done

# ── Report ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "  ✓ ${#RESOURCE_IDS[@]} resource(s) streaming Azure SQL diagnostics to"
  echo "    OpenObserve via Event Hub '$EVENT_HUB_NAME'."
else
  echo "  ${#FAILED[@]} of ${#RESOURCE_IDS[@]} resource(s) FAILED:"
  for f in "${FAILED[@]}"; do echo "    - $f"; done
  echo ""
  echo "  'Category ... is not supported' means the category does not exist on"
  echo "  that resource type — see README.md → 'Diagnostic categories'."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  exit 1
fi
