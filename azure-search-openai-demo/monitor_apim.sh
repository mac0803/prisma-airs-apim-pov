#!/usr/bin/env bash
# =============================================================================
# monitor_apim.sh — Live APIM Gateway dashboard for the Prisma AIRS POV demo
#
# Run in Terminal 3 while the chatbot (Terminal 1) and security tests
# (Terminal 2) are running.  Auto-refreshes every 20 seconds.
#
# Requires: az CLI logged in, setup_monitoring.sh already run once.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV="${SCRIPT_DIR}/../azure-apim-gateway-pov/demo.env"
REFRESH_SECS=20

# ── Load demo.env ──────────────────────────────────────────────────────────────
[[ -f "$DEMO_ENV" ]] || { echo "demo.env not found at $DEMO_ENV — run deploy_apim.sh first."; exit 1; }
set -a; source "$DEMO_ENV"; set +a

RESOURCE_GROUP="${AZURE_OPENAI_RESOURCE_GROUP:-rg-airs-apim-pov}"
APIM_NAME="airsapimgw"
PREFIX="airsapim"
LAW_NAME="${PREFIX}logs"

# Allow overriding LAW workspace ID from demo.env (set by setup_monitoring.sh)
LAW_WORKSPACE_ID="${LAW_WORKSPACE_ID:-}"

az account show >/dev/null 2>&1 || { echo "Not logged in. Run: az login"; exit 1; }
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# ── Resolve Log Analytics workspace ID if not in demo.env ────────────────────
if [[ -z "$LAW_WORKSPACE_ID" ]]; then
  LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
    -n "$LAW_NAME" -g "$RESOURCE_GROUP" --query customerId -o tsv 2>/dev/null || true)
fi

if [[ -z "$LAW_WORKSPACE_ID" ]]; then
  echo -e "${RED}[FAIL]${NC} Log Analytics workspace '$LAW_NAME' not found."
  echo -e "       Run: ${CYAN}../azure-apim-gateway-pov/setup_monitoring.sh${NC} first."
  exit 1
fi

# ── Portal deep links ─────────────────────────────────────────────────────────
BASE="https://portal.azure.com/#@${TENANT_ID}/resource/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers"
APIM_PORTAL="${BASE}/Microsoft.ApiManagement/service/${APIM_NAME}/analytics"
LAW_PORTAL="${BASE}/Microsoft.OperationalInsights/workspaces/${LAW_NAME}/logs"

# ── KQL helpers ───────────────────────────────────────────────────────────────
run_kql() {
  local query="$1" timespan="${2:-PT30M}"
  az monitor log-analytics query \
    --workspace "$LAW_WORKSPACE_ID" \
    --analytics-query "$query" \
    --timespan "$timespan" \
    -o json 2>/dev/null || echo "[]"
}

# ── Rendering helpers ─────────────────────────────────────────────────────────
hr() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '─'; }

pad_right() {
  local s="$1" width="$2"
  printf "%-${width}s" "$s"
}

