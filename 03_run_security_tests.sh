#!/usr/bin/env bash
# =============================================================================
# 03_run_security_tests.sh — Step 3: Run live security attack demonstrations
#
# Fires 14 live HTTP probes directly at the APIM gateway and reports:
#   - Baseline (benign chat)
#   - Attack #01: Prompt injection (role override)
#   - Attack #02: Malicious URL access
#   - Attack #03: PII / PCI data exfiltration
#   - Attack #04: Reverse shell command generation
#   - Attack #05: Indirect prompt injection via untrusted content
#   - Attack #06: Toxic / hateful content
#   - Attack #07: MCP tool poisoning (hidden instructions)
#   - Attack #08: MCP rug-pull (behavior change mid-session)
#   - Attack #09: MCP excessive permissions request
#   - Attack #10: MCP server impersonation
#   - Attack #11: MCP data exfiltration via tool calls
#   - Attack #12: MCP malicious code + URL injection (nested JSON)
#   - Attack #13: Multi-turn gradual jailbreak
#
# Output: per-attack BLOCKED / ALLOWED / BYPASSED status + APIM metrics summary
#
# Prerequisites:
#   Run 01_deploy_infra.sh + 02_setup_monitoring.sh first.
#   demo.env must contain APIM_GATEWAY_URL.
#
# Usage:
#   ./03_run_security_tests.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${REPO_ROOT}/azure-apim-gateway-pov/show_apim_traffic.py"
DEMO_ENV="${REPO_ROOT}/azure-apim-gateway-pov/demo.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
die()  { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Step 3/4 — Live Security Attack Demonstrations             ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

[[ -f "$SCRIPT" ]]   || die "show_apim_traffic.py not found at $SCRIPT"
[[ -f "$DEMO_ENV" ]] || die "demo.env not found at $DEMO_ENV — run 01_deploy_infra.sh first."

# Load demo.env into the environment
set -a; source "$DEMO_ENV"; set +a

# Detect Python
PYTHON=$(command -v python3 || command -v python || true)
[[ -z "$PYTHON" ]] && die "python3 not found. Install Python 3.9+."

# Install dependencies if needed
for pkg in requests; do
  "$PYTHON" -c "import $pkg" 2>/dev/null || {
    info "Installing Python package: $pkg"
    "$PYTHON" -m pip install -q "$pkg"
  }
done

info "Running show_apim_traffic.py against $APIM_GATEWAY_URL ..."
echo ""
exec "$PYTHON" "$SCRIPT"
