#!/bin/bash
# OpenObserve - Azure Activity Logs Diagnostic Setting Setup
# Usage:
#   curl -s https://your-host/azure-activity-logs.sh | bash -s -- \
#     --resource-group "my-rg" \
#     --deployment-name "my-deployment" \
#     --categories "Administrative,Security,ServiceHealth,Alert,Recommendation,Policy,Autoscale,ResourceHealth" \
#     --setting-name "o2-activity-to-eventhub"

set -e

# ── Defaults ────────────────────────────────────────────────────────────────
SETTING_NAME="o2-activity-to-eventhub"
CATEGORIES="Administrative,Security,ServiceHealth,Alert,Recommendation,Policy,Autoscale,ResourceHealth"
RESOURCE_GROUP=""
DEPLOYMENT_NAME=""

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
    --deployment-name)  DEPLOYMENT_NAME="$2";  shift 2 ;;
    --categories)       CATEGORIES="$2";       shift 2 ;;
    --setting-name)     SETTING_NAME="$2";     shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Validate required args ───────────────────────────────────────────────────
if [[ -z "$RESOURCE_GROUP" || -z "$DEPLOYMENT_NAME" ]]; then
  echo ""
  echo "Error: --resource-group and --deployment-name are required."
  echo ""
  echo "Usage:"
  echo "  curl -s https://your-host/azure-activity-logs.sh | bash -s -- \\"
  echo "    --resource-group \"my-rg\" \\"
  echo "    --deployment-name \"my-deployment\" \\"
  echo "    --categories \"Administrative,Security,Policy\""
  echo ""
  exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OpenObserve — Azure Activity Logs Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Resource group : $RESOURCE_GROUP"
echo "  Deployment     : $DEPLOYMENT_NAME"
echo "  Setting name   : $SETTING_NAME"
echo "  Categories     : $CATEGORIES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Check az CLI is available ────────────────────────────────────────────────
if ! command -v az &>/dev/null; then
  echo "Error: Azure CLI (az) is not installed."
  echo "Install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli"
  exit 1
fi

# ── Step 1: Read deployment outputs ─────────────────────────────────────────
echo "→ Reading deployment outputs..."

EVENT_HUB_NAME=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.eventHubName.value" -o tsv 2>/dev/null)

SEND_RULE_ID=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --query "properties.outputs.sendAuthRuleId.value" -o tsv 2>/dev/null)

if [[ -z "$EVENT_HUB_NAME" || -z "$SEND_RULE_ID" ]]; then
  echo ""
  echo "Error: Could not read deployment outputs."
  echo "  Make sure the resource group and deployment name are correct"
  echo "  and that the ARM deployment completed successfully."
  exit 1
fi

echo "  Event Hub      : $EVENT_HUB_NAME"
echo "  Auth Rule ID   : $SEND_RULE_ID"
echo ""

# ── Step 2: Get subscription location ───────────────────────────────────────
echo "→ Getting subscription location..."

LOCATION=$(az account show --query "homeTenantId" -o tsv &>/dev/null && \
  az account list-locations --query "[?metadata.regionCategory=='Recommended'] | [0].name" -o tsv 2>/dev/null || echo "eastus")

if [[ -z "$LOCATION" ]]; then
  LOCATION="eastus"
fi

echo "  Location       : $LOCATION"
echo ""

# ── Step 3: Build logs JSON from categories ──────────────────────────────────
echo "→ Building log category configuration..."

LOGS_JSON="["
FIRST=true
IFS=',' read -ra CATS <<< "$CATEGORIES"
for CAT in "${CATS[@]}"; do
  CAT=$(echo "$CAT" | tr -d '[:space:]')
  if [[ -n "$CAT" ]]; then
    if [[ "$FIRST" == true ]]; then
      FIRST=false
    else
      LOGS_JSON+=","
    fi
    LOGS_JSON+="{\"category\":\"$CAT\",\"enabled\":true}"
  fi
done
LOGS_JSON+="]"

echo "  Enabled: ${CATS[*]}"
echo ""

# ── Step 4: Create diagnostic setting ───────────────────────────────────────
echo "→ Creating subscription diagnostic setting '$SETTING_NAME'..."

az monitor diagnostic-settings subscription create \
  --name "$SETTING_NAME" \
  --location "$LOCATION" \
  --event-hub "$EVENT_HUB_NAME" \
  --event-hub-auth-rule "$SEND_RULE_ID" \
  --logs "$LOGS_JSON" \
  --output none

echo ""

# ── Step 5: Verify ───────────────────────────────────────────────────────────
echo "→ Verifying..."

RESULT=$(az monitor diagnostic-settings subscription list \
  --query "[?name=='$SETTING_NAME'].{Name:name, Location:location}" \
  -o table 2>/dev/null)

if echo "$RESULT" | grep -q "$SETTING_NAME"; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✓ Done! Activity Logs are now streaming to"
  echo "    OpenObserve via Event Hub."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
else
  echo "Warning: Could not verify the setting was created."
  echo "Run this to check manually:"
  echo "  az monitor diagnostic-settings subscription list --query \"[?name=='$SETTING_NAME']\" -o table"
fi
