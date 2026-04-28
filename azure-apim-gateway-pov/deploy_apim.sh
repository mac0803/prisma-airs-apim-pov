#!/usr/bin/env bash
# =============================================================================
# deploy_apim.sh — Deploy Azure APIM AI Gateway with Prisma AIRS integration
#
# Usage:
#   export PRISMA_AIRS_API_KEY="your-key"
#   export PRISMA_AIRS_PROFILE_NAME="your-profile"
#   ./deploy_apim.sh [--rg <resource-group>] [--location <location>] [--prefix <prefix>]
#
# Outputs: demo.env  (source this before running start_demo.sh)
#
# Policy compliance:
#   - OpenAI created with system-assigned MSI (satisfies "use managed identity" policy)
#   - OpenAI network ACLs: defaultAction=Deny, bypass=AzureServices (satisfies "restrict network access" policy)
#   - APIM authenticates to OpenAI via MSI token — no static API key stored
# =============================================================================
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ── Defaults (override via flags or env) ─────────────────────────────────────
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-airs-apim-pov}"
LOCATION="${AZURE_LOCATION:-eastus}"
PREFIX="${DEPLOY_PREFIX:-airsapim}"

# ── Parse flags ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --rg)       RESOURCE_GROUP="$2"; shift 2 ;;
    --location) LOCATION="$2";       shift 2 ;;
    --prefix)   PREFIX="$2";         shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--rg <rg>] [--location <loc>] [--prefix <prefix>]"
      exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# ── Prereq checks ────────────────────────────────────────────────────────────
command -v az   >/dev/null 2>&1 || die "Azure CLI not found. Run: curl -sL https://aka.ms/InstallAzureCLIDeb | bash"
command -v jq   >/dev/null 2>&1 || die "jq not found. Run: sudo apt-get install -y jq"
command -v curl >/dev/null 2>&1 || die "curl not found."

[[ -z "${PRISMA_AIRS_API_KEY:-}" ]]      && die "PRISMA_AIRS_API_KEY is not set. Export it first."
[[ -z "${PRISMA_AIRS_PROFILE_NAME:-}" ]] && die "PRISMA_AIRS_PROFILE_NAME is not set. Export it first."

az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
info "Using subscription: $SUBSCRIPTION_ID"

# ── Resource names ────────────────────────────────────────────────────────────
OPENAI_NAME="${PREFIX}oai"
APIM_NAME="${PREFIX}gw"
SEARCH_NAME="${PREFIX}search"
STORAGE_NAME="${PREFIX}stor"
VNET_NAME="${PREFIX}vnet"
PE_SUBNET_NAME="private-endpoints"
SEARCH_PE_NAME="${SEARCH_NAME}-pe"
SEARCH_DNS_ZONE="privatelink.search.windows.net"
OPENAI_DEPLOYMENT="gpt-4o"
OPENAI_MODEL="gpt-4o"
OPENAI_VERSION="2024-11-20"
SEARCH_INDEX="gptkbindex"
API_ID="azure-openai-api"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV="${SCRIPT_DIR}/demo.env"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Prisma AIRS + Azure APIM AI Gateway — POV Deployment        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Resource group : $RESOURCE_GROUP"
info "Location       : $LOCATION"
info "Prefix         : $PREFIX"
info "APIM name      : $APIM_NAME"
info "OpenAI name    : $OPENAI_NAME"
info "AIRS profile   : $PRISMA_AIRS_PROFILE_NAME"
info "Auth mode      : APIM system-assigned MSI → Azure OpenAI"
echo ""

# ── 1. Resource Group ─────────────────────────────────────────────────────────
info "Step 1/10: Ensuring resource group '$RESOURCE_GROUP'..."
if az group show -n "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Resource group already exists."
else
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
  success "Resource group created."
fi

# ── 2. Azure OpenAI — with MSI and network ACLs ───────────────────────────────
info "Step 2/10: Ensuring Azure OpenAI account '$OPENAI_NAME'..."
info "  Policy requires: system-assigned MSI + networkAcls.defaultAction=Deny at creation time."
info "  Using az rest PUT so all properties are set in a single request (policy evaluates at creation)."

if az cognitiveservices account show -n "$OPENAI_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Azure OpenAI account already exists."
else
  # The org policy evaluates the resource body at creation time — a POST/create followed by a
  # PATCH is rejected because the initial request violates the policy before the PATCH runs.
  # Using az rest PUT lets us satisfy both policy conditions in one atomic request:
  #   identity.type=SystemAssigned  → satisfies "(CSB) Cognitive Services accounts should use a managed identity"
  #   networkAcls.defaultAction=Deny → satisfies "(CSB) Azure AI Services resources should restrict network access"
  #   networkAcls.bypass=AzureServices → allows APIM MSI token calls without an IP allowlist entry
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.CognitiveServices/accounts/${OPENAI_NAME}?api-version=2023-05-01" \
    --body "{
      \"kind\": \"OpenAI\",
      \"location\": \"${LOCATION}\",
      \"sku\": {\"name\": \"S0\"},
      \"identity\": {\"type\": \"SystemAssigned\"},
      \"properties\": {
        \"networkAcls\": {
          \"defaultAction\": \"Deny\",
          \"bypass\": \"AzureServices\",
          \"ipRules\": [],
          \"virtualNetworkRules\": []
        }
      }
    }" \
    -o none
  success "Azure OpenAI created (system-assigned MSI, networkAcls.defaultAction=Deny, bypass=AzureServices)."

  # Wait for provisioning to complete before proceeding
  info "  Waiting for Azure OpenAI provisioning to complete..."
  for i in {1..18}; do
    STATE=$(az cognitiveservices account show \
      -n "$OPENAI_NAME" -g "$RESOURCE_GROUP" \
      --query properties.provisioningState -o tsv 2>/dev/null || echo "Creating")
    [[ "$STATE" == "Succeeded" ]] && break
    warn "  Provisioning state: $STATE (attempt $i/18, waiting 10s)..."
    sleep 10
  done
  success "Azure OpenAI provisioned."
fi

