#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# teardown.sh — Destroy all resources for the AKS ML Cluster demo
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "\033[0;34m[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Defaults
RESOURCE_GROUP="rg-aks-ml-demo"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --resource-group NAME  Resource group to delete (default: rg-aks-ml-demo)"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

# Check resource group exists
if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  error "Resource group '${RESOURCE_GROUP}' not found."
  exit 1
fi

echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ⚠️  DESTRUCTIVE ACTION                                    ║${NC}"
echo -e "${RED}${BOLD}║                                                              ║${NC}"
echo -e "${RED}${BOLD}║  This will permanently delete resource group:                ║${NC}"
echo -e "${RED}${BOLD}║    ${RESOURCE_GROUP}$(printf '%*s' $((42 - ${#RESOURCE_GROUP})) '')║${NC}"
echo -e "${RED}${BOLD}║                                                              ║${NC}"
echo -e "${RED}${BOLD}║  All resources inside will be destroyed.                     ║${NC}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -r -p "Are you sure? Type 'yes' to confirm: " response
if [[ "$response" != "yes" ]]; then
  info "Teardown cancelled."
  exit 0
fi

info "Deleting resource group '${RESOURCE_GROUP}'..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait

ok "Resource group deletion initiated (running in background)."
info "Azure will take a few minutes to fully remove all resources."
info "Monitor progress: az group show --name ${RESOURCE_GROUP} --query properties.provisioningState -o tsv"
