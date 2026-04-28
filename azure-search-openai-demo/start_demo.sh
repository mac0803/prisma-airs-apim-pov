#!/usr/bin/env bash
# =============================================================================
# start_demo.sh — Start the RAG chatbot demo with Prisma AIRS + APIM
#
# Run from: ~/prisma-airs-apim-pov/azure-search-openai-demo/
# Browser:  http://localhost:50505  (accessible from Windows Chrome)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV="${SCRIPT_DIR}/../azure-apim-gateway-pov/demo.env"
APP_DIR="${SCRIPT_DIR}/app"
BACKEND_DIR="${APP_DIR}/backend"
FRONTEND_DIR="${APP_DIR}/frontend"
VENV_DIR="${SCRIPT_DIR}/.venv"
PORT=50505

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Prisma AIRS × Azure APIM — RAG Chatbot Demo                ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Load environment ──────────────────────────────────────────────────────────
if [[ -f "$DEMO_ENV" ]]; then
  echo -e "${GREEN}[OK]${NC}   Loading $DEMO_ENV"
  # shellcheck disable=SC1090
  set -a; source "$DEMO_ENV"; set +a
else
  echo -e "${YELLOW}[WARN]${NC} demo.env not found at $DEMO_ENV"
  echo -e "       Run ${CYAN}../azure-apim-gateway-pov/deploy_apim.sh${NC} first, or set vars manually."
  if [[ -z "${OPENAI_HOST:-}" ]]; then
    echo -e "${RED}[FAIL]${NC} OPENAI_HOST is not set. Cannot continue."
    exit 1
  fi
fi

# RUNNING_IN_PRODUCTION skips load_azd_env() in main.py (azd is not installed).
# USE_AZ_CLI_CREDENTIAL overrides the credential to use 'az login' instead of
# ManagedIdentityCredential (which doesn't work on WSL2).
export RUNNING_IN_PRODUCTION=true
export USE_AZ_CLI_CREDENTIAL=true

# Validate critical variables
MISSING=()
[[ -z "${OPENAI_HOST:-}" ]]                && MISSING+=("OPENAI_HOST")
[[ -z "${AZURE_OPENAI_CUSTOM_URL:-}" ]] \
  && [[ "${OPENAI_HOST:-}" == "azure_custom" ]] && MISSING+=("AZURE_OPENAI_CUSTOM_URL")
[[ -z "${AZURE_OPENAI_SERVICE:-}" ]] \
  && [[ "${OPENAI_HOST:-}" == "azure" ]]        && MISSING+=("AZURE_OPENAI_SERVICE")
# AZURE_SEARCH_SERVICE is optional — when blank, backend uses DirectChatApproach (no RAG)

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo -e "${RED}[FAIL]${NC} Missing required environment variables:"
  for v in "${MISSING[@]}"; do echo "         - $v"; done
  exit 1
fi

echo -e "${GREEN}[OK]${NC}   OPENAI_HOST              = $OPENAI_HOST"
if [[ "${OPENAI_HOST:-}" == "azure_custom" ]]; then
  echo -e "${GREEN}[OK]${NC}   AZURE_OPENAI_CUSTOM_URL  = ${AZURE_OPENAI_CUSTOM_URL:-N/A}"
else
  echo -e "${GREEN}[OK]${NC}   AZURE_OPENAI_SERVICE     = ${AZURE_OPENAI_SERVICE:-N/A}"
fi
if [[ -n "${AZURE_SEARCH_SERVICE:-}" ]]; then
  echo -e "${GREEN}[OK]${NC}   AZURE_SEARCH_SERVICE     = $AZURE_SEARCH_SERVICE (RAG mode)"
else
  echo -e "${YELLOW}[INFO]${NC} AZURE_SEARCH_SERVICE     = (not set) — DirectChat mode, no RAG"
fi
echo ""

