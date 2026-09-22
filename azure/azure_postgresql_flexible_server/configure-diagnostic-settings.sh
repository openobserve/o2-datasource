#!/bin/bash
# OpenObserve — attach an Azure Database for PostgreSQL Flexible Server to the
# Event Hub created by postgres-logs-to-openobserve.json.
#
# Use this when the servers were not selected at deploy time, or when they live
# in a different subscription than the pipeline (the ARM template can only reach
# servers in its own subscription).
#
# Usage:
#   ./configure-diagnostic-settings.sh \
#     --resource-group "rg-openobserve-postgres-logs" \
#     --deployment-name "o2-pgflex-202609221200" \
#     --server-id "/subscriptions/.../flexibleServers/mypgsrv" \
#     [--server-id "..."] \
#     [--categories "PostgreSQLLogs"] \
#     [--setting-name "o2-pgflex-pglogs-to-eventhub"]

set -e

# ── Defaults ────────────────────────────────────────────────────────────────
SETTING_NAME=""
CATEGORIES="PostgreSQLLogs"
RESOURCE_GROUP=""
DEPLOYMENT_NAME=""
SERVER_IDS=()

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
    --deployment-name)  DEPLOYMENT_NAME="$2";  shift 2 ;;
    --server-id)        SERVER_IDS+=("$2");    shift 2 ;;
    --categories)       CATEGORIES="$2";       shift 2 ;;
    --setting-name)     SETTING_NAME="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate required args ───────────────────────────────────────────────────
if [[ -z "$RESOURCE_GROUP" || -z "$DEPLOYMENT_NAME" || ${#SERVER_IDS[@]} -eq 0 ]]; then
  echo ""
  echo "Error: --resource-group, --deployment-name and at least one --server-id are required."
  echo ""
  echo "Usage:"
  echo "  ./configure-diagnostic-settings.sh \\"
  echo "    --resource-group \"rg-openobserve-postgres-logs\" \\"
  echo "    --deployment-name \"o2-pgflex-202609221200\" \\"
  echo "    --server-id \"/subscriptions/.../flexibleServers/mypgsrv\""
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
echo "  Categories     : $CATEGORIES"
echo ""

# ── Build the logs JSON from the category list ──────────────────────────────
LOGS_JSON="["
FIRST=true
IFS=',' read -ra CATS <<< "$CATEGORIES"
for CAT in "${CATS[@]}"; do
  CAT=$(echo "$CAT" | tr -d '[:space:]')
  if [[ -n "$CAT" ]]; then
    if [[ "$FIRST" == true ]]; then FIRST=false; else LOGS_JSON+=","; fi
    LOGS_JSON+="{\"category\":\"$CAT\",\"enabled\":true}"
  fi
done
LOGS_JSON+="]"

# ── Create one diagnostic setting per server ────────────────────────────────
FAILED=()
for SERVER_ID in "${SERVER_IDS[@]}"; do
  SERVER_NAME="${SERVER_ID##*/}"
  echo "→ Configuring '$SERVER_NAME'..."

  # Replace rather than update: a setting with the same name but a different
  # destination would otherwise silently keep pointing at the old Event Hub.
  if az monitor diagnostic-settings show \
      --name "$SETTING_NAME" --resource "$SERVER_ID" &>/dev/null; then
    echo "  existing setting '$SETTING_NAME' found — replacing"
    az monitor diagnostic-settings delete \
      --name "$SETTING_NAME" --resource "$SERVER_ID" --output none
  fi

  if az monitor diagnostic-settings create \
      --name "$SETTING_NAME" \
      --resource "$SERVER_ID" \
      --event-hub "$EVENT_HUB_NAME" \
      --event-hub-rule "$SEND_RULE_ID" \
      --logs "$LOGS_JSON" \
      --output none; then
    echo "  ✓ $SERVER_NAME connected"
  else
    echo "  ✗ $SERVER_NAME failed"
    FAILED+=("$SERVER_NAME")
  fi
  echo ""
done

# ── Report ──────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED[@]} -eq 0 ]]; then
  echo "  ✓ ${#SERVER_IDS[@]} server(s) streaming PostgreSQL logs to"
  echo "    OpenObserve via Event Hub '$EVENT_HUB_NAME'."
else
  echo "  ${#FAILED[@]} of ${#SERVER_IDS[@]} server(s) FAILED:"
  for f in "${FAILED[@]}"; do echo "    - $f"; done
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Reminder: logs only carry executed plans once auto_explain is loaded and"
echo "configured on the server. See README.md → 'PostgreSQL server parameters'."

if [[ ${#FAILED[@]} -gt 0 ]]; then
  exit 1
fi