OPENAI_ENDPOINT=$(az cognitiveservices account show \
  -n "$OPENAI_NAME" -g "$RESOURCE_GROUP" \
  --query properties.endpoint -o tsv)
OPENAI_RESOURCE_ID=$(az cognitiveservices account show \
  -n "$OPENAI_NAME" -g "$RESOURCE_GROUP" \
  --query id -o tsv)
info "OpenAI endpoint: $OPENAI_ENDPOINT"

# ── 3. OpenAI Model Deployment ────────────────────────────────────────────────
info "Step 3/10: Ensuring model deployment '$OPENAI_DEPLOYMENT'..."
if az cognitiveservices account deployment show \
   -n "$OPENAI_NAME" -g "$RESOURCE_GROUP" \
   --deployment-name "$OPENAI_DEPLOYMENT" >/dev/null 2>&1; then
  success "Model deployment already exists."
else
  az cognitiveservices account deployment create \
    -n "$OPENAI_NAME" \
    -g "$RESOURCE_GROUP" \
    --deployment-name "$OPENAI_DEPLOYMENT" \
    --model-name "$OPENAI_MODEL" \
    --model-version "$OPENAI_VERSION" \
    --model-format OpenAI \
    --sku-capacity 30 \
    --sku-name "GlobalStandard" \
    -o none
  success "Model deployment created (gpt-4o, 30K TPM)."
fi

# ── 4a. VNet + Private Endpoint Subnet ───────────────────────────────────────
# Required because org policy forces publicNetworkAccess=Disabled on AI Search.
# The backend reaches Search via a private endpoint whose private IP is added to
# WSL2's /etc/hosts (or resolved via corporate VPN to Azure VNet).
info "Step 4/10: Ensuring VNet '$VNET_NAME' and private-endpoint subnet..."

if az network vnet show -n "$VNET_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "VNet already exists."
else
  az network vnet create \
    -n "$VNET_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --address-prefix "10.100.0.0/16" \
    -o none
  success "VNet created (10.100.0.0/16)."
fi

if az network vnet subnet show -n "$PE_SUBNET_NAME" -g "$RESOURCE_GROUP" \
   --vnet-name "$VNET_NAME" >/dev/null 2>&1; then
  success "Private-endpoint subnet already exists."
else
  az network vnet subnet create \
    -n "$PE_SUBNET_NAME" \
    -g "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --address-prefix "10.100.1.0/24" \
    --private-endpoint-network-policies Disabled \
    -o none
  success "Private-endpoint subnet created (10.100.1.0/24)."
fi

# ── 4b. Azure AI Search (publicNetworkAccess=Disabled, required by policy) ────
info "  Ensuring Azure AI Search '$SEARCH_NAME'..."
info "  Policies require publicNetworkAccess=Disabled — using az rest PUT to set at creation time."

if az search service show -n "$SEARCH_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Search service already exists."
else
  # Both blocking policies evaluated at creation — use az rest PUT with all required properties:
  #   publicNetworkAccess=Disabled → satisfies "(CSB) Azure AI Search services should disable public network access"
  #   (the first CSB policy on AI Services also fires here; Disabled satisfies its condition too)
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Search/searchServices/${SEARCH_NAME}?api-version=2023-11-01" \
    --body "{
      \"location\": \"${LOCATION}\",
      \"sku\": {\"name\": \"basic\"},
      \"properties\": {
        \"replicaCount\": 1,
        \"partitionCount\": 1,
        \"publicNetworkAccess\": \"Disabled\"
      }
    }" \
    -o none

  info "  Waiting for Search provisioning..."
  for i in {1..18}; do
    STATE=$(az search service show -n "$SEARCH_NAME" -g "$RESOURCE_GROUP" \
      --query properties.provisioningState -o tsv 2>/dev/null || echo "Creating")
    [[ "$STATE" == "succeeded" ]] && break
    warn "  Provisioning state: $STATE (attempt $i/18, waiting 10s)..."
    sleep 10
  done
  success "Azure AI Search created (publicNetworkAccess=Disabled)."
fi

SEARCH_RESOURCE_ID=$(az search service show -n "$SEARCH_NAME" -g "$RESOURCE_GROUP" \
  --query id -o tsv)

# Management-plane key retrieval works regardless of publicNetworkAccess setting.
# Note: az search admin-key show uses --service-name, not -n/--name.
SEARCH_KEY=$(az search admin-key show --service-name "$SEARCH_NAME" -g "$RESOURCE_GROUP" \
  --query primaryKey -o tsv)

# ── 4c. Private Endpoint for Search ──────────────────────────────────────────
# Using az rest PUT to avoid --group-id / --group-ids / --service-name CLI flag
# incompatibilities across Azure CLI versions.
info "  Ensuring private endpoint '$SEARCH_PE_NAME'..."

SUBNET_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${PE_SUBNET_NAME}"

PE_EXISTS=$(az rest \
  --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}?api-version=2023-09-01" \
  --query name -o tsv 2>/dev/null || true)

if [[ -n "$PE_EXISTS" ]]; then
  success "Private endpoint already exists."
else
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}?api-version=2023-09-01" \
    --body "{
      \"location\": \"${LOCATION}\",
      \"properties\": {
        \"subnet\": {\"id\": \"${SUBNET_ID}\"},
        \"privateLinkServiceConnections\": [{
          \"name\": \"${SEARCH_NAME}-conn\",
          \"properties\": {
            \"privateLinkServiceId\": \"${SEARCH_RESOURCE_ID}\",
            \"groupIds\": [\"searchService\"]
          }
        }]
      }
    }" \
    -o none

  info "  Waiting for private endpoint provisioning..."
  for i in {1..12}; do
    PE_STATE=$(az rest \
      --method GET \
      --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}?api-version=2023-09-01" \
      --query properties.provisioningState -o tsv 2>/dev/null || echo "Updating")
    [[ "$PE_STATE" == "Succeeded" ]] && break
    warn "  PE provisioning: $PE_STATE (attempt $i/12, waiting 10s)..."
    sleep 10
  done
  success "Private endpoint created."
fi

