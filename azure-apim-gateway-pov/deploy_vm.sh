#!/usr/bin/env bash
# =============================================================================
# deploy_vm.sh — Deploy a demo-runner VM inside the VNet
#
# Why: Azure AI Search has publicNetworkAccess=Disabled (org policy).
# GlobalProtect cannot route WSL2 traffic to the private endpoint.
# This VM lives in the same VNet and is reached via Azure Bastion Standard
# (org policy also blocks public IPs on NICs, so Bastion is required).
#
# Usage:
#   ./deploy_vm.sh          # full deployment
#   ./deploy_vm.sh --tunnel # print Bastion tunnel commands for an existing VM
#
# After deployment:
#   Terminal 1: az network bastion tunnel ... (keep running)
#   Terminal 2: ssh -i ~/.ssh/id_rsa_airsapim -L 50505:localhost:50505 -p 2222 azureuser@127.0.0.1
#   On the VM:  cd ~/azure-search-openai-demo && ./start_demo.sh
#   Chrome:     http://localhost:50505
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ── Config (must match deploy_apim.sh) ───────────────────────────────────────
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-rg-airs-apim-pov}"
LOCATION="${AZURE_LOCATION:-eastus}"
PREFIX="${DEPLOY_PREFIX:-airsapim}"
VNET_NAME="${PREFIX}vnet"
SEARCH_NAME="${PREFIX}search"

VM_NAME="${PREFIX}vm"
VM_SUBNET_NAME="demo-runner"
VM_SIZE="Standard_B2s"
VM_IMAGE="Ubuntu2204"
VM_ADMIN="azureuser"
VM_SSH_KEY_FILE="${HOME}/.ssh/id_rsa_airsapim"

# Bastion — Standard tier required for SSH tunneling (no public IP on NIC policy)
BASTION_NAME="${PREFIX}bastion"
BASTION_SUBNET_NAME="AzureBastionSubnet"   # must be exactly this name
BASTION_PIP_NAME="${BASTION_NAME}-pip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_ENV="${SCRIPT_DIR}/demo.env"
DEMO_REPO_DIR="$(dirname "$SCRIPT_DIR")/azure-search-openai-demo"

# ── Flags ─────────────────────────────────────────────────────────────────────
PRINT_TUNNEL_ONLY=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --tunnel) PRINT_TUNNEL_ONLY=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--tunnel]"
      echo "  --tunnel   Print Bastion tunnel commands for an existing VM, then exit"
      exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# ── Prereqs ───────────────────────────────────────────────────────────────────
command -v az  >/dev/null 2>&1 || die "Azure CLI not found."
az account show >/dev/null 2>&1 || die "Not logged in. Run: az login"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

print_tunnel() {
  local vm_id
  vm_id=$(az vm show -n "$VM_NAME" -g "$RESOURCE_GROUP" --query id -o tsv 2>/dev/null || true)
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║  Demo VM ready — Bastion tunnel setup                        ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${YELLOW}WSL2 Terminal 1 — open Bastion SSH tunnel (keep running):${NC}"
  echo -e "    ${CYAN}az network bastion tunnel \\${NC}"
  echo -e "      ${CYAN}--name ${BASTION_NAME} \\${NC}"
  echo -e "      ${CYAN}--resource-group ${RESOURCE_GROUP} \\${NC}"
  echo -e "      ${CYAN}--target-resource-id ${vm_id} \\${NC}"
  echo -e "      ${CYAN}--resource-port 22 --port 2222${NC}"
  echo ""
  echo -e "  ${YELLOW}WSL2 Terminal 2 — SSH through tunnel with port-forward:${NC}"
  echo -e "    ${CYAN}ssh -i ${VM_SSH_KEY_FILE} -L 50505:localhost:50505 -p 2222 ${VM_ADMIN}@127.0.0.1${NC}"
  echo -e "    ${CYAN}# Once on the VM:${NC}"
  echo -e "    ${CYAN}cd ~/azure-search-openai-demo && ./start_demo.sh${NC}"
  echo ""
  echo -e "  ${YELLOW}WSL2 Terminal 3 — security tests (APIM is public, no tunnel needed):${NC}"
  echo -e "    ${CYAN}cd ~/prisma-airs-apim-pov/azure-search-openai-demo${NC}"
  echo -e "    ${CYAN}python3 run_security_tests.py${NC}"
  echo ""
  echo -e "  ${YELLOW}Windows Chrome:${NC}  ${CYAN}http://localhost:50505${NC}"
  echo ""
}

