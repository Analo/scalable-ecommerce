locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ============================================================
# IAM Role for EC2 Instances
# ============================================================
resource "aws_iam_role" "ec2_role" {
  name = "${local.name_prefix}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# s3:ListBucket is required by `aws s3 sync` in addition to s3:GetObject —
# without it the CLI cannot enumerate objects and fails with AccessDenied.
resource "aws_iam_role_policy" "ec2_s3_assets" {
  name = "${local.name_prefix}-ec2-s3-assets"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "arn:aws:s3:::${var.s3_assets_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.s3_assets_bucket}"
      }
    ]
  })
}

# The app-tier user-data fetches DB credentials from Secrets Manager at boot.
# Without secretsmanager:GetSecretValue + kms:Decrypt, the script aborts before
# installing the service, leaving the instance with nothing listening on app_port.
resource "aws_iam_role_policy" "ec2_secrets_access" {
  name = "${local.name_prefix}-ec2-secrets-access"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = var.db_secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.db_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# ============================================================
# External Application Load Balancer
# ============================================================
resource "aws_lb" "external" {
  name               = "${local.name_prefix}-external-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_external_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod"

  access_logs {
    bucket  = var.alb_logs_bucket
    prefix  = "external-alb"
    enabled = true
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-external-alb"
  })
}

resource "aws_lb_target_group" "web_tier" {
  name     = "${local.name_prefix}-web-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-web-tg"
  })
}

# HTTP → HTTPS redirect: only created when a certificate is provided.
# Without HTTPS there is nothing to redirect to, so external_http_forward handles port 80 instead.
resource "aws_lb_listener" "external_http" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "external_https" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.external.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tier.arn
  }
}

# HTTP fallback when no certificate provided (dev/testing only)
resource "aws_lb_listener" "external_http_forward" {
  count = var.certificate_arn == "" ? 1 : 0

  load_balancer_arn = aws_lb.external.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tier.arn
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================
# Internal Application Load Balancer
# ============================================================
resource "aws_lb" "internal" {
  name               = "${local.name_prefix}-internal-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_internal_sg_id]
  subnets            = var.private_web_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-internal-alb"
  })
}

resource "aws_lb_target_group" "app_tier" {
  name     = "${local.name_prefix}-app-tg"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = var.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-app-tg"
  })
}

resource "aws_lb_listener" "internal_http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = var.app_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tier.arn
  }
}

# ============================================================
# Web Tier Launch Template
# ============================================================
resource "aws_launch_template" "web_tier" {
  name_prefix   = "${local.name_prefix}-web-"
  image_id      = var.ami_id
  instance_type = var.web_instance_type

  key_name = var.key_pair_name

  vpc_security_group_ids = [var.web_tier_sg_id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/scripts/web-tier-setup.sh", {
    internal_alb_dns = aws_lb.internal.dns_name
    app_port         = var.app_port
    environment      = var.environment
    project_name     = var.project_name
    region           = var.aws_region
    s3_assets_bucket = var.s3_assets_bucket
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${local.name_prefix}-web-tier"
      Tier = "web"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================
# Web Tier Auto Scaling Group
# ============================================================
resource "aws_autoscaling_group" "web_tier" {
  name                = "${local.name_prefix}-web-asg"
  vpc_zone_identifier = var.private_web_subnet_ids
  target_group_arns   = [aws_lb_target_group.web_tier.arn]
  health_check_type   = "ELB"

  min_size         = var.web_min_size
  max_size         = var.web_max_size
  desired_capacity = var.web_desired_capacity

  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.web_tier.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                                = "${local.name_prefix}-web-tier"
      Tier                                = "web"
      "aws-autoscaling-groupName"         = "${local.name_prefix}-web-asg"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_autoscaling_policy" "web_scale_up" {
  name                   = "${local.name_prefix}-web-scale-up"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web_tier.name
}

resource "aws_autoscaling_policy" "web_scale_down" {
  name                   = "${local.name_prefix}-web-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web_tier.name
}

# ============================================================
# App Tier Launch Template
# ============================================================
resource "aws_launch_template" "app_tier" {
  name_prefix   = "${local.name_prefix}-app-"
  image_id      = var.ami_id
  instance_type = var.app_instance_type

  key_name = var.key_pair_name

  vpc_security_group_ids = [var.app_tier_sg_id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/scripts/app-tier-setup.sh", {
    db_secret_arn = var.db_secret_arn
    environment   = var.environment
    project_name  = var.project_name
    region        = var.aws_region
    app_port      = var.app_port
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${local.name_prefix}-app-tier"
      Tier = "app"
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================
# App Tier Auto Scaling Group
# ============================================================
resource "aws_autoscaling_group" "app_tier" {
  name                = "${local.name_prefix}-app-asg"
  vpc_zone_identifier = var.private_app_subnet_ids
  target_group_arns   = [aws_lb_target_group.app_tier.arn]
  health_check_type   = "ELB"

  min_size         = var.app_min_size
  max_size         = var.app_max_size
  desired_capacity = var.app_desired_capacity

  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.app_tier.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                                = "${local.name_prefix}-app-tier"
      Tier                                = "app"
      "aws-autoscaling-groupName"         = "${local.name_prefix}-app-asg"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_autoscaling_policy" "app_scale_up" {
  name                   = "${local.name_prefix}-app-scale-up"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.app_tier.name
}

resource "aws_autoscaling_policy" "app_scale_down" {
  name                   = "${local.name_prefix}-app-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.app_tier.name
}

# ============================================================
# Bastion Host
# ============================================================
resource "aws_instance" "bastion" {
  ami           = var.ami_id
  instance_type = var.bastion_instance_type
  subnet_id     = var.public_subnet_ids[0]

  associate_public_ip_address = true
  key_name                    = var.key_pair_name

  vpc_security_group_ids = [var.bastion_sg_id]

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = base64encode(templatefile("${path.module}/scripts/bastion-setup.sh", {
    environment  = var.environment
    project_name = var.project_name
  }))

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-bastion"
    Tier = "management"
  })
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-bastion-eip"
  })
}
