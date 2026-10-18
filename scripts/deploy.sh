#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/terraform"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}   $*"; }
fail() { echo -e "${RED}[error]${NC}  $*" >&2; exit 1; }
info() { echo -e "${CYAN}[info]${NC}   $*"; }

# ============================================================
# Pre-flight checks
# ============================================================
log "Running pre-flight checks..."

[[ -f "$TERRAFORM_DIR/terraform.tfvars" ]] || fail "terraform.tfvars not found. Run ./scripts/setup.sh first."
aws sts get-caller-identity &>/dev/null || fail "AWS CLI not configured"

command -v terraform &>/dev/null || fail "terraform not installed"
command -v jq &>/dev/null        || fail "jq not installed"

# ============================================================
# Terraform plan
# ============================================================
log "Running terraform plan..."

pushd "$TERRAFORM_DIR" > /dev/null

terraform plan -out=tfplan -input=false

echo ""
warn "Review the plan above before proceeding."
read -p "Apply this plan? [y/N] " CONFIRM
echo ""

[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Deploy cancelled."; exit 0; }

# ============================================================
# Terraform apply
# ============================================================
log "Applying infrastructure..."
terraform apply -input=false tfplan
rm -f tfplan

# ============================================================
# Capture outputs
# ============================================================
log "Fetching deployment outputs..."

EXTERNAL_ALB_DNS=$(terraform output -raw external_alb_dns_name 2>/dev/null || echo "N/A")
CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain_name 2>/dev/null || echo "N/A")
BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || echo "N/A")
DASHBOARD_URL=$(terraform output -raw dashboard_url 2>/dev/null || echo "N/A")

popd > /dev/null

# ============================================================
# Post-deploy summary
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ScaleCommerce deployed successfully!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ${CYAN}Application URL:${NC}     http://$EXTERNAL_ALB_DNS"
echo -e "  ${CYAN}CDN URL:${NC}             https://$CLOUDFRONT_DOMAIN"
echo -e "  ${CYAN}Bastion SSH:${NC}         ssh -i ~/.ssh/scalecommerce-key ec2-user@$BASTION_IP"
echo -e "  ${CYAN}CloudWatch Dashboard:${NC} $DASHBOARD_URL"
echo ""
echo "  Run ./scripts/health-check.sh to verify all endpoints"
echo ""
