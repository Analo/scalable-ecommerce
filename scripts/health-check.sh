#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/terraform"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $*"; }

FAILURES=0

# ============================================================
# Get endpoints from Terraform
# ============================================================
pushd "$TERRAFORM_DIR" > /dev/null

ALB_DNS=$(terraform output -raw external_alb_dns_name 2>/dev/null || echo "")
CF_DOMAIN=$(terraform output -raw cloudfront_domain_name 2>/dev/null || echo "")

popd > /dev/null

[[ -n "$ALB_DNS" ]] || { echo "Could not read ALB DNS from terraform output. Is the stack deployed?"; exit 1; }

echo ""
echo "ScaleCommerce Health Check"
echo "=========================="
echo ""

# ============================================================
# ALB health
# ============================================================
echo "External ALB ($ALB_DNS):"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/health" || echo "000")
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "/health → HTTP $HTTP_STATUS"
elif [[ "$HTTP_STATUS" == "301" || "$HTTP_STATUS" == "302" ]]; then
  info "/health → HTTP $HTTP_STATUS (redirect to HTTPS — expected if certificate is configured)"
else
  fail "/health → HTTP $HTTP_STATUS"
fi

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://$ALB_DNS/api/products" || echo "000")
if [[ "$HTTP_STATUS" =~ ^2 ]]; then
  pass "/api/products → HTTP $HTTP_STATUS"
else
  fail "/api/products → HTTP $HTTP_STATUS"
fi

# ============================================================
# CloudFront health
# ============================================================
if [[ -n "$CF_DOMAIN" ]]; then
  echo ""
  echo "CloudFront CDN ($CF_DOMAIN):"

  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://$CF_DOMAIN/static/app.js" || echo "000")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    pass "/static/app.js → HTTP $HTTP_STATUS"
  else
    fail "/static/app.js → HTTP $HTTP_STATUS"
  fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "${GREEN}All health checks passed.${NC}"
else
  echo -e "${RED}$FAILURES health check(s) failed.${NC}"
  exit 1
fi
echo ""
