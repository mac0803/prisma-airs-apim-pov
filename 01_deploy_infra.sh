#!/usr/bin/env bash
# =============================================================================
# 01_deploy_infra.sh — Step 1: Deploy Azure infrastructure
#
# Deploys:
#   - Azure OpenAI (gpt-4o, system-assigned MSI, network ACLs)
#   - Azure APIM Standard v2 with Prisma AIRS inbound/outbound policy
#   - Azure AI Search (publicNetworkAccess=Disabled, private endpoint)
#   - Azure Storage (defaultAction=Deny + IP allowlist)
#   - APIM Named Value for AIRS API key (stored as secret)
#   - RBAC: APIM MSI → Cognitive Services OpenAI User
#
# Prerequisites:
#   az login  (run once — interactive browser auth)
#   export PRISMA_AIRS_API_KEY="<your-key>"
#   export PRISMA_AIRS_PROFILE_NAME="<your-profile>"
#
# Outputs:
#   azure-apim-gateway-pov/demo.env  (source before running step 4)
#
# Usage:
#   ./01_deploy_infra.sh [--rg <resource-group>] [--location <region>] [--prefix <prefix>]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${REPO_ROOT}/azure-apim-gateway-pov/deploy_apim.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
die()   { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Step 1/4 — Deploy Azure Infrastructure                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ -f "$SCRIPT" ]] || die "deploy_apim.sh not found at $SCRIPT"

[[ -z "${PRISMA_AIRS_API_KEY:-}" ]]      && die "PRISMA_AIRS_API_KEY is not set. Export it first."
[[ -z "${PRISMA_AIRS_PROFILE_NAME:-}" ]] && die "PRISMA_AIRS_PROFILE_NAME is not set. Export it first."

az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

info "Delegating to azure-apim-gateway-pov/deploy_apim.sh ..."
echo ""
exec bash "$SCRIPT" "$@"
