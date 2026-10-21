locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ============================================================
# SNS Topic for Alerts
# ============================================================
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-alerts"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ============================================================
# CloudWatch Log Groups
# ============================================================
resource "aws_cloudwatch_log_group" "web_tier" {
  name              = "/aws/ec2/${local.name_prefix}/web-tier/system"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "app_tier" {
  name              = "/aws/ec2/${local.name_prefix}/app-tier/system"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "bastion" {
  name              = "/aws/ec2/${local.name_prefix}/bastion/auth"
  retention_in_days = 90
  tags              = var.tags
}

# RDS auto-creates /aws/rds/instance/*/error (and other log groups) when
# enabled_cloudwatch_logs_exports is set — Terraform must not own them or
# apply will fail with ResourceAlreadyExistsException on a fresh deploy.

# ============================================================
# CloudWatch Dashboard
# ============================================================
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix],
            [".", "TargetResponseTime", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
            [".", "HTTPCode_Target_2XX_Count", ".", "."]
          ]
          period = 60
          stat   = "Sum"
          title  = "External ALB — Traffic & Errors"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.web_asg_name],
            [".", ".", ".", var.app_asg_name]
          ]
          period = 60
          stat   = "Average"
          title  = "Auto Scaling — Instance Counts"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${local.name_prefix}-mysql"],
            [".", "DatabaseConnections", ".", "."],
            [".", "ReadLatency", ".", "."],
            [".", "WriteLatency", ".", "."]
          ]
          period = 60
          stat   = "Average"
          title  = "RDS — Performance"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", var.cloudfront_distribution_id, "Region", "Global"],
            [".", "BytesDownloaded", ".", ".", ".", "."],
            [".", "4xxErrorRate", ".", ".", ".", "."],
            [".", "5xxErrorRate", ".", ".", ".", "."]
          ]
          period = 300
          stat   = "Sum"
          title  = "CloudFront — CDN Metrics"
          region = "us-east-1"
        }
      }
    ]
  })
}

# ============================================================
# CloudWatch Alarms — ALB
# ============================================================
resource "aws_cloudwatch_metric_alarm" "alb_high_error_rate" {
  alarm_name          = "${local.name_prefix}-alb-high-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5XX errors exceeded 10 in 2 consecutive minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.external_alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_high_response_time" {
  alarm_name          = "${local.name_prefix}-alb-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 0.2
  alarm_description   = "p95 response time > 200ms"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.external_alb_arn_suffix
  }

  tags = var.tags
}

# ============================================================
# CloudWatch Alarms — Web Tier ASG
# ============================================================
resource "aws_cloudwatch_metric_alarm" "web_cpu_high" {
  alarm_name          = "${local.name_prefix}-web-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Web tier CPU > 70% — trigger scale out"
  alarm_actions       = [var.web_scale_up_policy_arn, aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.web_asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_low" {
  alarm_name          = "${local.name_prefix}-web-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "Web tier CPU < 30% — trigger scale in"
  alarm_actions       = [var.web_scale_down_policy_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.web_asg_name
  }

  tags = var.tags
}

# ============================================================
# CloudWatch Alarms — App Tier ASG
# ============================================================
resource "aws_cloudwatch_metric_alarm" "app_cpu_high" {
  alarm_name          = "${local.name_prefix}-app-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "App tier CPU > 70% — trigger scale out"
  alarm_actions       = [var.app_scale_up_policy_arn, aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.app_asg_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "app_cpu_low" {
  alarm_name          = "${local.name_prefix}-app-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 5
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "App tier CPU < 30% — trigger scale in"
  alarm_actions       = [var.app_scale_down_policy_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.app_asg_name
  }

  tags = var.tags
}

# ============================================================
# CloudWatch Alarms — RDS
# ============================================================
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU > 80%"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = "${local.name_prefix}-mysql"
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${local.name_prefix}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120 # 5 GB in bytes
  alarm_description   = "RDS free storage < 5 GB"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = "${local.name_prefix}-mysql"
  }

  tags = var.tags
}

# ============================================================
# Lambda — Custom Metrics Publisher
# ============================================================
data "archive_file" "custom_metrics" {
  type        = "zip"
  source_file = "${path.module}/lambda/custom_metrics.py"
  output_path = "${path.module}/lambda/custom_metrics.zip"
}

resource "aws_iam_role" "lambda_metrics" {
  name = "${local.name_prefix}-lambda-metrics-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_metrics.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_cloudwatch" {
  name = "${local.name_prefix}-lambda-cloudwatch"
  role = aws_iam_role.lambda_metrics.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "elasticloadbalancing:DescribeTargetHealth",
          "autoscaling:DescribeAutoScalingGroups",
          "rds:DescribeDBInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "custom_metrics" {
  filename         = data.archive_file.custom_metrics.output_path
  function_name    = "${local.name_prefix}-custom-metrics"
  role             = aws_iam_role.lambda_metrics.arn
  handler          = "custom_metrics.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.custom_metrics.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      WEB_ASG_NAME = var.web_asg_name
      APP_ASG_NAME = var.app_asg_name
      NAMESPACE    = "${var.project_name}/${var.environment}"
    }
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-custom-metrics"
  })
}

resource "aws_cloudwatch_event_rule" "custom_metrics" {
  name                = "${local.name_prefix}-custom-metrics-schedule"
  description         = "Trigger custom metrics Lambda every minute"
  schedule_expression = "rate(1 minute)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "custom_metrics" {
  rule = aws_cloudwatch_event_rule.custom_metrics.name
  arn  = aws_lambda_function.custom_metrics.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.custom_metrics.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.custom_metrics.arn
}
