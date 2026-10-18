#!/bin/bash
set -euo pipefail

# Template variables injected by Terraform templatefile()
# These lowercase names are substituted at plan/apply time.
INTERNAL_ALB_DNS="${internal_alb_dns}"
APP_PORT="${app_port}"
ENVIRONMENT="${environment}"
PROJECT_NAME="${project_name}"
REGION="${region}"
S3_ASSETS_BUCKET="${s3_assets_bucket}"

# ============================================================
# System update and package install
# ============================================================
dnf update -y
dnf install -y nodejs npm nginx amazon-cloudwatch-agent aws-cli jq

# ============================================================
# Create application directory
# ============================================================
mkdir -p /opt/web-tier
useradd -r -s /bin/false webapp 2>/dev/null || true

# ============================================================
# Write web tier reverse proxy application
# ============================================================
cat > /opt/web-tier/app.js << 'APPEOF'
const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');

const app = express();
const PORT = process.env.PORT || 80;
const APP_BACKEND = process.env.APP_BACKEND;

app.use((req, res, next) => {
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  next();
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'healthy', tier: 'web', timestamp: new Date().toISOString() });
});

app.use('/api', createProxyMiddleware({
  target: APP_BACKEND,
  changeOrigin: true,
  timeout: 30000
}));

app.use(express.static('/var/www/html'));

app.listen(PORT, () => {
  console.log(`Web tier listening on port $${PORT}`);
  console.log(`Proxying API requests to $${APP_BACKEND}`);
});
APPEOF

# ============================================================
# Install Node.js dependencies
# ============================================================
cd /opt/web-tier
npm init -y
npm install express http-proxy-middleware

# ============================================================
# Pull static assets from S3
# ============================================================
mkdir -p /var/www/html
aws s3 sync "s3://$${S3_ASSETS_BUCKET}/static/" /var/www/html/ --region "$${REGION}" || echo "No static assets found in S3"

# ============================================================
# systemd service
# ============================================================
cat > /etc/systemd/system/web-tier.service << SVCEOF
[Unit]
Description=ScaleCommerce Web Tier
After=network.target

[Service]
Type=simple
User=webapp
WorkingDirectory=/opt/web-tier
Environment=NODE_ENV=$${ENVIRONMENT}
Environment=PORT=80
Environment=APP_BACKEND=http://$${INTERNAL_ALB_DNS}:$${APP_PORT}
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=web-tier

[Install]
WantedBy=multi-user.target
SVCEOF

chown -R webapp:webapp /opt/web-tier
chmod 755 /opt/web-tier

systemctl daemon-reload
systemctl enable web-tier
systemctl start web-tier

# ============================================================
# CloudWatch Agent configuration
# ============================================================
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/ec2/$${PROJECT_NAME}-$${ENVIRONMENT}/web-tier/system",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}",
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/"]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
