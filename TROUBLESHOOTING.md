# ScaleCommerce — Troubleshooting

Common issues and how to resolve them.

---

## Terraform Issues

### `Error: Backend initialization required`

```
Error: Backend initialization required, please run "terraform init"
```

**Fix:** The backend configuration has changed or this is a fresh clone.

```bash
./scripts/setup.sh
# or
cd terraform && terraform init -reconfigure
```

---

### `Error: Error acquiring the state lock`

```
Error: Error acquiring the state lock
Lock Info:
  ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**Cause:** A previous Terraform run failed while holding the lock.

**Fix:**
```bash
cd terraform
terraform force-unlock <LOCK_ID>
```

---

### `Error: creating DB Instance: InvalidParameterCombination`

**Cause:** The chosen `db_instance_class` doesn't support Multi-AZ in your region, or the selected AZs don't support the instance class.

**Fix:** Change to a supported class in `terraform.tfvars`:
```hcl
db_instance_class = "db.t3.micro"  # dev
db_instance_class = "db.t3.medium" # prod
```

---

### `Error: InvalidClientTokenId` or `NoCredentialProviders`

**Cause:** AWS credentials are not configured or have expired.

**Fix:**
```bash
aws sts get-caller-identity   # test credentials
aws configure                 # reconfigure if needed
```

---

## Infrastructure Issues

### Health check returns HTTP 502/503

**Cause:** Target instances are not healthy or app is not running.

**Diagnosis:**
```bash
# Check target group health
aws elbv2 describe-target-health \
  --target-group-arn <TG_ARN> \
  --region us-east-1

# SSH into instance via bastion
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/scalecommerce-key ec2-user@$BASTION_IP

# From bastion, check service status on web instance
ssh -i ~/.ssh/scalecommerce-key ec2-user@<WEB_INSTANCE_IP>
sudo systemctl status web-tier
sudo journalctl -u web-tier -n 50
```

---

### RDS connection refused from app tier

**Cause:** Security group rule missing, or wrong endpoint in app config.

**Diagnosis:**
```bash
# From bastion or app instance:
mysql -h <RDS_ENDPOINT> -u dbadmin -p

# Check the DB secret is accessible
aws secretsmanager get-secret-value \
  --secret-id "scalecommerce-dev/rds/credentials" \
  --region us-east-1
```

**Fix:** Verify that the app tier security group allows port 3306 to the DB security group. Check `terraform/modules/security/main.tf`.

---

### Auto Scaling not triggering

**Cause:** CloudWatch alarms are not in ALARM state, or scaling policies are misconfigured.

**Diagnosis:**
```bash
# Check alarm states
aws cloudwatch describe-alarms \
  --alarm-names "scalecommerce-dev-web-cpu-high" \
  --region us-east-1 \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}'

# Check recent scaling activities
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name scalecommerce-dev-web-asg \
  --region us-east-1 \
  --max-items 5
```

---

### CloudFront returns 403 for S3 objects

**Cause:** The OAC bucket policy hasn't propagated, or the file path is wrong.

**Diagnosis:**
```bash
# List objects in the assets bucket
aws s3 ls s3://<ASSETS_BUCKET>/static/

# Check if the OAC policy is attached
aws s3api get-bucket-policy --bucket <ASSETS_BUCKET>
```

**Fix:** Re-run `terraform apply` to force the bucket policy to be re-evaluated. CloudFront changes can take up to 15 minutes to propagate.

---

### `Error: Error modifying DB instance: InvalidParameterCombination: Cannot upgrade...`

**Cause:** Trying to change the DB engine version while the instance is in a state that doesn't allow upgrades.

**Fix:** Wait for RDS to be in `available` state, then re-apply:
```bash
aws rds describe-db-instances \
  --db-instance-identifier scalecommerce-dev-mysql \
  --query 'DBInstances[0].DBInstanceStatus'
```

---

## GitHub Actions Issues

### `Error: credentials file not found`

**Cause:** `AWS_ROLE_ARN` secret is missing or the OIDC provider isn't configured.

**Fix:** Follow the OIDC setup steps in [DEPLOYMENT.md](./DEPLOYMENT.md#create-github-actions-iam-role-oidc).

---

### Plan succeeds but Apply fails with `AccessDenied`

**Cause:** The IAM role has insufficient permissions for a specific resource.

**Fix:** Attach additional policies to `ScaleCommerceGitHubActions` or use `PowerUserAccess` for portfolio projects:
```bash
aws iam attach-role-policy \
  --role-name ScaleCommerceGitHubActions \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
```

---

## Useful Commands

```bash
# View all Terraform outputs
cd terraform && terraform output

# Check all CloudWatch alarms at once
aws cloudwatch describe-alarms --state-value ALARM --region us-east-1

# Watch ASG instance counts in real time
watch -n 10 "aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names scalecommerce-dev-web-asg scalecommerce-dev-app-asg \
  --query 'AutoScalingGroups[*].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Min:MinSize,Max:MaxSize}' \
  --output table"

# Tail web tier logs from CloudWatch
aws logs tail /aws/ec2/scalecommerce-dev/web-tier/system --follow

# Tail app tier logs
aws logs tail /aws/ec2/scalecommerce-dev/app-tier/system --follow
```