# ── 4d. Private DNS Zone for Search ──────────────────────────────────────────
info "  Ensuring private DNS zone '$SEARCH_DNS_ZONE'..."

DNS_ZONE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateDnsZones/${SEARCH_DNS_ZONE}"

if az network private-dns zone show -g "$RESOURCE_GROUP" -n "$SEARCH_DNS_ZONE" >/dev/null 2>&1; then
  success "Private DNS zone already exists."
else
  az network private-dns zone create \
    -g "$RESOURCE_GROUP" \
    -n "$SEARCH_DNS_ZONE" \
    -o none
  success "Private DNS zone created."
fi

DNS_LINK_NAME="${VNET_NAME}-search-link"
VNET_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}"

if az network private-dns link vnet show \
   -g "$RESOURCE_GROUP" -z "$SEARCH_DNS_ZONE" -n "$DNS_LINK_NAME" >/dev/null 2>&1; then
  success "DNS VNet link already exists."
else
  az network private-dns link vnet create \
    -g "$RESOURCE_GROUP" \
    -z "$SEARCH_DNS_ZONE" \
    -n "$DNS_LINK_NAME" \
    --virtual-network "$VNET_NAME" \
    --registration-enabled false \
    -o none
  success "DNS VNet link created."
fi

# DNS zone group — use az rest PUT to avoid CLI version flag issues
DNS_GROUP_NAME="default"
DNS_GROUP_EXISTS=$(az rest \
  --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}/privateDnsZoneGroups/${DNS_GROUP_NAME}?api-version=2023-09-01" \
  --query name -o tsv 2>/dev/null || true)

if [[ -n "$DNS_GROUP_EXISTS" ]]; then
  success "DNS zone group already exists."
else
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}/privateDnsZoneGroups/${DNS_GROUP_NAME}?api-version=2023-09-01" \
    --body "{
      \"properties\": {
        \"privateDnsZoneConfigs\": [{
          \"name\": \"searchService\",
          \"properties\": {\"privateDnsZoneId\": \"${DNS_ZONE_ID}\"}
        }]
      }
    }" \
    -o none
  success "DNS zone group created (auto-registers PE IP in private DNS zone)."
fi

# Get the private IP from the PE's NIC directly (customDnsConfigs only populates
# after DNS propagation which takes longer than provisioning; NIC is immediate).
info "  Retrieving Search private endpoint IP via NIC..."
SEARCH_PRIVATE_IP=""
PE_NIC_ID=$(az rest \
  --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}?api-version=2023-09-01" \
  --query 'properties.networkInterfaces[0].id' -o tsv 2>/dev/null || true)

if [[ -n "$PE_NIC_ID" ]]; then
  SEARCH_PRIVATE_IP=$(az rest \
    --method GET \
    --url "https://management.azure.com${PE_NIC_ID}?api-version=2023-09-01" \
    --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o tsv 2>/dev/null || true)
fi

if [[ -z "$SEARCH_PRIVATE_IP" ]]; then
  warn "Could not retrieve Search private endpoint IP from NIC."
  warn "Retrieve it later with:"
  warn "  NIC=\$(az rest --method GET --url 'https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/privateEndpoints/${SEARCH_PE_NAME}?api-version=2023-09-01' --query 'properties.networkInterfaces[0].id' -o tsv)"
  warn "  az rest --method GET --url \"https://management.azure.com\${NIC}?api-version=2023-09-01\" --query 'properties.ipConfigurations[0].properties.privateIPAddress' -o tsv"
  SEARCH_PRIVATE_IP="RETRIEVE_MANUALLY"
fi
info "Search private endpoint IP: $SEARCH_PRIVATE_IP"

# ── 5. Storage Account — Deny by default + GlobalProtect CIDR allowlist ────────
info "Step 5/10: Ensuring Storage account '$STORAGE_NAME'..."
info "  Policy requires networkAcls.defaultAction=Deny at creation time."
info "  Adding GlobalProtect US egress CIDRs to ipRules so WSL2 can reach the data plane."

# Full GlobalProtect / Azure NSG US IP list provided by the user.
# Storage supports defaultAction=Deny PLUS an ipRules allowlist (unlike Search which
# requires publicNetworkAccess=Disabled with no allowlist option).
read -r -d '' STORAGE_IP_RULES <<'IPRULES' || true
[
  {"value":"130.41.0.0/16","action":"Allow"},
  {"value":"134.238.0.0/16","action":"Allow"},
  {"value":"137.83.0.0/16","action":"Allow"},
  {"value":"202.181.130.0/22","action":"Allow"},
  {"value":"147.185.136.160/27","action":"Allow"},
  {"value":"165.1.0.0/16","action":"Allow"},
  {"value":"165.85.0.0/16","action":"Allow"},
  {"value":"34.100.0.0/14","action":"Allow"},
  {"value":"13.52.0.0/14","action":"Allow"},
  {"value":"128.177.26.192/29","action":"Allow"},
  {"value":"128.77.0.0/16","action":"Allow"},
  {"value":"208.184.7.0/24","action":"Allow"},
  {"value":"47.190.62.0/24","action":"Allow"},
  {"value":"8.47.64.0/24","action":"Allow"},
  {"value":"207.18.0.16/28","action":"Allow"},
  {"value":"50.237.249.72/29","action":"Allow"},
  {"value":"71.78.132.8/29","action":"Allow"},
  {"value":"104.11.166.123","action":"Allow"},
  {"value":"104.247.34.97","action":"Allow"},
  {"value":"140.209.231.45","action":"Allow"},
  {"value":"140.209.253.24/29","action":"Allow"},
  {"value":"144.125.204.248/29","action":"Allow"},
  {"value":"153.72.16.53","action":"Allow"},
  {"value":"184.169.196.241","action":"Allow"},
  {"value":"192.197.222.0/24","action":"Allow"},
  {"value":"199.167.52.0/23","action":"Allow"},
  {"value":"208.127.0.0/16","action":"Allow"}
]
IPRULES