# ── --tunnel shortcut ─────────────────────────────────────────────────────────
if $PRINT_TUNNEL_ONLY; then
  az vm show -n "$VM_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1 \
    || die "VM '$VM_NAME' not found in '$RESOURCE_GROUP'. Run ./deploy_vm.sh first."
  print_tunnel
  exit 0
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Prisma AIRS POV — Demo Runner VM Deployment                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Resource group : $RESOURCE_GROUP"
info "VM name        : $VM_NAME  ($VM_SIZE, $VM_IMAGE, no public IP)"
info "VNet           : $VNET_NAME"
info "Access         : Azure Bastion Standard (policy: NICs may not have public IPs)"
echo ""

[[ -f "$DEMO_ENV" ]] || die "demo.env not found at '$DEMO_ENV'. Run deploy_apim.sh first."
[[ -f "${DEMO_REPO_DIR}/start_demo.sh" ]] \
  || die "start_demo.sh not found at '${DEMO_REPO_DIR}/start_demo.sh'."
[[ -f "${DEMO_REPO_DIR}/run_security_tests.py" ]] \
  || die "run_security_tests.py not found at '${DEMO_REPO_DIR}/run_security_tests.py'."

# ── SSH key ───────────────────────────────────────────────────────────────────
if [[ ! -f "${VM_SSH_KEY_FILE}" ]]; then
  info "Generating dedicated SSH key pair at ${VM_SSH_KEY_FILE}..."
  ssh-keygen -t rsa -b 4096 -f "$VM_SSH_KEY_FILE" -N "" -C "airsapim-demo-vm" -q
  success "SSH key generated."
else
  success "SSH key already exists: ${VM_SSH_KEY_FILE}"
fi
VM_SSH_PUB_KEY=$(cat "${VM_SSH_KEY_FILE}.pub")

# ── Step 1: VM subnet ─────────────────────────────────────────────────────────
info "Step 1/6: Ensuring VM subnet '$VM_SUBNET_NAME' (10.100.2.0/24)..."
if az network vnet subnet show -n "$VM_SUBNET_NAME" -g "$RESOURCE_GROUP" \
   --vnet-name "$VNET_NAME" >/dev/null 2>&1; then
  success "VM subnet already exists."
else
  az network vnet subnet create \
    -n "$VM_SUBNET_NAME" \
    -g "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --address-prefix "10.100.2.0/24" \
    -o none
  success "VM subnet created."
fi

VM_SUBNET_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${VNET_NAME}/subnets/${VM_SUBNET_NAME}"

# ── Step 2: AzureBastionSubnet ────────────────────────────────────────────────
# Name must be exactly "AzureBastionSubnet"; minimum /26.
info "Step 2/6: Ensuring AzureBastionSubnet (10.100.3.0/26)..."
if az network vnet subnet show -n "$BASTION_SUBNET_NAME" -g "$RESOURCE_GROUP" \
   --vnet-name "$VNET_NAME" >/dev/null 2>&1; then
  success "AzureBastionSubnet already exists."
else
  az network vnet subnet create \
    -n "$BASTION_SUBNET_NAME" \
    -g "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --address-prefix "10.100.3.0/26" \
    -o none
  success "AzureBastionSubnet created (10.100.3.0/26)."
fi

# ── Step 3: Bastion public IP ─────────────────────────────────────────────────
# Policy blocks public IPs on NICs but Bastion's own public IP is on the
# Bastion resource, not a NIC, so it is not blocked by that policy.
info "Step 3/6: Ensuring Bastion public IP '$BASTION_PIP_NAME'..."
if az network public-ip show -n "$BASTION_PIP_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Bastion public IP already exists."
else
  az network public-ip create \
    -n "$BASTION_PIP_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    -o none
  success "Bastion public IP created."
fi

