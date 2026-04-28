#!/usr/bin/env bash
# =============================================================================
# setup_monitoring.sh — Wire Azure APIM to Log Analytics for demo monitoring
#
# Run ONCE after deploy_apim.sh. Idempotent — safe to re-run.
#
# What it sets up:
#   1. Log Analytics workspace (airsapimlogs)
#   2. APIM service diagnostic settings → Log Analytics (GatewayLogs)
#   3. APIM API-level diagnostics with body sampling (response body → tokens)
#   4. Operation-level outbound policy to emit x-tokens-consumed header
#   5. Updates demo.env with workspace ID
#   6. Prints portal deep links for the demo
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV="${SCRIPT_DIR}/demo.env"

[[ -f "$DEMO_ENV" ]] || die "demo.env not found at $DEMO_ENV — run deploy_apim.sh first."

# ── Load demo.env ─────────────────────────────────────────────────────────────
set -a; source "$DEMO_ENV"; set +a

RESOURCE_GROUP="${AZURE_OPENAI_RESOURCE_GROUP:-rg-airs-apim-pov}"
APIM_NAME="airsapimgw"
API_ID="azure-openai-api"
OPERATION_ID="all-operations"
PREFIX="airsapim"
LAW_NAME="${PREFIX}logs"

az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  APIM Monitoring Setup — Prisma AIRS POV                    ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── 1. Log Analytics Workspace ────────────────────────────────────────────────
info "Step 1/4: Ensuring Log Analytics workspace '$LAW_NAME'..."
if az monitor log-analytics workspace show -n "$LAW_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Log Analytics workspace already exists."
else
  az monitor log-analytics workspace create \
    -n "$LAW_NAME" \
    -g "$RESOURCE_GROUP" \
    --location eastus \
    --retention-time 30 \
    -o none
  success "Log Analytics workspace created (30-day retention)."
fi

LAW_RESOURCE_ID=$(az monitor log-analytics workspace show \
  -n "$LAW_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  -n "$LAW_NAME" -g "$RESOURCE_GROUP" --query customerId -o tsv)
LAW_KEY=$(az monitor log-analytics workspace get-shared-keys \
  -n "$LAW_NAME" -g "$RESOURCE_GROUP" --query primarySharedKey -o tsv)

info "Workspace ID: $LAW_WORKSPACE_ID"

# ── 2. APIM Service Diagnostic Settings ──────────────────────────────────────
info "Step 2/4: Enabling APIM Gateway Logs → Log Analytics..."

APIM_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}"

EXISTING_DIAG=$(az monitor diagnostic-settings show \
  --resource "$APIM_RESOURCE_ID" \
  --name "apim-gateway-logs" 2>/dev/null | jq -r '.name // empty' || true)

DIAG_BODY="{
  \"properties\": {
    \"workspaceId\": \"${LAW_RESOURCE_ID}\",
    \"logs\": [{
      \"category\": \"GatewayLogs\",
      \"enabled\": true,
      \"retentionPolicy\": {\"enabled\": false, \"days\": 0}
    }],
    \"metrics\": [{
      \"category\": \"AllMetrics\",
      \"enabled\": true,
      \"retentionPolicy\": {\"enabled\": false, \"days\": 0}
    }]
  }
}"

if [[ -n "$EXISTING_DIAG" ]]; then
  az rest \
    --method PUT \
    --url "https://management.azure.com${APIM_RESOURCE_ID}/providers/microsoft.insights/diagnosticSettings/apim-gateway-logs?api-version=2021-05-01-preview" \
    --body "$DIAG_BODY" \
    -o none
  success "Diagnostic settings updated."
else
  az rest \
    --method PUT \
    --url "https://management.azure.com${APIM_RESOURCE_ID}/providers/microsoft.insights/diagnosticSettings/apim-gateway-logs?api-version=2021-05-01-preview" \
    --body "$DIAG_BODY" \
    -o none
  success "Diagnostic settings created — GatewayLogs and AllMetrics → Log Analytics."
