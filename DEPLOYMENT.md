# ScaleCommerce — Deployment Guide

Step-by-step instructions for deploying and managing the ScaleCommerce infrastructure.

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Terraform | >= 1.9 | [terraform.io/downloads](https://developer.hashicorp.com/terraform/downloads) |
| AWS CLI | >= 2.x | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| jq | any | `brew install jq` / `apt install jq` |
| hey (optional) | any | `go install github.com/rakyll/hey@latest` |

---

## Step 1 — Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:      <your key>
# AWS Secret Access Key:  <your secret>
# Default region name:    us-east-1
# Default output format:  json
```

Verify:

```bash
aws sts get-caller-identity
```

---

## Step 2 — Clone the Repository

```bash
git clone https://github.com/Analo/scalable-ecommerce.git
cd scalable-ecommerce
```

---

## Step 3 — Run Setup

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

This script:
- Generates an SSH key pair and imports it to AWS
- Creates the Terraform state backend (S3 + DynamoDB)
- Auto-generates `terraform/terraform.tfvars` with sensible defaults
- Runs `terraform init`

---

## Step 4 — Review Variables

Edit `terraform/terraform.tfvars`:

```hcl
project_name = "scalecommerce"
environment  = "dev"
aws_region   = "us-east-1"

# Required: your AWS account ID (find it in the AWS console)
account_id = "123456789012"

# Optional: set your email to receive CloudWatch alerts
alert_email = "your-email@example.com"

# Optional: restrict bastion SSH to your IP only (recommended)
allowed_ssh_cidr_blocks = ["YOUR_IP/32"]
```

Find your public IP:
```bash
curl -s ifconfig.me
```

---

## Step 5 — Deploy

```bash
./scripts/deploy.sh
```

Expected duration: **10–15 minutes** (RDS creation is the bottleneck).

The script will:
1. Run `terraform plan` and display the summary
2. Prompt for confirmation
3. Apply the plan
4. Print the deployment summary with all endpoint URLs

---

## Step 6 — Verify

```bash
./scripts/health-check.sh
```

Expected output:
```
ScaleCommerce Health Check
==========================

External ALB (scalecommerce-dev-external-alb-xxx.us-east-1.elb.amazonaws.com):
  [PASS] /health → HTTP 200
  [PASS] /api/products → HTTP 200

CloudFront CDN (dXXXXXXXXXXXX.cloudfront.net):
  [PASS] /static/app.js → HTTP 200

All health checks passed.
```

---

## Step 7 — Load Test (Optional)

Install `hey`:
```bash
go install github.com/rakyll/hey@latest
```

Run the load test:
```bash
./scripts/load-test.sh
```

Watch Auto Scaling in action:
```bash
# In a separate terminal — watch instance counts
watch -n 5 "aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names scalecommerce-dev-web-asg \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,InService:length(Instances[?LifecycleState==\`InService\`])}'"
```

---

## GitHub Actions (CI/CD)

### Required Secrets

In your GitHub repository: **Settings → Secrets and variables → Actions**

| Secret | How to find |
|---|---|
| `AWS_ROLE_ARN` | Create an OIDC IAM role — see below |
| `AWS_REGION` | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | `aws sts get-caller-identity --query Account` |
| `TF_STATE_BUCKET` | From `terraform/terraform.tfvars` |
| `TF_LOCK_TABLE` | From `terraform/terraform.tfvars` |
| `KEY_PAIR_NAME` | `scalecommerce-key` (default from setup.sh) |
| `AMI_ID` | From `terraform/terraform.tfvars` |

### Create GitHub Actions IAM Role (OIDC)

> **Important — GitHub OIDC sub claim format**
>
> GitHub now includes numeric user/repository IDs in the OIDC `sub` claim to prevent
> claim-squatting attacks after repo transfers or renames. The actual sub claim looks like:
>
> ```
> repo:Analo@13014489/scalable-ecommerce@1046386513:pull_request
> ```
>
> The trust policy must match this format exactly. Get your IDs with:
> ```bash
> gh api /user --jq '"User ID: \(.id), Login: \(.login)"'
> gh api /repos/OWNER/REPO --jq '"Repo ID: \(.id)"'
> ```

```bash
# 1 — Fetch your user and repo IDs
OWNER="Analo"
REPO="scalable-ecommerce"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
USER_ID=$(gh api /user --jq '.id')
REPO_ID=$(gh api /repos/${OWNER}/${REPO} --jq '.id')

# 2 — Create the OIDC provider (skip if it already exists)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list \
    6938fd4d98bab03faadb97b34396831e3780aea1 \
    1c58a3a8518e8759bf075b76b750d4f2df264fcd \
    06d927fecd0a84aeba28aad1d808139470fe95c3

# 3 — Create the trust policy with the correct sub claim format
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${OWNER}@${USER_ID}/${REPO}@${REPO_ID}:*"
      }
    }
  }]
}
EOF

# 4 — Create the role and attach permissions
aws iam create-role \
  --role-name ScaleCommerceGitHubActions \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name ScaleCommerceGitHubActions \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

rm trust-policy.json
```

Also set the `ELB_ACCOUNT_ID` secret — this is the AWS-owned account ID for the ELB service in your region, required for the ALB access log bucket policy:

| Region | ELB Account ID |
|---|---|
| `us-east-1` | `127311923021` |
| `eu-west-1` | `156460612806` |
| `ap-southeast-1` | `114774131450` |

See the [full list in AWS docs](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html).

---

## Tearing Down

```bash
./scripts/destroy.sh
```

To also remove the Terraform state backend (only when done with the project entirely):

```bash
cd terraform/backend
terraform destroy
```

---

## Environments

The same Terraform code supports multiple environments by setting `environment` in `terraform.tfvars`:

| Environment | Instance Types | Multi-AZ RDS | Protection |
|---|---|---|---|
| `dev` | t3.micro | No | No |
| `staging` | t3.small | No | No |
| `prod` | t3.medium+ | Yes | Deletion protection on |

For separate environments, use separate state keys:
```hcl
# dev
-backend-config="key=scalecommerce/dev/terraform.tfstate"

# prod
-backend-config="key=scalecommerce/prod/terraform.tfstate"
```