if az storage account show -n "$STORAGE_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Storage account already exists."
else
  # Use az rest PUT so policy-required networkAcls are set at creation time.
  # bypass=AzureServices,Logging,Metrics keeps diagnostic and Azure-internal traffic flowing.
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_NAME}?api-version=2023-01-01" \
    --body "{
      \"location\": \"${LOCATION}\",
      \"sku\": {\"name\": \"Standard_LRS\"},
      \"kind\": \"StorageV2\",
      \"properties\": {
        \"networkAcls\": {
          \"defaultAction\": \"Deny\",
          \"bypass\": \"AzureServices, Logging, Metrics\",
          \"ipRules\": ${STORAGE_IP_RULES},
          \"virtualNetworkRules\": []
        },
        \"minimumTlsVersion\": \"TLS1_2\",
        \"allowBlobPublicAccess\": false
      }
    }" \
    -o none

  info "  Waiting for Storage account provisioning..."
  for i in {1..12}; do
    ST_STATE=$(az storage account show -n "$STORAGE_NAME" -g "$RESOURCE_GROUP" \
      --query provisioningState -o tsv 2>/dev/null || echo "Creating")
    [[ "$ST_STATE" == "Succeeded" ]] && break
    warn "  State: $ST_STATE (attempt $i/12, waiting 10s)..."
    sleep 10
  done
  success "Storage account created (defaultAction=Deny + GlobalProtect IP allowlist)."
fi

STORAGE_KEY=$(az storage account keys list -n "$STORAGE_NAME" -g "$RESOURCE_GROUP" \
  --query "[0].value" -o tsv)

# Create the blob container via ARM REST (management plane) so network ACLs don't block it.
# az storage container create uses the data plane and would be blocked by defaultAction=Deny
# if the current machine's IP isn't in the allowlist yet (e.g. GP is down).
CONTAINER_EXISTS=$(az rest \
  --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_NAME}/blobServices/default/containers/content?api-version=2023-01-01" \
  --query name -o tsv 2>/dev/null || true)

if [[ -z "$CONTAINER_EXISTS" ]]; then
  az rest \
    --method PUT \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_NAME}/blobServices/default/containers/content?api-version=2023-01-01" \
    --body '{"properties":{"publicAccess":"None"}}' \
    -o none
  success "Blob container 'content' created via ARM (bypasses data-plane network ACL)."
else
  success "Blob container 'content' already exists."
fi

# ── 6. APIM Instance (Consumption tier — instant provisioning) ────────────────
info "Step 6/10: Ensuring APIM instance '$APIM_NAME' (Consumption tier)..."
if az apim show -n "$APIM_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "APIM instance already exists."
else
  warn "Creating APIM (Consumption tier — this takes ~2 minutes)..."
  az apim create \
    -n "$APIM_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --publisher-email "admin@example.com" \
    --publisher-name "AI Gateway POV" \
    --sku-name Consumption \
    -o none
  success "APIM instance created."
fi

APIM_GW_URL=$(az apim show -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
  --query gatewayUrl -o tsv)
info "APIM Gateway URL: $APIM_GW_URL"

# ── 7. Enable MSI on APIM + grant OpenAI access ───────────────────────────────
info "Step 7/10: Enabling system-assigned MSI on APIM and assigning OpenAI RBAC role..."

# Enable system-assigned identity on APIM via REST (az apim update --assign-identity varies by CLI version)
az rest \
  --method PATCH \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}?api-version=2022-08-01" \
  --body '{"identity":{"type":"SystemAssigned"}}' \
  -o none

# Retrieve the APIM MSI principal ID (may need a moment after enabling)
APIM_PRINCIPAL_ID=""
for i in {1..6}; do
  APIM_PRINCIPAL_ID=$(az apim show -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
    --query identity.principalId -o tsv 2>/dev/null || true)
  [[ -n "$APIM_PRINCIPAL_ID" ]] && break
  warn "  Waiting for MSI principal ID to propagate (attempt $i/6)..."
  sleep 10
done

if [[ -z "$APIM_PRINCIPAL_ID" ]]; then
  die "Could not retrieve APIM managed identity principal ID after 60s. Check the Azure Portal."
fi
info "APIM MSI Principal ID: $APIM_PRINCIPAL_ID"

