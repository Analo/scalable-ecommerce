"""
Custom metrics Lambda — publishes aggregated health metrics to CloudWatch.
Triggered by EventBridge every minute.
"""

import os
import boto3
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cloudwatch = boto3.client('cloudwatch')
autoscaling = boto3.client('autoscaling')

WEB_ASG_NAME = os.environ['WEB_ASG_NAME']
APP_ASG_NAME = os.environ['APP_ASG_NAME']
NAMESPACE = os.environ['NAMESPACE']


def get_asg_metrics(asg_name: str) -> dict:
    response = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )

    if not response['AutoScalingGroups']:
        logger.warning(f"ASG not found: {asg_name}")
        return {}

    asg = response['AutoScalingGroups'][0]
    instances = asg['Instances']

    in_service = sum(1 for i in instances if i['LifecycleState'] == 'InService')
    healthy = sum(
        1 for i in instances
        if i['LifecycleState'] == 'InService' and i['HealthStatus'] == 'Healthy'
    )

    return {
        'InServiceCount': in_service,
        'HealthyCount': healthy,
        'UnhealthyCount': in_service - healthy,
        'DesiredCapacity': asg['DesiredCapacity'],
        'MinSize': asg['MinSize'],
        'MaxSize': asg['MaxSize'],
        'CapacityUtilization': (in_service / asg['MaxSize'] * 100) if asg['MaxSize'] > 0 else 0,
    }


def publish_metrics(asg_name: str, tier: str, metrics: dict) -> None:
    if not metrics:
        return

    metric_data = []
    timestamp = datetime.utcnow()
    dimensions = [{'Name': 'AutoScalingGroupName', 'Value': asg_name}]

    for metric_name, value in metrics.items():
        metric_data.append({
            'MetricName': metric_name,
            'Dimensions': dimensions,
            'Timestamp': timestamp,
            'Value': float(value),
            'Unit': 'Percent' if 'Utilization' in metric_name else 'Count',
        })

    if metric_data:
        cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=metric_data)
        logger.info(f"Published {len(metric_data)} metrics for {tier} tier ({asg_name})")


def handler(event, context):
    errors = []

    for asg_name, tier in [(WEB_ASG_NAME, 'web'), (APP_ASG_NAME, 'app')]:
        try:
            metrics = get_asg_metrics(asg_name)
            publish_metrics(asg_name, tier, metrics)
        except Exception as exc:
            logger.error(f"Failed to process {tier} tier metrics: {exc}")
            errors.append(str(exc))

    if errors:
        raise RuntimeError(f"Errors publishing metrics: {'; '.join(errors)}")

    return {'statusCode': 200, 'body': 'Custom metrics published successfully'}