# ── Step 4: Azure Bastion Standard ───────────────────────────────────────────
# Standard tier is required for the 'tunnel' command used for SSH port-forwarding.
info "Step 4/6: Ensuring Azure Bastion '$BASTION_NAME' (Standard — ~5 min to provision)..."
if az network bastion show -n "$BASTION_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "Bastion already exists."
else
  warn "Creating Azure Bastion Standard — this takes ~5 minutes..."
  az network bastion create \
    -n "$BASTION_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --vnet-name "$VNET_NAME" \
    --public-ip-address "$BASTION_PIP_NAME" \
    --sku Standard \
    --enable-tunneling true \
    -o none
  success "Azure Bastion Standard created."
fi

# ── Step 5: VM (no public IP on NIC) ─────────────────────────────────────────
info "Step 5/6: Ensuring VM '$VM_NAME' (no public IP — accessed via Bastion)..."

CLOUD_INIT=$(cat <<'CLOUDINIT'
#cloud-config
package_update: true
package_upgrade: false
packages:
  - git
  - curl
  - python3-pip
  - python3-venv
  - python3-dev
  - build-essential
  - unzip

runcmd:
  - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  - apt-get install -y nodejs
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  - touch /home/azureuser/.vm-ready
  - chown azureuser:azureuser /home/azureuser/.vm-ready
CLOUDINIT
)

if az vm show -n "$VM_NAME" -g "$RESOURCE_GROUP" >/dev/null 2>&1; then
  success "VM already exists."
else
  warn "Creating VM (no public IP — ~3 minutes for provisioning + cloud-init)..."

  CLOUD_INIT_FILE=$(mktemp /tmp/cloud-init-XXXXXX.yaml)
  echo "$CLOUD_INIT" > "$CLOUD_INIT_FILE"

  az vm create \
    -n "$VM_NAME" \
    -g "$RESOURCE_GROUP" \
    -l "$LOCATION" \
    --size "$VM_SIZE" \
    --image "$VM_IMAGE" \
    --admin-username "$VM_ADMIN" \
    --ssh-key-value "$VM_SSH_PUB_KEY" \
    --subnet "$VM_SUBNET_ID" \
    --public-ip-address "" \
    --nsg "" \
    --custom-data "@${CLOUD_INIT_FILE}" \
    --os-disk-size-gb 64 \
    -o none

  rm -f "$CLOUD_INIT_FILE"
  success "VM created."

  info "  Waiting for VM to reach Succeeded state..."
  for i in {1..24}; do
    VM_STATE=$(az vm show -n "$VM_NAME" -g "$RESOURCE_GROUP" \
      --query provisioningState -o tsv 2>/dev/null || echo "Creating")
    [[ "$VM_STATE" == "Succeeded" ]] && break
    warn "  VM state: $VM_STATE (attempt $i/24, waiting 15s)..."
    sleep 15
  done
  success "VM provisioned."
fi

