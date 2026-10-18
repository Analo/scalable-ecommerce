#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${GREEN}ScaleCommerce — Available Scripts${NC}"
echo "=================================="
echo ""
echo -e "${CYAN}Setup & Deployment${NC}"
echo "  ./scripts/setup.sh        — One-time setup: SSH key, backend, tfvars, terraform init"
echo "  ./scripts/deploy.sh       — Plan + apply all infrastructure (prompts for confirmation)"
echo "  ./scripts/destroy.sh      — Tear down all infrastructure (double confirmation required)"
echo ""
echo -e "${CYAN}Operations${NC}"
echo "  ./scripts/health-check.sh — HTTP health checks across all endpoints"
echo "  ./scripts/load-test.sh    — Load test using 'hey' (requires: go install rakyll/hey@latest)"
echo ""
echo -e "${CYAN}Environment Variables (load-test.sh)${NC}"
echo -e "  ${YELLOW}DURATION${NC}=60       Test duration in seconds (default: 60)"
echo -e "  ${YELLOW}CONCURRENCY${NC}=50    Concurrent workers (default: 50)"
echo -e "  ${YELLOW}QPS${NC}=100           Requests per second limit (default: 100)"
echo ""
echo -e "${CYAN}Example Usage${NC}"
echo "  DURATION=120 CONCURRENCY=200 ./scripts/load-test.sh"
echo ""
echo -e "${CYAN}Documentation${NC}"
echo "  README.md           — Project overview and architecture"
echo "  DEPLOYMENT.md       — Step-by-step deployment guide"
echo "  TROUBLESHOOTING.md  — Common issues and fixes"
echo ""
