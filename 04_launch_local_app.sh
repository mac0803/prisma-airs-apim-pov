#!/usr/bin/env bash
# =============================================================================
# 04_launch_local_app.sh — Step 4: Launch the RAG chatbot demo app locally
#
# Starts the Azure OpenAI RAG chatbot (azure-search-openai-demo) configured
# to route all LLM calls through APIM → Prisma AIRS.
#
# What it does:
#   - Loads azure-apim-gateway-pov/demo.env
#   - Creates a Python venv + installs backend requirements (first run only)
#   - Builds the React frontend (first run only)
#   - Starts the Quart backend on 0.0.0.0:50505
#
# Security flow (when OPENAI_HOST=azure_custom):
#   Browser → Backend (Python/Quart) → APIM Gateway → Prisma AIRS → Azure OpenAI
#   Blocked prompts return HTTP 403 → app shows PRISMA AIRS SECURITY ALERT shield
#
# Access:
#   Windows Chrome:  http://localhost:50505
#
# Prerequisites:
#   Run 01_deploy_infra.sh first (demo.env must exist).
#   Requires: python3, node, npm, az CLI (logged in)
#
# Usage:
#   ./04_launch_local_app.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${REPO_ROOT}/azure-search-openai-demo/start_demo.sh"
DEMO_ENV="${REPO_ROOT}/azure-apim-gateway-pov/demo.env"

RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Step 4/4 — Launch RAG Chatbot Demo App                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ -f "$SCRIPT" ]]   || die "start_demo.sh not found at $SCRIPT"
[[ -f "$DEMO_ENV" ]] || die "demo.env not found at $DEMO_ENV — run 01_deploy_infra.sh first."

info "Delegating to azure-search-openai-demo/start_demo.sh ..."
echo ""
exec bash "$SCRIPT"
