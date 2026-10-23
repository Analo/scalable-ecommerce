# ScaleCommerce — Elastic Multi-Tier E-Commerce Platform on AWS

E-commerce businesses lose revenue in two ways: their infrastructure collapses under a flash sale, or they over-provision for peak capacity and pay for idle servers 23 hours a day. This project solves both problems simultaneously — an AWS platform that scales automatically with demand and returns to baseline the moment traffic drops, with zero manual intervention.

**Business outcome:** The platform survives a 10× traffic spike without pre-warming, recovers from an Availability Zone failure in under 2 minutes, and costs nothing extra at baseline because every scaling decision is driven by real CPU signal — not a guess about future load.

---

## Architecture

![ScaleCommerce AWS Architecture](./docs/architecture.png)

> Source: [`docs/architecture.drawio`](./docs/architecture.drawio) — open in [draw.io](https://app.diagrams.net/) to edit.

Traffic flows through four isolated network tiers across two Availability Zones. Each tier is a separate subnet with its own security boundary — the internet never reaches anything beyond the external load balancer:

```
Internet
    │
    ▼
External ALB  (public subnets — only entry point)
    │
    ▼
Web Tier ASG  (private — accepts only ALB traffic)
    │
    ▼
Internal ALB  (private — web tier cannot directly reach app tier)
    │
    ▼
App Tier ASG  (private — accepts only internal ALB traffic)
    │
    ▼
RDS MySQL Multi-AZ  (isolated — accepts only app tier, no internet route at subnet level)
    │
CloudFront + S3  (static assets cached at edge — never hit EC2)
```

Network layout across two Availability Zones:

| Subnet Tier | AZ-1 | AZ-2 |
|---|---|---|
| Public | 10.0.1.0/24 | 10.0.2.0/24 |
| Web (private) | 10.0.11.0/24 | 10.0.12.0/24 |
| App (private) | 10.0.21.0/24 | 10.0.22.0/24 |
| DB (private) | 10.0.31.0/24 | 10.0.32.0/24 |

---

## Key Design Decisions

These are the choices where judgment matters — where a senior engineer makes a different call than a junior one.

| Decision | Choice | Why |
|---|---|---|
| **Three tiers over two** | Web, App, DB separated | Each tier scales independently. A flash sale hammers the web tier; decoupling prevents that traffic from overwhelming the database directly. If you collapse web and app into one tier, you lose independent scaling and blast radius containment. |
| **Two ALBs over one** | External ALB + Internal ALB | The external ALB terminates internet traffic. The internal ALB routes between tiers. The app tier has no inbound rule from the internet — even if the web tier were compromised, the attacker cannot directly reach business logic or the database. Defense in depth. |
| **EC2 ASG over containers** | EC2 Auto Scaling Groups | Demonstrates foundational AWS networking — VPC design, tiered security groups, IAM instance profiles — without adding container orchestration complexity on top. ECS/EKS is the right next step once the network foundation is understood; they don't replace it. |
| **RDS Multi-AZ over Aurora** | RDS MySQL 8.0 Multi-AZ | Multi-AZ provides synchronous replication with automatic failover in 60–120 seconds. Aurora is the right choice for read-heavy workloads needing read replicas; for a write-consistent transactional workload, RDS Multi-AZ is simpler and ~40% cheaper. Use the simpler tool when it fits. |
| **CloudFront in front of S3** | CDN for all static assets | During a flash sale, 80–90% of requests are for static content — product images, CSS, JS. CloudFront absorbs those at the edge, globally, without touching EC2. This is the highest-leverage latency and cost optimisation available. |
| **Single NAT Gateway (dev)** | One shared gateway vs one per AZ | Saves ~$32/month during development. In production, one NAT Gateway per AZ is required: cross-AZ traffic costs money, and a single NAT is a single point of failure for all outbound traffic. The variable `single_nat_gateway` controls this — flip it for production. |

---

## What-If Scenarios

**What if an Availability Zone goes down?**
Both ASGs (web and app) span two AZs. The ALB health checks detect unhealthy targets within 30 seconds and stop routing traffic to the affected zone. RDS Multi-AZ promotes the standby replica automatically — typically within 60–120 seconds. The only manual step required is zero. The NAT Gateway is the one component that needs attention in production: in `dev` mode, a single NAT Gateway failure would block all outbound traffic from the surviving AZ — which is why `single_nat_gateway = false` is the correct production setting.

**What if traffic spikes 10×?**
CloudFront absorbs all static asset requests at the edge — those never reach EC2 regardless of traffic volume. For dynamic traffic, the ALB distributes load across all healthy instances. When CPU on the web or app tier exceeds 70% for two consecutive minutes, the ASG scale-out alarm fires and adds two instances. New instances bootstrap via user-data and register with the ALB automatically — no manual intervention, no pre-warming. When traffic drops, the scale-in alarm fires after five minutes below 30% CPU and removes instances one at a time. You pay for peak capacity only during the peak.

**What if an EC2 instance crashes?**
The ALB runs health checks every 30 seconds. A failed instance is deregistered within two check intervals. The ASG's desired capacity policy replaces it automatically — the new instance bootstraps via user-data (fetches credentials from Secrets Manager, not from config files) and joins the load balancer pool. The operator sees a brief dip in healthy host count on the CloudWatch dashboard; no alert fires unless the count drops below the minimum threshold.

**What if the database is overwhelmed?**
The RDS CPU alarm fires at 80% and sends an SNS notification. At the architecture level, the app tier is the only path to the database — the web tier cannot send queries directly. This limits the surface area. Production mitigations not included in this demo: read replicas for read-heavy queries, connection pooling (RDS Proxy), and query result caching. The architecture supports all three without structural changes.

**What if this needs to run in production tomorrow?**
Three changes: set `single_nat_gateway = false` (one NAT per AZ), set `multi_az = true` on RDS (already the default), and add HTTPS listeners on the external ALB with an ACM certificate. Everything else is already production-grade: IMDSv2 enforced, credentials in Secrets Manager, KMS encryption on RDS and S3, no public IPs on any compute instance.

---

## Security Design

Traffic between tiers is enforced at two levels — security groups (stateful, instance-level) and NACLs (stateless, subnet-level). Neither layer alone is sufficient; together they provide defense in depth:

- External ALB accepts ports 80 and 443 from the internet; all other inbound traffic is blocked at the security group
- Web tier instances accept traffic only from the external ALB security group — no public IP is assigned to any instance
- App tier instances accept traffic only from the internal ALB security group — the web tier cannot bypass the ALB to reach the app tier directly
- RDS accepts port 3306 only from the app tier security group and the bastion — no internet route exists at the subnet level either (subnet routing table has no IGW entry)
- IMDSv2 required on all EC2 instances — blocks SSRF-based metadata credential theft
- Database credentials stored in Secrets Manager and fetched at boot via user-data — never baked into AMIs, environment variables, or config files
- Customer-managed KMS keys for RDS and S3 encryption — key rotation and access auditable via CloudTrail

---

## Monitoring & Auto Scaling

CloudWatch alarms serve two purposes: operational alerts (notify the engineer) and scaling triggers (act automatically):

| Alarm | Threshold | Action |
|---|---|---|
| Web tier CPU high | > 70% for 2 min | Scale out — add 2 instances |
| Web tier CPU low | < 30% for 5 min | Scale in — remove 1 instance |
| App tier CPU high | > 70% for 2 min | Scale out — add 2 instances |
| App tier CPU low | < 30% for 5 min | Scale in — remove 1 instance |
| ALB 5XX errors | > 10 in 2 min | SNS alert |
| ALB p95 latency | > 200ms | SNS alert |
| RDS CPU | > 80% | SNS alert |
| RDS free storage | < 5 GB | SNS alert |

A Lambda function publishes custom ASG metrics (instance counts, capacity utilisation) to a CloudWatch namespace every minute — giving the dashboard visibility into scaling events that native EC2 metrics alone don't surface.

---

## Evidence Artifacts

To reproduce the scaling evidence:

```bash
# 1. Deploy the platform
./scripts/deploy.sh

# 2. Verify all endpoints are healthy
./scripts/health-check.sh

# 3. Generate load to trigger the auto-scaling alarms
./scripts/load-test.sh

# 4. Observe in CloudWatch:
#    - Web tier instance count increases within 2-3 minutes
#    - CPU alarm transitions from OK → ALARM → OK
#    - ALB healthy host count rises then falls as traffic ends
```

The load test script uses `hey` to generate sustained traffic against the external ALB endpoint. Watch the CloudWatch dashboard — the ASG scale-out event is visible within 3 minutes of sustained CPU above 70%.

---

## Project Structure

```
scalable-ecommerce/
├── terraform/
│   ├── backend/              S3 + DynamoDB for remote state
│   ├── main.tf               Root module — wires all modules together
│   ├── variables.tf
│   ├── providers.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/              VPC, subnets, IGW, NAT gateways, route tables
│       ├── security/         Security groups and NACLs for all tiers
│       ├── compute/          ALBs, launch templates, ASGs, bastion host
│       │   └── scripts/      EC2 user-data for web, app, and bastion tiers
│       ├── database/         RDS instance, parameter group, KMS key
│       ├── storage/          S3 buckets, CloudFront distribution
│       └── monitoring/       CloudWatch alarms, dashboard, Lambda metrics
├── scripts/
│   ├── setup.sh              One-time setup: backend, key pair, tfvars
│   ├── deploy.sh             Plan and apply with confirmation prompt
│   ├── destroy.sh            Tear down with double confirmation
│   ├── health-check.sh       HTTP checks across all endpoints
│   ├── load-test.sh          Traffic generation using hey
│   └── help.sh               Script usage reference
└── .github/workflows/
    ├── terraform-plan.yml          Runs on pull requests
    ├── terraform-apply.yml         Runs on merge to main
    ├── security-scan.yml           Checkov, TFSec, TruffleHog
    └── destroy-infrastructure.yml  Manual trigger with confirmation
```

---

## Deploy

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.9
- `jq`

### Steps

```bash
git clone https://github.com/Analo/scalable-ecommerce.git
cd scalable-ecommerce
chmod +x scripts/*.sh

# Creates the S3+DynamoDB state backend, generates terraform.tfvars,
# imports an SSH key pair, and runs terraform init
./scripts/setup.sh

# Review variables — especially allowed_ssh_cidr_blocks and alert_email
vim terraform/terraform.tfvars

# Plan and apply
./scripts/deploy.sh

# Verify endpoints
./scripts/health-check.sh

# Tear down when done (cost control)
./scripts/destroy.sh
```

---

## CI/CD

GitHub Actions uses OIDC to assume an IAM role — no long-lived AWS credentials stored in GitHub secrets.

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | IAM role ARN for GitHub Actions (OIDC) |
| `AWS_REGION` | Target region, e.g. `eu-west-1` |
| `AWS_ACCOUNT_ID` | 12-digit account ID |
| `TF_STATE_BUCKET` | S3 bucket for Terraform state |
| `TF_LOCK_TABLE` | DynamoDB table for state locking |
| `KEY_PAIR_NAME` | EC2 key pair name |
| `AMI_ID` | Amazon Linux 2023 AMI for the target region |

See [DEPLOYMENT.md](./DEPLOYMENT.md) for the full OIDC role setup.

---

## Cost Profile

NAT Gateways and ALBs are the main ongoing costs. The default `terraform.tfvars` sets `single_nat_gateway = true` — one shared gateway instead of one per AZ — saving ~$32/month during development.

| Resource | Dev (default) | Production |
|---|---|---|
| NAT Gateway | ~$32/month (×1) | ~$64/month (×2) |
| ALB ×2 (ext + int) | ~$33/month | ~$33/month |
| EC2 t3.micro ×2 | Free tier* | Depends on instance type |
| RDS db.t3.micro | Free tier* | Depends on instance class |
| CloudFront + S3 | Free tier | ~$0–5/month at low traffic |
| CloudWatch + Lambda | ~$1/month | ~$1/month |

*Free tier applies for the first 12 months (750 hours/month per service).

**For lab use:** deploy, run the load test, capture evidence, then destroy. The full cycle costs under $2 if completed within a few hours.

---

## Detailed Documentation

- [DEPLOYMENT.md](./DEPLOYMENT.md) — Step-by-step deployment and CI/CD setup
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — Common errors and fixes