fi

# ── 3. APIM Logger + API-Level Diagnostics (body sampling for token counts) ───
# The azuremonitor diagnostic type requires a loggerId that points to an APIM
# logger resource of type "azureMonitor". We create the logger first, then
# reference it in the API-level diagnostic.
# Sampling the backend response body at 100% lets us parse usage.total_tokens
# from the OpenAI response in Log Analytics queries.
info "Step 3/4: Creating APIM logger and enabling API-level diagnostics..."

LOGGER_NAME="azuremonitor"
LOGGER_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/loggers/${LOGGER_NAME}"

# Create (or update) the azureMonitor logger on the APIM service
az rest \
  --method PUT \
  --url "https://management.azure.com${LOGGER_RESOURCE_ID}?api-version=2022-08-01" \
  --body "{
    \"properties\": {
      \"loggerType\": \"azureMonitor\",
      \"isBuffered\": true
    }
  }" \
  -o none
success "APIM azureMonitor logger ready."

az rest \
  --method PUT \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_ID}/diagnostics/azuremonitor?api-version=2022-08-01" \
  --body "{
    \"properties\": {
      \"loggerId\": \"${LOGGER_RESOURCE_ID}\",
      \"verbosity\": \"information\",
      \"sampling\": {\"samplingType\": \"fixed\", \"percentage\": 100},
      \"request\":  {\"headers\": [\"x-session-id\", \"Content-Type\"], \"body\": {\"bytes\": 0}},
      \"response\": {\"headers\": [\"Content-Type\", \"x-tokens-consumed\"],  \"body\": {\"bytes\": 0}},
      \"backend\": {
        \"request\":  {\"headers\": [], \"body\": {\"bytes\": 0}},
        \"response\": {\"headers\": [], \"body\": {\"bytes\": 4096}}
      },
      \"logClientIp\": true
    }
  }" \
  -o none
success "API diagnostics enabled (100% sampling, backend response body up to 4KB)."

# ── 4. Operation-Level Outbound Policy — emit x-tokens-consumed header ────────
# Adds a response header with the token count from the OpenAI response body.
# The header is captured by the diagnostic settings above and appears in
# ApiManagementGatewayLogs as a queryable field for the monitor dashboard.
info "Step 4/4: Patching operation-level policy to emit token count header..."

TOKEN_POLICY='<policies>
  <inbound><base /></inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <set-header name="x-tokens-consumed" exists-action="override">
      <value>@{
        try {
          var body = context.Response.Body.As&lt;JObject&gt;(preserveContent: true);
          var tokens = body["usage"]?["total_tokens"];
          return tokens != null ? tokens.ToString() : "0";
        } catch { return "0"; }
      }</value>
    </set-header>
  </outbound>
  <on-error><base /></on-error>
</policies>'

az rest \
  --method PUT \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_ID}/operations/${OPERATION_ID}/policies/policy?api-version=2022-08-01" \
  --body "{
    \"properties\": {
      \"format\": \"rawxml\",
      \"value\": $(echo "$TOKEN_POLICY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    }
  }" \
  -o none
success "Operation-level policy patched — x-tokens-consumed header will appear in logs."

# ── Update demo.env ───────────────────────────────────────────────────────────
if grep -q "^LAW_WORKSPACE_ID=" "$DEMO_ENV" 2>/dev/null; then
  sed -i "s|^LAW_WORKSPACE_ID=.*|LAW_WORKSPACE_ID=${LAW_WORKSPACE_ID}|" "$DEMO_ENV"
  sed -i "s|^LAW_RESOURCE_ID=.*|LAW_RESOURCE_ID=${LAW_RESOURCE_ID}|" "$DEMO_ENV"
else
  cat >> "$DEMO_ENV" <<EOF

# ── Log Analytics (added by setup_monitoring.sh) ──────────────────
LAW_WORKSPACE_ID=${LAW_WORKSPACE_ID}
LAW_RESOURCE_ID=${LAW_RESOURCE_ID}
EOF
fi
success "demo.env updated with Log Analytics workspace ID."