VM_ID=$(az vm show -n "$VM_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)

# ── Step 6: Push files + configure VM via run-command ────────────────────────
# No SSH/SCP needed — az vm run-command invoke works via the Azure control plane.
info "Step 6/6: Waiting for cloud-init, then pushing demo files via run-command..."

info "  Polling for cloud-init completion (~3-5 min on first boot)..."
for i in {1..40}; do
  READY=$(az vm run-command invoke \
    -n "$VM_NAME" -g "$RESOURCE_GROUP" \
    --command-id RunShellScript \
    --scripts "test -f /home/azureuser/.vm-ready && echo yes || echo no" \
    --query "value[0].message" -o tsv 2>/dev/null || echo "no")
  [[ "$READY" == *"yes"* ]] && break
  warn "  cloud-init still running (attempt $i/40, waiting 15s)..."
  sleep 15
done
success "Cloud-init complete."

info "  Encoding demo files for transfer..."
START_DEMO_B64=$(base64 -w 0 "${DEMO_REPO_DIR}/start_demo.sh")
RUN_TESTS_B64=$(base64 -w 0 "${DEMO_REPO_DIR}/run_security_tests.py")
DEMO_ENV_B64=$(base64 -w 0 "${DEMO_ENV}")

SETUP_SCRIPT=$(mktemp /tmp/vm-setup-XXXXXX.sh)
cat > "$SETUP_SCRIPT" <<SETUPEOF
#!/bin/bash
set -e

# Clone demo repo if not already present
if [[ ! -d /home/azureuser/azure-search-openai-demo ]]; then
  git clone --depth 1 https://github.com/Azure-Samples/azure-search-openai-demo.git /home/azureuser/azure-search-openai-demo
  echo "Repo cloned."
else
  echo "Repo already present."
fi

# Write files (base64-encoded to avoid shell quoting issues)
echo "${START_DEMO_B64}" | base64 -d > /home/azureuser/azure-search-openai-demo/start_demo.sh
echo "${RUN_TESTS_B64}" | base64 -d > /home/azureuser/azure-search-openai-demo/run_security_tests.py
echo "${DEMO_ENV_B64}"  | base64 -d > /home/azureuser/azure-search-openai-demo/demo.env

chmod +x /home/azureuser/azure-search-openai-demo/start_demo.sh \
         /home/azureuser/azure-search-openai-demo/run_security_tests.py

# On the VM, demo.env lives alongside the script — patch the path
sed -i 's|DEMO_ENV=.*|DEMO_ENV="\${SCRIPT_DIR}/demo.env"|' \
  /home/azureuser/azure-search-openai-demo/start_demo.sh

chown -R azureuser:azureuser /home/azureuser/azure-search-openai-demo/

# Add Search private endpoint to /etc/hosts
SEARCH_IP=\$(grep '^SEARCH_PRIVATE_IP=' /home/azureuser/azure-search-openai-demo/demo.env | cut -d= -f2 | tr -d '"')
SEARCH_SVC=\$(grep '^AZURE_SEARCH_SERVICE=' /home/azureuser/azure-search-openai-demo/demo.env | cut -d= -f2 | tr -d '"')
if [[ -n "\$SEARCH_IP" && "\$SEARCH_IP" != "RETRIEVE_MANUALLY" ]]; then
  HOSTS_ENTRY="\$SEARCH_IP \${SEARCH_SVC}.search.windows.net"
  if ! grep -qF "\${SEARCH_SVC}.search.windows.net" /etc/hosts; then
    echo "\$HOSTS_ENTRY" >> /etc/hosts
    echo "Added to /etc/hosts: \$HOSTS_ENTRY"
  else
    echo "/etc/hosts entry already present."
  fi
fi

echo "VM setup complete."
SETUPEOF

info "  Running setup script on VM via run-command..."
az vm run-command invoke \
  -n "$VM_NAME" \
  -g "$RESOURCE_GROUP" \
  --command-id RunShellScript \
  --scripts "$(cat "$SETUP_SCRIPT")" \
  --query "value[0].message" -o tsv

rm -f "$SETUP_SCRIPT"
success "Demo files deployed to VM."

# ── Print instructions ────────────────────────────────────────────────────────
print_tunnel

SEARCH_SVC_HINT=$(grep "^AZURE_SEARCH_SERVICE=" "$DEMO_ENV" 2>/dev/null | cut -d= -f2 || echo "airsapimsearch")
echo -e "  ${YELLOW}SSH key location:${NC} ${VM_SSH_KEY_FILE}"
echo -e "  ${YELLOW}Copy to Windows (optional, for Windows Terminal / PuTTY):${NC}"
echo -e "    ${CYAN}cp ${VM_SSH_KEY_FILE} /mnt/c/Users/\$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\\r')/.ssh/id_rsa_airsapim 2>/dev/null || true${NC}"
echo ""
echo -e "  ${YELLOW}Verify Search private endpoint from the VM (run after opening Bastion tunnel + SSH):${NC}"
echo -e "    ${CYAN}curl -sk -o /dev/null -w '%{http_code}' https://${SEARCH_SVC_HINT}.search.windows.net${NC}"
echo -e "    Expected: ${GREEN}403${NC} (reachable but unauthenticated = private endpoint working)"
echo ""
echo -e "  ${YELLOW}Note:${NC} Azure Bastion Standard costs ~\$0.19/hr. Delete when POV is complete:"
echo -e "    ${CYAN}az network bastion delete -n ${BASTION_NAME} -g ${RESOURCE_GROUP}${NC}"
echo ""
