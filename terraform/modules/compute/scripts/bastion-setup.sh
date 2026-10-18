#!/bin/bash
set -euo pipefail

# Template variables injected by Terraform templatefile()
# These lowercase names are substituted at plan/apply time.
ENVIRONMENT="${environment}"
PROJECT_NAME="${project_name}"

# ============================================================
# System update and security hardening
# ============================================================
dnf update -y
dnf install -y aws-cli jq mysql tmux vim htop fail2ban

# ============================================================
# SSH hardening
# ============================================================
cat >> /etc/ssh/sshd_config << 'EOF'
PermitRootLogin no
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ec2-user
EOF

systemctl restart sshd

# ============================================================
# fail2ban for SSH brute force protection
# ============================================================
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/secure
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban
systemctl start fail2ban

# ============================================================
# Useful shell aliases for operators
# ============================================================
cat >> /home/ec2-user/.bashrc << BASHRC
alias ll='ls -alF'
alias ..='cd ..'
export AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export PS1='\[\033[01;31m\][BASTION $${PROJECT_NAME}-$${ENVIRONMENT}]\[\033[00m\] \u@\h:\w\$ '
BASHRC

# ============================================================
# CloudWatch Agent — log SSH access
# ============================================================
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/secure",
            "log_group_name": "/aws/ec2/$${PROJECT_NAME}-$${ENVIRONMENT}/bastion/auth",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
CWEOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
