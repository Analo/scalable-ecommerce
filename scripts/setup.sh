#!/usr/bin/env bash
# =============================================================================
# setup.sh — One-time project initialisation
#
# Purpose:
#   Prepares a fresh environment for deploying the ScaleCommerce infrastructure.
#   Run this once before your first deploy. Subsequent deploys use deploy.sh.
#
# What this script does:
#   1. Checks that required tools are installed (terraform, aws cli, jq)
#   2. Verifies AWS credentials are configured and working
#   3. Generates an SSH key pair and imports the public key to AWS
#   4. Creates the Terraform remote state backend (S3 bucket + DynamoDB table)
#   5. Auto-generates terraform/terraform.tfvars from discovered values
#   6. Runs terraform init with the backend configuration
#
# Usage:
#   chmod +x scripts/*.sh
#   ./scripts/setup.sh
#
# Requirements:
#   - AWS CLI configured (aws configure)
#   - Terraform >= 1.9
#   - jq
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$ROOT_DIR/terraform"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
fail() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# =============================================================================
# Step 1 — Prerequisites
# =============================================================================
log "Checking prerequisites..."

for cmd in terraform aws jq; do
  command -v "$cmd" &>/dev/null || fail "'$cmd' is not installed or not in PATH. Install it and re-run."
done

TERRAFORM_VERSION=$(terraform version -json | jq -r '.terraform_version')
log "Terraform $TERRAFORM_VERSION — OK"

# Verify AWS credentials are active before doing anything destructive
AWS_IDENTITY=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || fail "AWS CLI not configured or credentials are expired. Run 'aws configure' first."

AWS_ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
log "AWS account: $AWS_ACCOUNT_ID | region: $AWS_REGION"

# =============================================================================
# Step 2 — SSH key pair
# =============================================================================
KEY_NAME="scalecommerce-key"
KEY_PATH="$HOME/.ssh/$KEY_NAME"

if [[ ! -f "$KEY_PATH" ]]; then
  log "Generating SSH key pair at $KEY_PATH..."
  ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$KEY_NAME"
  chmod 400 "$KEY_PATH"
else
  warn "SSH key already exists at $KEY_PATH — skipping generation"
fi

# Import the public key into AWS if it isn't there already
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$AWS_REGION" &>/dev/null; then
  log "Importing key pair '$KEY_NAME' to AWS ($AWS_REGION)..."
  aws ec2 import-key-pair \
    --key-name "$KEY_NAME" \
    --public-key-material "fileb://${KEY_PATH}.pub" \
    --region "$AWS_REGION"
else
  warn "Key pair '$KEY_NAME' already exists in AWS — skipping import"
fi

# =============================================================================
# Step 3 — Terraform remote state backend
#
# State is stored in S3 with DynamoDB locking. The bucket name embeds the
# account ID to guarantee global uniqueness without requiring manual input.
# =============================================================================
STATE_BUCKET="${AWS_ACCOUNT_ID}-scalecommerce-tfstate"
LOCK_TABLE="scalecommerce-tfstate-lock"

log "Creating Terraform state backend..."
log "  S3 bucket:       $STATE_BUCKET"
log "  DynamoDB table:  $LOCK_TABLE"

pushd "$TERRAFORM_DIR/backend" > /dev/null

terraform init -input=false -reconfigure
terraform apply -auto-approve \
  -var="bucket_name=$STATE_BUCKET" \
  -var="dynamodb_table_name=$LOCK_TABLE" \
  -var="aws_region=$AWS_REGION"

popd > /dev/null

log "State backend ready"

# =============================================================================
# Step 4 — Auto-generate terraform.tfvars
# =============================================================================
TFVARS_FILE="$TERRAFORM_DIR/terraform.tfvars"

if [[ -f "$TFVARS_FILE" ]]; then
  warn "terraform.tfvars already exists — skipping. Edit it manually if needed."
else
  log "Discovering latest Amazon Linux 2023 AMI for $AWS_REGION..."

  AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters \
      "Name=name,Values=al2023-ami-2023*-x86_64" \
      "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text \
    --region "$AWS_REGION")

  # ELB service account IDs are region-specific — required for ALB access logs
  # Full list: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
  declare -A ELB_ACCOUNTS=(
    ["us-east-1"]="127311923021"
    ["us-east-2"]="033677994240"
    ["us-west-1"]="027434742980"
    ["us-west-2"]="797873946194"
    ["eu-west-1"]="156460612806"
    ["eu-central-1"]="054676820928"
    ["ap-southeast-1"]="114774131450"
    ["ap-northeast-1"]="582318560864"
  )
  ELB_ACCOUNT_ID="${ELB_ACCOUNTS[$AWS_REGION]:-}"
  [[ -n "$ELB_ACCOUNT_ID" ]] \
    || warn "ELB account ID not found for $AWS_REGION — set elb_account_id manually in tfvars"

  MY_IP="$(curl -s ifconfig.me)/32"
  log "Your current IP: $MY_IP — will be used for bastion SSH access"

  log "Generating terraform.tfvars..."

  cat > "$TFVARS_FILE" << TFVARSEOF
# Generated by scripts/setup.sh on $(date -u +"%Y-%m-%d %H:%M UTC")
# Review all values before deploying — especially allowed_ssh_cidr_blocks.

project_name = "scalecommerce"
environment  = "dev"
aws_region   = "$AWS_REGION"
owner        = "Analo"

single_nat_gateway = true

ami_id        = "$AMI_ID"
key_pair_name = "$KEY_NAME"

# Restrict SSH to the IP detected at setup time — update if your IP changes
allowed_ssh_cidr_blocks = ["$MY_IP"]

web_asg_min_size         = 1
web_asg_max_size         = 6
web_asg_desired_capacity = 1

app_asg_min_size         = 1
app_asg_max_size         = 4
app_asg_desired_capacity = 1

enable_multi_az = false

account_id     = "$AWS_ACCOUNT_ID"
elb_account_id = "${ELB_ACCOUNT_ID}"

# Optional: set your email to receive CloudWatch alarm notifications
alert_email = ""
TFVARSEOF

  log "terraform.tfvars created"
fi

# =============================================================================
# Step 5 — Terraform init with remote backend
# =============================================================================
log "Initialising Terraform with remote backend..."

pushd "$TERRAFORM_DIR" > /dev/null

terraform init \
  -backend-config="bucket=$STATE_BUCKET" \
  -backend-config="key=scalecommerce/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$LOCK_TABLE" \
  -input=false

popd > /dev/null

echo ""
echo -e "${GREEN}Setup complete.${NC}"
echo ""
echo "  Next: review $TERRAFORM_DIR/terraform.tfvars then run ./scripts/deploy.sh"
echo ""
echo "  REMINDER: run ./scripts/destroy.sh immediately after validating"
echo "  to avoid ongoing AWS charges from NAT gateways and ALBs."
echo ""