# ── Azure CLI auth check + auto-refresh OpenAI IP allowlist ──────────────────
# The OpenAI resource has networkAcls.defaultAction=Deny (org policy). This machine's
# public IP must be in the allowlist. Corporate NAT IPs rotate — we add the current
# IP on every start to stay connected.
if az account show >/dev/null 2>&1; then
  echo -e "${GREEN}[OK]${NC}   az CLI session active"
  if [[ "${OPENAI_HOST:-}" == "azure" && -n "${AZURE_OPENAI_SERVICE:-}" ]]; then
    CURRENT_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    if [[ -n "$CURRENT_IP" ]]; then
      OAI_RESOURCE_ID="/subscriptions/${AZURE_SUBSCRIPTION_ID:-5c144ab1-83b1-41eb-8683-16d499db8c27}/resourceGroups/${AZURE_OPENAI_RESOURCE_GROUP:-rg-airs-apim-pov}/providers/Microsoft.CognitiveServices/accounts/${AZURE_OPENAI_SERVICE}"
      EXISTING=$(az rest --method GET \
        --url "https://management.azure.com${OAI_RESOURCE_ID}?api-version=2024-04-01-preview" \
        --query "properties.networkAcls.ipRules[].value" -o tsv 2>/dev/null || echo "")
      if echo "$EXISTING" | grep -qF "$CURRENT_IP"; then
        echo -e "${GREEN}[OK]${NC}   OpenAI allowlist has current IP ($CURRENT_IP)"
      else
        echo -e "${YELLOW}[WARN]${NC} Adding current IP ($CURRENT_IP) to OpenAI allowlist..."
        # Build new ipRules array preserving existing IPs
        NEW_IPS=$(echo "$EXISTING" | python3 -c "
import json,sys
existing = [l.strip() for l in sys.stdin if l.strip()]
new_ip = '${CURRENT_IP}'
if new_ip not in existing:
    existing.append(new_ip)
# keep at most 20 IPs (Azure limit)
existing = existing[-20:]
print(json.dumps([{'value': ip} for ip in existing]))
")
        az rest --method PATCH \
          --url "https://management.azure.com${OAI_RESOURCE_ID}?api-version=2024-04-01-preview" \
          --headers "Content-Type=application/json" \
          --body "{\"properties\":{\"networkAcls\":{\"defaultAction\":\"Deny\",\"bypass\":\"AzureServices\",\"ipRules\":${NEW_IPS}}}}" \
          -o none 2>/dev/null && \
          echo -e "${GREEN}[OK]${NC}   OpenAI allowlist updated (IP: $CURRENT_IP)" || \
          echo -e "${YELLOW}[WARN]${NC} Could not update allowlist — check az login"
      fi
    fi
  fi
else
  echo -e "${RED}[FAIL]${NC} az CLI not logged in. Run: az login --tenant 66b66353-3b76-4e41-9dc3-fee328bd400e"
  exit 1
fi
echo ""

# ── Re-apply /etc/hosts entry for Search private endpoint ────────────────────
# WSL2 regenerates /etc/hosts on every restart, so we re-apply on each launch.
# This is required when Azure AI Search has publicNetworkAccess=Disabled (org policy).
if [[ -n "${SEARCH_PRIVATE_IP:-}" && "$SEARCH_PRIVATE_IP" != "RETRIEVE_MANUALLY" ]]; then
  HOSTS_ENTRY="${SEARCH_PRIVATE_IP} ${AZURE_SEARCH_SERVICE}.search.windows.net"
  if ! grep -qF "${AZURE_SEARCH_SERVICE}.search.windows.net" /etc/hosts 2>/dev/null; then
    echo -e "${YELLOW}[WARN]${NC} Search private endpoint not in /etc/hosts — adding (requires sudo)..."
    echo "$HOSTS_ENTRY" | sudo tee -a /etc/hosts > /dev/null && \
      echo -e "${GREEN}[OK]${NC}   Added: ${HOSTS_ENTRY}" || \
      echo -e "${YELLOW}[WARN]${NC} Could not write /etc/hosts. Add manually: ${HOSTS_ENTRY}"
  else
    echo -e "${GREEN}[OK]${NC}   /etc/hosts has Search private endpoint (${SEARCH_PRIVATE_IP})"
  fi
fi
echo ""

# ── Python venv ───────────────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
  echo -e "${CYAN}[INFO]${NC} Creating Python virtual environment..."
  python3 -m venv "$VENV_DIR"
fi

echo -e "${CYAN}[INFO]${NC} Installing backend dependencies..."
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -r "$BACKEND_DIR/requirements.txt"
echo -e "${GREEN}[OK]${NC}   Backend dependencies installed."

# ── Frontend build ────────────────────────────────────────────────────────────
if [[ ! -d "$FRONTEND_DIR/node_modules" ]]; then
  echo -e "${CYAN}[INFO]${NC} Installing frontend npm packages..."
  (cd "$FRONTEND_DIR" && npm install --silent)
fi

if [[ ! -d "$FRONTEND_DIR/dist" ]] || \
   [[ "$FRONTEND_DIR/src" -nt "$FRONTEND_DIR/dist" ]]; then
  echo -e "${CYAN}[INFO]${NC} Building frontend..."
  (cd "$FRONTEND_DIR" && npm run build --silent)
  echo -e "${GREEN}[OK]${NC}   Frontend built."
else
  echo -e "${GREEN}[OK]${NC}   Frontend already built (skipping rebuild)."
fi

# ── Get Windows host IP for display purposes ──────────────────────────────────
WSL_HOST_IP=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1 || echo "")

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  Starting backend on 0.0.0.0:${PORT}                           ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Open in ${BOLD}Windows Chrome${NC}: ${CYAN}http://localhost:${PORT}${NC}"
if [[ -n "$WSL_HOST_IP" ]]; then
  echo -e "  Or via WSL IP:         ${CYAN}http://${WSL_HOST_IP}:${PORT}${NC}"
fi
echo ""
echo -e "  ${YELLOW}Security flow:${NC}"
if [[ "${OPENAI_HOST:-}" == "azure_custom" ]]; then
  echo -e "    Browser → Backend → ${CYAN}APIM Gateway${NC} → ${RED}Prisma AIRS Scan${NC} → Azure OpenAI"
  echo -e "    Blocked prompts return a ${RED}403 PRISMA AIRS SECURITY ALERT${NC}"
else
  echo -e "    Browser → Backend → Azure OpenAI (direct, IP allowlisted)"
  echo -e "    ${RED}Prisma AIRS scanning${NC}: open Terminal 2 → python3 run_security_tests.py"
fi
echo ""
echo -e "  Press ${BOLD}Ctrl+C${NC} to stop."
echo ""

# ── Launch backend (bound to 0.0.0.0 so Windows Chrome can reach it) ─────────
cd "$BACKEND_DIR"
exec "$VENV_DIR/bin/python" -m quart --app main:app run \
  --port "$PORT" \
  --host "0.0.0.0"