# Strip ANSI codes to measure visible length
visible_len() { echo -n "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -c; }

# ── Main draw loop ────────────────────────────────────────────────────────────
draw() {
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')

  # ── Fetch data ──────────────────────────────────────────────────────────────
  # 1. Summary counts (last 30 min)
  local summary_json
  summary_json=$(run_kql "
ApiManagementGatewayLogs
| where TimeGenerated > ago(30m)
| summarize
    TotalRequests = count(),
    AIRSBlocks    = countif(ResponseCode == 403),
    Allowed       = countif(ResponseCode == 200),
    AvgLatencyMs  = round(avg(DurationMs), 0),
    TotalTokens   = sum(tolong(parse_json(ResponseHeaders)[\"x-tokens-consumed\"]))
" "PT30M")

  local total_req airs_blocks allowed avg_lat total_tokens
  total_req=$(echo "$summary_json"    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['TotalRequests'] if d else 0)" 2>/dev/null || echo 0)
  airs_blocks=$(echo "$summary_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['AIRSBlocks'] if d else 0)" 2>/dev/null || echo 0)
  allowed=$(echo "$summary_json"      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['Allowed'] if d else 0)" 2>/dev/null || echo 0)
  avg_lat=$(echo "$summary_json"      | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d[0]['AvgLatencyMs']) if d else 0)" 2>/dev/null || echo 0)
  total_tokens=$(echo "$summary_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d[0]['TotalTokens']) if d else 0)" 2>/dev/null || echo 0)

  # 2. Recent requests (last 15 rows)
  local recent_json
  recent_json=$(run_kql "
ApiManagementGatewayLogs
| where TimeGenerated > ago(30m)
| extend Tokens = tolong(parse_json(ResponseHeaders)[\"x-tokens-consumed\"])
| project TimeGenerated, ResponseCode, DurationMs, Tokens,
          Path = tostring(split(Url, \"/\")[-1]),
          AIRSBlock = (ResponseCode == 403)
| order by TimeGenerated desc
| take 15
" "PT30M")

  # 3. AIRS block reasons (last 30 min)
  local blocks_json
  blocks_json=$(run_kql "
ApiManagementGatewayLogs
| where TimeGenerated > ago(30m) and ResponseCode == 403
| extend Msg = tostring(parse_json(BackendResponseBody).error)
| project TimeGenerated, DurationMs, BlockReason = coalesce(Msg, \"AIRS block\")
| order by TimeGenerated desc
| take 8
" "PT30M")

  # 4. Token trend (last hour, 5-min buckets)
  local trend_json
  trend_json=$(run_kql "
ApiManagementGatewayLogs
| where TimeGenerated > ago(1h) and ResponseCode == 200
| extend Tokens = tolong(parse_json(ResponseHeaders)[\"x-tokens-consumed\"])
| summarize Tokens=sum(Tokens), Reqs=count() by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
| take 12
" "PT1H")

  # ── Render ──────────────────────────────────────────────────────────────────
  clear

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}${BOLD}║  Prisma AIRS × Azure APIM — Live Gateway Monitor                        ║${NC}"
  printf "${CYAN}${BOLD}║${NC}  %-70s ${CYAN}${BOLD}║${NC}\n" "Updated: $now (refresh: ${REFRESH_SECS}s)"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # ── Summary row ─────────────────────────────────────────────────────────────
  echo -e "  ${BOLD}Last 30 minutes${NC}"
  echo ""
  printf "  ${GREEN}${BOLD}%-20s${NC}" "✓ Allowed"
  printf "  ${RED}${BOLD}%-20s${NC}" "✗ AIRS Blocks"
  printf "  ${CYAN}%-20s${NC}" "Total Requests"
  printf "  ${YELLOW}%-18s${NC}" "Avg Latency"
  printf "  ${MAGENTA}%-15s${NC}\n" "Tokens Used"

  local block_pct=0
  if [[ "$total_req" -gt 0 ]]; then
    block_pct=$(( airs_blocks * 100 / total_req ))
  fi

  printf "  ${GREEN}${BOLD}%-20s${NC}" "$allowed"
  printf "  ${RED}${BOLD}%-20s${NC}" "${airs_blocks}  (${block_pct}%)"
  printf "  ${CYAN}%-20s${NC}" "$total_req"
  printf "  ${YELLOW}%-18s${NC}" "${avg_lat} ms"
  printf "  ${MAGENTA}%-15s${NC}\n" "$total_tokens"

  echo ""
  hr

  # ── Recent requests table ───────────────────────────────────────────────────
  echo -e "\n  ${BOLD}Recent Requests${NC}  ${DIM}(most recent first)${NC}\n"
  printf "  %-22s  %-6s  %-10s  %-8s  %-30s\n" "Time (UTC)" "Code" "Latency" "Tokens" "Path"
  printf "  %-22s  %-6s  %-10s  %-8s  %-30s\n" "──────────────────────" "──────" "──────────" "────────" "──────────────────────────────"

  echo "$recent_json" | python3 - <<'PYEOF'
import json, sys

raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw)
except Exception:
    rows = []

RESET  = '\033[0m'
RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
CYAN   = '\033[0;36m'
DIM    = '\033[2m'

for r in rows:
    ts  = str(r.get('TimeGenerated', ''))[:19].replace('T', ' ')
    code = str(r.get('ResponseCode', '?'))
    lat  = str(r.get('DurationMs', '?'))
    tok  = str(r.get('Tokens', '0'))
    path = str(r.get('Path', ''))[:30]
    blk  = r.get('AIRSBlock', False)

    if blk or code == '403':
        code_str = f"{RED}{code:6s}{RESET}"
        tok_str  = f"{DIM}{'–':8s}{RESET}"
        row_col  = RED
        marker   = f"{RED}✗ BLOCKED{RESET}"
    else:
        code_str = f"{GREEN}{code:6s}{RESET}"
        tok_str  = f"{CYAN}{tok:8s}{RESET}"
        row_col  = RESET
        marker   = ""

    print(f"  {ts:22s}  {code_str}  {lat:>8s}ms  {tok_str}  {path:30s} {marker}")

if not rows:
    print(f"  {DIM}No requests in the last 30 minutes — generate traffic first.{RESET}")
    print(f"  {DIM}Run Terminal 2: python3 run_security_tests.py{RESET}")
PYEOF

  echo ""
  hr

  # ── AIRS Block detail ───────────────────────────────────────────────────────
  echo -e "\n  ${RED}${BOLD}Prisma AIRS Block Log${NC}  ${DIM}(last 30 min)${NC}\n"

  echo "$blocks_json" | python3 - <<'PYEOF'
import json, sys

raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw)
except Exception:
    rows = []

RESET   = '\033[0m'
RED     = '\033[0;31m'
YELLOW  = '\033[1;33m'
DIM     = '\033[2m'
BOLD    = '\033[1m'

if not rows:
    print(f"  {DIM}No AIRS blocks recorded — try a prompt injection in the chatbot.{RESET}")
else:
    print(f"  {'Time (UTC)':<22}  {'Latency':>10}  Block Reason")
    print(f"  {'──────────────────────':<22}  {'──────────':>10}  ──────────────────────────────────────────")
    for r in rows:
        ts     = str(r.get('TimeGenerated', ''))[:19].replace('T', ' ')
        lat    = str(r.get('DurationMs', '?'))
        reason = str(r.get('BlockReason', 'AIRS block'))[:70]
        print(f"  {ts:<22}  {lat:>8s}ms  {RED}{reason}{RESET}")
PYEOF

  echo ""
  hr

  # ── Token trend sparkline ───────────────────────────────────────────────────
  echo -e "\n  ${MAGENTA}${BOLD}Token Usage — Last Hour${NC}  ${DIM}(5-min buckets)${NC}\n"

  echo "$trend_json" | python3 - <<'PYEOF'
import json, sys, math

raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw)
except Exception:
    rows = []

RESET   = '\033[0m'
MAGENTA = '\033[0;35m'
CYAN    = '\033[0;36m'
DIM     = '\033[2m'
BOLD    = '\033[1m'

if not rows:
    print(f"  {DIM}No token data yet — send some allowed requests through the chatbot.{RESET}")
    sys.exit(0)

max_tokens = max((r.get('Tokens', 0) or 0) for r in rows) or 1
bar_width   = 30

print(f"  {'Time':10s}  {'Tokens':>8s}  {'Reqs':>5s}  Bar")
print(f"  {'──────────':10s}  {'────────':>8s}  {'─────':>5s}  {'──────────────────────────────'}")
for r in rows:
    ts  = str(r.get('TimeGenerated', ''))[:16].replace('T', ' ')[-8:]  # HH:MM only
    tok = int(r.get('Tokens', 0) or 0)
    req = int(r.get('Reqs', 0) or 0)
    filled = int(round(bar_width * tok / max_tokens))
    bar = f"{MAGENTA}{'█' * filled}{DIM}{'░' * (bar_width - filled)}{RESET}"
    print(f"  {ts:10s}  {tok:>8,d}  {req:>5d}  {bar}")
PYEOF

  echo ""
  hr

  # ── Portal links ─────────────────────────────────────────────────────────────
  echo -e "\n  ${CYAN}${BOLD}Azure Portal Deep Links:${NC}"
  echo -e "  ${BOLD}APIM Analytics:${NC}  ${YELLOW}${APIM_PORTAL}${NC}"
  echo -e "  ${BOLD}Log Analytics:${NC}   ${YELLOW}${LAW_PORTAL}${NC}"
  echo ""
  echo -e "  ${DIM}Note: Log Analytics has a ~5-10 min ingestion delay.${NC}"
  echo -e "  ${DIM}Press Ctrl+C to exit.  Next refresh in ${REFRESH_SECS}s.${NC}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────────────
trap 'echo -e "\n${GREEN}Monitor stopped.${NC}"; exit 0' INT TERM

echo -e "${CYAN}[INFO]${NC} Starting APIM monitor (workspace: ${LAW_WORKSPACE_ID})..."
echo -e "${DIM}       First draw may take 10-15 s while querying Log Analytics...${NC}"

while true; do
  draw
  sleep "$REFRESH_SECS"
done