# ── Build portal deep links ────────────────────────────────────────────────────
BASE="https://portal.azure.com/#@${TENANT_ID}/resource/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers"
APIM_BASE="${BASE}/Microsoft.ApiManagement/service/${APIM_NAME}"
LAW_BASE="${BASE}/Microsoft.OperationalInsights/workspaces/${LAW_NAME}"

# Pre-built KQL for the demo Log Analytics link
KQL=$(python3 -c "
import urllib.parse
q = '''ApiManagementGatewayLogs
| where TimeGenerated > ago(30m)
| extend Tokens = tolong(parse_json(ResponseHeaders)[\"x-tokens-consumed\"])
| project TimeGenerated, Method, ResponseCode, DurationMs, Tokens,
          IsAIRSBlock = (ResponseCode == 403),
          Path = tostring(split(Url, \"/\")[-1])
| order by TimeGenerated desc
| take 50'''
print(urllib.parse.quote(q))
")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Setup Complete — Demo Portal Cheat Sheet                   ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}${BOLD}APIM BLADES (open in Azure Portal):${NC}"
echo -e "  📊 Analytics (traffic + latency graphs):"
echo -e "     ${YELLOW}${APIM_BASE}/analytics${NC}"
echo ""
echo -e "  📜 Policy editor (shows AIRS XML inline):"
echo -e "     ${YELLOW}${APIM_BASE}/apis/${API_ID}/policies${NC}"
echo ""
echo -e "  🧪 API Test console (live test + trace):"
echo -e "     ${YELLOW}${APIM_BASE}/apis/${API_ID}/operations/${OPERATION_ID}${NC}"
echo ""
echo -e "  🔑 Subscriptions (show subscription key):"
echo -e "     ${YELLOW}${APIM_BASE}/subscriptions${NC}"
echo ""
echo -e "  ${CYAN}${BOLD}LOG ANALYTICS (KQL queries):${NC}"
echo -e "  📋 Workspace logs (run pre-built query):"
echo -e "     ${YELLOW}${LAW_BASE}/logs${NC}"
echo ""
echo -e "  ${CYAN}${BOLD}COPY-PASTE KQL QUERIES FOR THE DEMO:${NC}"
cat <<'KQLEOF'

  ── Last 30 min traffic with AIRS blocks and token counts ──
  ApiManagementGatewayLogs
  | where TimeGenerated > ago(30m)
  | extend Tokens = tolong(parse_json(ResponseHeaders)["x-tokens-consumed"])
  | project TimeGenerated, Method, ResponseCode, DurationMs, Tokens,
            AIRSBlock = (ResponseCode == 403)
  | order by TimeGenerated desc

  ── AIRS block summary ──────────────────────────────────────
  ApiManagementGatewayLogs
  | where TimeGenerated > ago(30m) and ResponseCode == 403
  | extend Msg = parse_json(BackendResponseBody).error
  | project TimeGenerated, DurationMs, BlockReason = tostring(Msg)
  | order by TimeGenerated desc

  ── Token usage over time ────────────────────────────────────
  ApiManagementGatewayLogs
  | where TimeGenerated > ago(1h) and ResponseCode == 200
  | extend Tokens = tolong(parse_json(ResponseHeaders)["x-tokens-consumed"])
  | summarize TotalTokens=sum(Tokens), Requests=count() by bin(TimeGenerated, 5m)
  | order by TimeGenerated desc

KQLEOF

echo ""
echo -e "  ${CYAN}${BOLD}TERMINAL MONITOR (run in a new terminal):${NC}"
echo -e "     ${YELLOW}cd ~/prisma-airs-apim-pov/azure-search-openai-demo && ./monitor_apim.sh${NC}"
echo ""
echo -e "  ${YELLOW}Note:${NC} Log Analytics has a ~5-10 min ingestion delay."
echo -e "        Generate traffic first (run_security_tests.py), then open the monitor."
echo ""
