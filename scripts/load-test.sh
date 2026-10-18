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

log()  { echo -e "${GREEN}[load-test]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}      $*"; }
fail() { echo -e "${RED}[error]${NC}     $*" >&2; exit 1; }
info() { echo -e "${CYAN}[info]${NC}      $*"; }

# ============================================================
# Checks
# ============================================================
command -v hey &>/dev/null || fail "'hey' load testing tool not installed. Install with: go install github.com/rakyll/hey@latest"
command -v terraform &>/dev/null || fail "terraform not installed"

pushd "$TERRAFORM_DIR" > /dev/null
ALB_DNS=$(terraform output -raw external_alb_dns_name 2>/dev/null || echo "")
popd > /dev/null

[[ -n "$ALB_DNS" ]] || fail "Could not read ALB DNS. Is the stack deployed?"

BASE_URL="http://$ALB_DNS"

# ============================================================
# Load test parameters
# ============================================================
DURATION="${DURATION:-60}"        # seconds
CONCURRENCY="${CONCURRENCY:-50}"  # concurrent workers
QPS="${QPS:-100}"                 # requests per second (0 = unlimited)

echo ""
echo "ScaleCommerce Load Test"
echo "========================"
echo ""
info "Target:      $BASE_URL"
info "Duration:    ${DURATION}s"
info "Concurrency: $CONCURRENCY workers"
info "QPS:         ${QPS:-unlimited}"
echo ""

warn "This test will generate real traffic against your ALB and trigger Auto Scaling."
warn "Ensure you're in a non-production environment before proceeding."
echo ""
read -p "Start load test? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { log "Load test cancelled."; exit 0; }
echo ""

# ============================================================
# Run test — homepage
# ============================================================
log "Phase 1: Health endpoint baseline (10s, 10 workers)"
hey -z 10s -c 10 "$BASE_URL/health"
echo ""

log "Phase 2: API endpoint load (${DURATION}s, ${CONCURRENCY} workers)"
hey -z "${DURATION}s" -c "$CONCURRENCY" -q "$QPS" "$BASE_URL/api/products"
echo ""

log "Phase 3: Mixed traffic ramp-up (30s, 100 workers)"
hey -z 30s -c 100 -q 200 "$BASE_URL/api/products"
echo ""

echo -e "${GREEN}Load test complete.${NC}"
echo ""
echo "  Check CloudWatch for:"
echo "  - Auto Scaling events (should see scale-out at ~70% CPU)"
echo "  - ALB TargetResponseTime (target: p95 < 200ms)"
echo "  - Error rate (target: < 0.1%)"
echo ""
echo "  Dashboard: https://console.aws.amazon.com/cloudwatch/home"
echo ""
