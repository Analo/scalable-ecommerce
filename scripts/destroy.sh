#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/terraform"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[destroy]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}    $*"; }
fail() { echo -e "${RED}[error]${NC}   $*" >&2; exit 1; }

# ============================================================
# Safety gates
# ============================================================
echo ""
echo -e "${RED}WARNING: This will DESTROY all ScaleCommerce infrastructure.${NC}"
echo -e "${RED}This action cannot be undone.${NC}"
echo ""

read -p "Type 'destroy' to confirm: " CONFIRM_1
echo ""
[[ "$CONFIRM_1" == "destroy" ]] || { log "Destroy cancelled."; exit 0; }

read -p "Are you absolutely sure? Type 'yes' to proceed: " CONFIRM_2
echo ""
[[ "$CONFIRM_2" == "yes" ]] || { log "Destroy cancelled."; exit 0; }

warn "Proceeding with infrastructure teardown in 5 seconds... (Ctrl+C to abort)"
sleep 5

# ============================================================
# Terraform destroy
# ============================================================
pushd "$TERRAFORM_DIR" > /dev/null

log "Running terraform destroy..."
terraform destroy -input=false -auto-approve

popd > /dev/null

echo ""
echo -e "${GREEN}All infrastructure destroyed.${NC}"
echo ""
echo "  Note: The Terraform state backend (S3 + DynamoDB) was NOT destroyed."
echo "  To also remove the backend, run:"
echo "  cd terraform/backend && terraform destroy"
echo ""