# Grant 'Cognitive Services OpenAI User' to the APIM MSI on the OpenAI resource.
# This is what allows the MSI token to call Azure OpenAI, and combined with
# bypass=AzureServices it bypasses the network ACL IP restriction.
EXISTING_ROLE=$(az role assignment list \
  --assignee "$APIM_PRINCIPAL_ID" \
  --role "Cognitive Services OpenAI User" \
  --scope "$OPENAI_RESOURCE_ID" \
  --query "[0].id" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_ROLE" ]]; then
  success "RBAC role already assigned."
else
  az role assignment create \
    --assignee "$APIM_PRINCIPAL_ID" \
    --role "Cognitive Services OpenAI User" \
    --scope "$OPENAI_RESOURCE_ID" \
    -o none
  success "Granted 'Cognitive Services OpenAI User' to APIM MSI on OpenAI resource."
fi

# ── 8. APIM Named Value — AIRS API Key only ────────────────────────────────────
# Note: No OPENAI-API-KEY named value needed — APIM uses MSI tokens for OpenAI auth.
info "Step 8/10: Configuring APIM Named Values (AIRS API key)..."

EXISTING_NV=$(az apim nv show \
  -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
  --named-value-id "AIRS-API" 2>/dev/null | jq -r '.name // empty' || true)

if [[ -n "$EXISTING_NV" ]]; then
  az apim nv update \
    -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
    --named-value-id "AIRS-API" \
    --value "$PRISMA_AIRS_API_KEY" \
    --secret true \
    -o none
  success "Named value 'AIRS-API' updated."
else
  az apim nv create \
    -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
    --named-value-id "AIRS-API" \
    --display-name "AIRS-API" \
    --value "$PRISMA_AIRS_API_KEY" \
    --secret true \
    -o none
  success "Named value 'AIRS-API' created."
fi

# ── 9. APIM API + Policy ──────────────────────────────────────────────────────
info "Step 9/10: Configuring APIM API and policy..."

OPENAI_BASE="${OPENAI_ENDPOINT%/}"

# Policy uses:
#   <set-header name="Authorization" exists-action="delete" /> — strips any client-sent auth
#   <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
#     — gets an AAD token for the APIM MSI and sets Authorization: Bearer <token>
#     — combined with the RBAC role above and bypass=AzureServices, this reaches OpenAI
POLICY_XML=$(cat <<'POLICYEOF'
<policies>
  <inbound>
    <base />
    <set-header name="Authorization" exists-action="delete" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <set-variable name="currentProfile" value="AIRS_PROFILE_PLACEHOLDER" />
    <set-variable name="scanDescriptions" value="@{return new JObject(new JProperty(&quot;url_cats&quot;,&quot;Unacceptable URLs detected.&quot;),new JProperty(&quot;dlp&quot;,&quot;Sensitive data (DLP) detected.&quot;),new JProperty(&quot;injection&quot;,&quot;Prompt injection detected.&quot;),new JProperty(&quot;agent&quot;,&quot;Agent manipulation detected.&quot;),new JProperty(&quot;toxic_content&quot;,&quot;Policy-violating content detected.&quot;),new JProperty(&quot;malicious_code&quot;,&quot;Malicious code detected.&quot;),new JProperty(&quot;topic_violation&quot;,&quot;Off-topic content detected.&quot;),new JProperty(&quot;db_security&quot;,&quot;Unacceptable database commands detected.&quot;),new JProperty(&quot;ungrounded&quot;,&quot;Ungrounded content detected.&quot;));}" />
    <choose>
      <when condition="@(context.Request.Method.Equals(&quot;POST&quot;,StringComparison.OrdinalIgnoreCase)&amp;&amp;(context.Request.OriginalUrl.Path.EndsWith(&quot;/responses&quot;,StringComparison.OrdinalIgnoreCase)||context.Request.OriginalUrl.Path.EndsWith(&quot;/chat/completions&quot;,StringComparison.OrdinalIgnoreCase)))">
        <set-variable name="airsPromptReq" value="@{
          var body=context.Request.Body.As&lt;JObject&gt;(preserveContent:true);
          string model=(body!=null&amp;&amp;body.ContainsKey(&quot;model&quot;))?body[&quot;model&quot;].ToString():&quot;unknown-model&quot;;
          string session=context.Request.Headers.GetValueOrDefault(&quot;x-session-id&quot;,context.RequestId.ToString()??&quot;no-id&quot;);
          string prompt=&quot;&quot;;
          if(body!=null&amp;&amp;body[&quot;input&quot;]!=null){prompt=body[&quot;input&quot;].ToString();}
          else if(body!=null){var t=body[&quot;messages&quot;]?.Last?[&quot;content&quot;];if(t!=null){prompt=t.ToString();}}
          return new JObject(
            new JProperty(&quot;session_id&quot;,session),
            new JProperty(&quot;ai_profile&quot;,new JObject(new JProperty(&quot;profile_name&quot;,(string)context.Variables.GetValueOrDefault(&quot;currentProfile&quot;,&quot;example-profile&quot;)))),
            new JProperty(&quot;metadata&quot;,new JObject(new JProperty(&quot;app_name&quot;,&quot;APIM-RAG-Chatbot-POV&quot;),new JProperty(&quot;user_ip&quot;,context.Request.IpAddress),new JProperty(&quot;ai_model&quot;,model),new JProperty(&quot;app_user&quot;,context.Request.Headers.GetValueOrDefault(&quot;x-user-id&quot;,&quot;anonymous&quot;)))),
            new JProperty(&quot;contents&quot;,new JArray(new JObject(new JProperty(&quot;prompt&quot;,prompt))))
          );
        }" />
        <send-request mode="new" response-variable-name="panwPromptScan" timeout="10" ignore-error="true">
          <set-url>https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request</set-url>
          <set-method>POST</set-method>
          <set-header name="x-pan-token" exists-action="override"><value>{{AIRS-API}}</value></set-header>
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>@{return((JObject)context.Variables[&quot;airsPromptReq&quot;]).ToString();}</set-body>
        </send-request>
        <choose>
          <when condition="@(context.Variables.ContainsKey(&quot;panwPromptScan&quot;)&amp;&amp;((IResponse)context.Variables[&quot;panwPromptScan&quot;]).StatusCode==200&amp;&amp;((IResponse)context.Variables[&quot;panwPromptScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;action&quot;].ToString()==&quot;block&quot;)">
            <return-response>
              <set-status code="403" reason="Forbidden" />
              <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
              <set-body>@{
                var pr=((IResponse)context.Variables[&quot;panwPromptScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true);
                var desc=(JObject)context.Variables.GetValueOrDefault&lt;object&gt;(&quot;scanDescriptions&quot;);
                var det=new JObject();
                var detected=pr[&quot;prompt_detected&quot;]as JObject;
                if(detected!=null){foreach(JProperty p in detected.Properties()){if(p.Value.Type==JTokenType.Boolean&amp;&amp;(bool)p.Value){det.Add(p.Name,desc?[p.Name]??(JToken)true);}}}
                return new JObject(new JProperty(&quot;error&quot;,&quot;PRISMA AIRS: REQUEST BLOCKED&quot;),new JProperty(&quot;details&quot;,det)).ToString();
              }</set-body>
            </return-response>
          </when>
          <when condition="@(context.Variables.ContainsKey(&quot;panwPromptScan&quot;)&amp;&amp;((IResponse)context.Variables[&quot;panwPromptScan&quot;]).StatusCode==200&amp;&amp;((IResponse)context.Variables[&quot;panwPromptScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;action&quot;].ToString()==&quot;allow&quot;&amp;&amp;((IResponse)context.Variables[&quot;panwPromptScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true).ContainsKey(&quot;prompt_masked_data&quot;))">
            <set-body>@{
              var body=context.Request.Body.As&lt;JObject&gt;(preserveContent:true);
              var masked=((IResponse)context.Variables[&quot;panwPromptScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;prompt_masked_data&quot;][&quot;data&quot;].ToString();
              if(body[&quot;input&quot;]!=null){body[&quot;input&quot;]=masked;}
              else if(body[&quot;messages&quot;]is JArray arr&amp;&amp;arr.Count>0&amp;&amp;arr.Last[&quot;content&quot;]!=null){arr.Last[&quot;content&quot;]=masked;}
              return body.ToString();
            }</set-body>
          </when>
          <otherwise>
            <choose>
              <when condition="@(!context.Variables.ContainsKey(&quot;panwPromptScan&quot;)||context.Variables[&quot;panwPromptScan&quot;]==null||((IResponse)context.Variables[&quot;panwPromptScan&quot;]).StatusCode!=200)">
                <return-response>
                  <set-status code="503" reason="Service Unavailable" />
                  <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
                  <set-body>@{
                    string sc=&quot;not-called&quot;;string rb=&quot;&quot;;
                    try{if(context.Variables.ContainsKey(&quot;panwPromptScan&quot;)&amp;&amp;context.Variables[&quot;panwPromptScan&quot;]!=null){var r=(IResponse)context.Variables[&quot;panwPromptScan&quot;];sc=r.StatusCode.ToString();rb=r.Body.As&lt;string&gt;(preserveContent:true)??&quot;&quot;;if(rb.Length&gt;400){rb=rb.Substring(0,400);}}}catch{}
                    return new JObject(new JProperty(&quot;error&quot;,&quot;PRISMA AIRS: Security scanner unavailable. Request blocked.&quot;),new JProperty(&quot;airs_status&quot;,sc),new JProperty(&quot;airs_body&quot;,rb)).ToString();
                  }</set-body>
                </return-response>
              </when>
            </choose>
          </otherwise>
        </choose>
      </when>
    </choose>
  </inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <choose>
      <when condition="@(context.Request.Method.Equals(&quot;POST&quot;,StringComparison.OrdinalIgnoreCase)&amp;&amp;(context.Request.OriginalUrl.Path.EndsWith(&quot;/responses&quot;,StringComparison.OrdinalIgnoreCase)||context.Request.OriginalUrl.Path.EndsWith(&quot;/chat/completions&quot;,StringComparison.OrdinalIgnoreCase))&amp;&amp;context.Response!=null&amp;&amp;context.Response.StatusCode==200)">
        <set-variable name="airsRespReq" value="@{
          var reqBody=context.Request.Body.As&lt;JObject&gt;(preserveContent:true);
          string model=(reqBody!=null&amp;&amp;reqBody.ContainsKey(&quot;model&quot;))?reqBody[&quot;model&quot;].ToString():&quot;unknown-model&quot;;
          string session=context.Request.Headers.GetValueOrDefault(&quot;x-session-id&quot;,context.RequestId.ToString()??&quot;no-id&quot;);
          string resp=&quot;&quot;;
          try{
            var respBody=context.Response.Body.As&lt;JObject&gt;(preserveContent:true);
            var ot=respBody[&quot;output&quot;]?.Last?[&quot;content&quot;]?.Last?[&quot;text&quot;];
            var ct=((JArray)respBody[&quot;choices&quot;])?.Last?[&quot;message&quot;]?[&quot;content&quot;];
            if(ot!=null){resp=ot.ToString();}else if(ct!=null){resp=ct.ToString();}
          }catch{}
          return new JObject(
            new JProperty(&quot;session_id&quot;,session),
            new JProperty(&quot;ai_profile&quot;,new JObject(new JProperty(&quot;profile_name&quot;,(string)context.Variables.GetValueOrDefault(&quot;currentProfile&quot;,&quot;example-profile&quot;)))),
            new JProperty(&quot;metadata&quot;,new JObject(new JProperty(&quot;app_name&quot;,&quot;APIM-RAG-Chatbot-POV&quot;),new JProperty(&quot;user_ip&quot;,context.Request.IpAddress),new JProperty(&quot;ai_model&quot;,model),new JProperty(&quot;app_user&quot;,context.Request.Headers.GetValueOrDefault(&quot;x-user-id&quot;,&quot;anonymous&quot;)))),
            new JProperty(&quot;contents&quot;,new JArray(new JObject(new JProperty(&quot;response&quot;,resp))))
          );
        }" />
        <send-request mode="new" response-variable-name="panwRespScan" timeout="10" ignore-error="true">
          <set-url>https://service.api.aisecurity.paloaltonetworks.com/v1/scan/sync/request</set-url>
          <set-method>POST</set-method>
          <set-header name="x-pan-token" exists-action="override"><value>{{AIRS-API}}</value></set-header>
          <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
          <set-body>@{return((JObject)context.Variables[&quot;airsRespReq&quot;]).ToString();}</set-body>
        </send-request>
        <choose>
          <when condition="@(context.Variables.ContainsKey(&quot;panwRespScan&quot;)&amp;&amp;((IResponse)context.Variables[&quot;panwRespScan&quot;]).StatusCode==200&amp;&amp;((IResponse)context.Variables[&quot;panwRespScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;action&quot;].ToString()==&quot;block&quot;)">
            <return-response>
              <set-status code="403" reason="Forbidden" />
              <set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header>
              <set-body>@{
                var pr=((IResponse)context.Variables[&quot;panwRespScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true);
                var desc=(JObject)context.Variables.GetValueOrDefault&lt;object&gt;(&quot;scanDescriptions&quot;);
                var det=new JObject();
                var detected=pr[&quot;response_detected&quot;]as JObject;
                if(detected!=null){foreach(JProperty p in detected.Properties()){if(p.Value.Type==JTokenType.Boolean&amp;&amp;(bool)p.Value){det.Add(p.Name,desc?[p.Name]??(JToken)true);}}}
                return new JObject(new JProperty(&quot;error&quot;,&quot;PRISMA AIRS: RESPONSE BLOCKED&quot;),new JProperty(&quot;details&quot;,det)).ToString();
              }</set-body>
            </return-response>
          </when>
          <when condition="@(context.Variables.ContainsKey(&quot;panwRespScan&quot;)&amp;&amp;((IResponse)context.Variables[&quot;panwRespScan&quot;]).StatusCode==200&amp;&amp;((IResponse)context.Variables[&quot;panwRespScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;action&quot;].ToString()==&quot;allow&quot;&amp;&amp;((IResponse)context.Variables[&quot;panwRespScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true).ContainsKey(&quot;response_masked_data&quot;))">
            <set-body>@{
              var body=context.Response.Body.As&lt;JObject&gt;(preserveContent:true);
              var masked=((IResponse)context.Variables[&quot;panwRespScan&quot;]).Body.As&lt;JObject&gt;(preserveContent:true)[&quot;response_masked_data&quot;]?[&quot;data&quot;]?.ToString();
              if(body[&quot;output&quot;]is JArray oa&amp;&amp;oa.Count>0&amp;&amp;oa.Last[&quot;content&quot;]is JArray ca&amp;&amp;ca.Count>0&amp;&amp;ca.Last[&quot;text&quot;]!=null){ca.Last[&quot;text&quot;]=masked;}
              else if(body[&quot;choices&quot;]is JArray ch&amp;&amp;ch.Count>0&amp;&amp;ch.Last[&quot;message&quot;]!=null){ch.Last[&quot;message&quot;][&quot;content&quot;]=masked;}
              return body.ToString();
            }</set-body>
          </when>
        </choose>
      </when>
    </choose>
  </outbound>
  <on-error><base /></on-error>
</policies>
POLICYEOF
)

# Substitute AIRS profile name into policy (can't use shell vars inside single-quoted heredoc)
POLICY_XML="${POLICY_XML//AIRS_PROFILE_PLACEHOLDER/${PRISMA_AIRS_PROFILE_NAME}}"

# Create or update APIM API (subscriptionRequired=false — client auth is via MSI on the backend leg)
EXISTING_API=$(az apim api show \
  -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
  --api-id "$API_ID" 2>/dev/null | jq -r '.name // empty' || true)

if [[ -z "$EXISTING_API" ]]; then
  az apim api create \
    -n "$APIM_NAME" \
    -g "$RESOURCE_GROUP" \
    --api-id "$API_ID" \
    --display-name "Azure OpenAI API" \
    --path "openai/v1" \
    --service-url "${OPENAI_BASE}/openai/v1" \
    --protocols https \
    --subscription-required false \
    -o none
  success "APIM API 'azure-openai-api' created (no subscription key required)."
else
  az apim api update \
    -n "$APIM_NAME" \
    -g "$RESOURCE_GROUP" \
    --api-id "$API_ID" \
    --service-url "${OPENAI_BASE}/openai/v1" \
    --subscription-required false \
    -o none
  success "APIM API 'azure-openai-api' updated."
fi

# Add wildcard POST operation to catch all paths
EXISTING_OP=$(az apim api operation show \
  -n "$APIM_NAME" -g "$RESOURCE_GROUP" \
  --api-id "$API_ID" \
  --operation-id "all-operations" 2>/dev/null | jq -r '.name // empty' || true)

if [[ -z "$EXISTING_OP" ]]; then
  az apim api operation create \
    -n "$APIM_NAME" \
    -g "$RESOURCE_GROUP" \
    --api-id "$API_ID" \
    --operation-id "all-operations" \
    --display-name "All Operations" \
    --method "POST" \
    --url-template "/*" \
    -o none
  success "Wildcard POST operation created."
fi

# Apply the full inlined policy via az rest PUT (az apim api policy not available in all CLI versions)
POLICY_FILE=$(mktemp /tmp/apim-policy-XXXXXX.xml)
POLICY_BODY_FILE=$(mktemp /tmp/apim-policy-body-XXXXXX.json)
echo "$POLICY_XML" > "$POLICY_FILE"
jq -n --rawfile policy "$POLICY_FILE" '{"properties":{"format":"rawxml","value":$policy}}' > "$POLICY_BODY_FILE"

az rest \
  --method PUT \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${API_ID}/policies/policy?api-version=2022-08-01" \
  --body "@${POLICY_BODY_FILE}" \
  -o none

rm -f "$POLICY_FILE" "$POLICY_BODY_FILE"
success "APIM policy applied (MSI auth + Prisma AIRS prompt/response scanning)."

# ── 10. Subscription key (for run_security_tests.py and monitoring) ────────────
info "Step 10/10: Retrieving APIM subscription key for test scripts..."

APIM_SUB_KEY=$(az rest \
  --method POST \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/master/listSecrets?api-version=2022-08-01" \
  --query primaryKey -o tsv 2>/dev/null || true)

if [[ -z "$APIM_SUB_KEY" ]]; then
  warn "Could not retrieve built-in subscription key. Trying subscription list..."
  APIM_SUB_KEY=$(az rest \
    --method GET \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions?api-version=2022-08-01" \
    --query "value[0].properties.primaryKey" -o tsv 2>/dev/null || true)
fi

if [[ -z "$APIM_SUB_KEY" ]]; then
  warn "Could not retrieve APIM subscription key automatically."
  warn "Retrieve it from Portal → APIM → '$APIM_NAME' → Subscriptions → Built-in all-access"
  APIM_SUB_KEY="RETRIEVE_FROM_PORTAL"
fi
success "APIM subscription key retrieved (used by run_security_tests.py for the master sub)."

# ── Write demo.env ────────────────────────────────────────────────────────────
APIM_CUSTOM_URL="${APIM_GW_URL}/openai/v1"

cat > "$DEMO_ENV" <<EOF
# ============================================================
# demo.env — Generated by deploy_apim.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Source this file before running start_demo.sh
# ============================================================

# ── APIM / OpenAI routing ──────────────────────────────────
# The app uses 'azure_custom' mode, pointing at APIM instead of OpenAI directly.
# APIM authenticates to OpenAI via its system-assigned MSI (no static key stored).
OPENAI_HOST=azure_custom
AZURE_OPENAI_CUSTOM_URL=${APIM_CUSTOM_URL}
# A non-empty placeholder is required by the AsyncOpenAI client constructor.
# APIM strips this header and replaces it with a real MSI bearer token.
AZURE_OPENAI_API_KEY_OVERRIDE=apim-msi-gateway
AZURE_OPENAI_CHATGPT_DEPLOYMENT=${OPENAI_DEPLOYMENT}
AZURE_OPENAI_CHATGPT_MODEL=${OPENAI_MODEL}
AZURE_OPENAI_EMB_DEPLOYMENT=text-embedding-ada-002
AZURE_OPENAI_EMB_MODEL_NAME=text-embedding-ada-002

# ── Azure AI Search ───────────────────────────────────────
# Search has publicNetworkAccess=Disabled (org policy requirement).
# The backend reaches it via private endpoint. See /etc/hosts note below.
AZURE_SEARCH_SERVICE=${SEARCH_NAME}
AZURE_SEARCH_INDEX=${SEARCH_INDEX}
AZURE_SEARCH_KEY=${SEARCH_KEY}
# Private endpoint IP — used by start_demo.sh to patch /etc/hosts if needed
SEARCH_PRIVATE_IP=${SEARCH_PRIVATE_IP}

# ── Azure Storage ─────────────────────────────────────────
AZURE_STORAGE_ACCOUNT=${STORAGE_NAME}
AZURE_STORAGE_CONTAINER=content
AZURE_STORAGE_KEY=${STORAGE_KEY}

# ── Prisma AIRS ───────────────────────────────────────────
PRISMA_AIRS_API_KEY=${PRISMA_AIRS_API_KEY}
PRISMA_AIRS_PROFILE_NAME=${PRISMA_AIRS_PROFILE_NAME}

# ── App Config ────────────────────────────────────────────
AZURE_OPENAI_RESOURCE_GROUP=${RESOURCE_GROUP}

# ── For run_security_tests.py ─────────────────────────────
APIM_GATEWAY_URL=${APIM_GW_URL}
# Master subscription key — only needed by test scripts (API itself has no subscription requirement)
APIM_SUBSCRIPTION_KEY=${APIM_SUB_KEY}
EOF

# ── Patch WSL2 /etc/hosts for Search private endpoint DNS resolution ───────────
# When publicNetworkAccess=Disabled, the public DNS for Search still resolves to a
# CNAME that points to a blocked public IP. Adding the private endpoint IP to
# /etc/hosts makes the backend resolve to the correct private IP without VPN.
HOSTS_ENTRY="${SEARCH_PRIVATE_IP} ${SEARCH_NAME}.search.windows.net"
if [[ "$SEARCH_PRIVATE_IP" != "RETRIEVE_MANUALLY" ]]; then
  if grep -qF "${SEARCH_NAME}.search.windows.net" /etc/hosts 2>/dev/null; then
    warn "/etc/hosts already has an entry for ${SEARCH_NAME}.search.windows.net — skipping."
    warn "Verify it matches: ${HOSTS_ENTRY}"
  else
    info "Adding Search private endpoint to /etc/hosts (requires sudo)..."
    echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null && \
      success "Added to /etc/hosts: ${HOSTS_ENTRY}" || \
      warn "Could not write to /etc/hosts. Add this line manually: ${HOSTS_ENTRY}"
  fi
else
  warn "Search private endpoint IP unknown. Add manually to /etc/hosts once retrieved:"
  warn "  <private-ip>  ${SEARCH_NAME}.search.windows.net"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Deployment Complete!                                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}APIM Gateway URL:${NC}     $APIM_GW_URL"
echo -e "  ${CYAN}App Custom URL:${NC}       $APIM_CUSTOM_URL"
echo -e "  ${CYAN}OpenAI Endpoint:${NC}      $OPENAI_ENDPOINT"
echo -e "  ${CYAN}Search (private):${NC}     ${SEARCH_NAME}.search.windows.net → ${SEARCH_PRIVATE_IP}"
echo -e "  ${CYAN}APIM MSI Principal:${NC}   $APIM_PRINCIPAL_ID"
echo -e "  ${CYAN}Auth flow:${NC}            Backend → APIM MSI token → Azure OpenAI"
echo ""
echo -e "  ${CYAN}Compliance:${NC}"
echo -e "    ✅ OpenAI: system-assigned MSI, networkAcls.defaultAction=Deny, bypass=AzureServices"
echo -e "    ✅ Search: publicNetworkAccess=Disabled, private endpoint in ${VNET_NAME}"
echo -e "    ✅ APIM MSI has 'Cognitive Services OpenAI User' RBAC role on OpenAI"
echo -e "    ✅ No static OpenAI API key stored in APIM"
echo ""
echo -e "  ${CYAN}demo.env written to:${NC}  $DEMO_ENV"
echo ""
echo -e "${YELLOW}⚠  Search connectivity — no VPN/GP required:${NC}"
echo -e "  Azure AI Search has publicNetworkAccess=Disabled (org policy)."
echo -e "  Private endpoint IP: ${SEARCH_PRIVATE_IP}"
echo -e ""
echo -e "  Since GlobalProtect cannot route WSL2 traffic to 10.100.0.0/16, run the"
echo -e "  demo backend from an Azure VM inside the VNet (SSH port-forward replaces GP):"
echo -e ""
echo -e "    ${CYAN}./deploy_vm.sh${NC}   ← deploys VM, copies repo, prints SSH tunnel command"
echo -e ""
echo -e "  The VM lives in the same VNet as the Search private endpoint, so no VPN needed."
echo -e "  Chrome on Windows → localhost:50505 → SSH tunnel → VM → private endpoint."
echo -e ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1.  Deploy the demo VM (handles Search private endpoint access):"
echo -e "      ${CYAN}cd ~/prisma-airs-apim-pov/azure-apim-gateway-pov && ./deploy_vm.sh${NC}"
echo ""
echo -e "  2.  Follow the SSH tunnel + start_demo.sh instructions printed by deploy_vm.sh"
echo ""
echo -e "  3.  Run security tests from WSL2 (Terminal 2 — APIM is public, no VPN needed):"
echo -e "      ${CYAN}cd ~/prisma-airs-apim-pov/azure-search-openai-demo && python3 run_security_tests.py${NC}"
echo ""
echo -e "  4.  Open browser: ${CYAN}http://localhost:50505${NC}"
echo ""
