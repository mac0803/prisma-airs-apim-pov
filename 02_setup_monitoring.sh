#!/usr/bin/env bash
# =============================================================================
# 02_setup_monitoring.sh — Step 2: Wire APIM to Log Analytics
#
# Sets up:
#   - Log Analytics workspace
#   - APIM diagnostic settings → GatewayLogs + GatewayLlmLogs
#   - APIM azureMonitor logger + API-level diagnostics (100% sampling)
#   - Operation-level policy to emit x-tokens-consumed response header
#   - Updates azure-apim-gateway-pov/demo.env with LAW workspace IDs
#   - Prints portal deep-links + KQL query cheat sheet
#
# Prerequisites:
#   Run 01_deploy_infra.sh first (demo.env must exist).
#
# Usage:
#   ./02_setup_monitoring.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${REPO_ROOT}/azure-apim-gateway-pov/setup_monitoring.sh"
DEMO_ENV="${REPO_ROOT}/azure-apim-gateway-pov/demo.env"

RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Step 2/4 — Set Up Monitoring (Log Analytics)               ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ -f "$SCRIPT" ]]   || die "setup_monitoring.sh not found at $SCRIPT"
[[ -f "$DEMO_ENV" ]] || die "demo.env not found at $DEMO_ENV — run 01_deploy_infra.sh first."

az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"

info "Delegating to azure-apim-gateway-pov/setup_monitoring.sh ..."
echo ""
exec bash "$SCRIPT" "$@"
