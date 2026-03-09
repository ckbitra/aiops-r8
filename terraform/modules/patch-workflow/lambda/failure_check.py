"""
Failure Check Lambda - Checks if any recently patched instance has stopped.
Used for batched patching: after each batch, check before proceeding.
"""

import json
import os
import boto3
from datetime import datetime, timedelta
from typing import Any

dynamodb = boto3.resource("dynamodb")
ec2 = boto3.client("ec2")

PATCH_EXECUTIONS_TABLE = os.environ.get("PATCH_EXECUTIONS_TABLE", "")
PATCH_CORRELATION_MINUTES = int(os.environ.get("PATCH_CORRELATION_MINUTES", "45"))


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Queries patch_executions for recent patches, checks EC2 state.
    Returns {abort: true, stopped_instances: [...]} if any stopped.
    """
    execution_id = event.get("execution_id", "")
    if not PATCH_EXECUTIONS_TABLE:
        return {"statusCode": 200, "body": {"abort": False, "stopped_instances": []}}

    table = dynamodb.Table(PATCH_EXECUTIONS_TABLE)
    cutoff = (datetime.utcnow() - timedelta(minutes=PATCH_CORRELATION_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Scan for recent patch executions (within correlation window)
    try:
        resp = table.scan(
            FilterExpression="started_at >= :cutoff",
            ExpressionAttributeValues={":cutoff": cutoff},
        )
    except Exception as e:
        _log("ERROR", "DynamoDB scan failed", error=str(e))
        return {"statusCode": 200, "body": {"abort": False, "stopped_instances": []}}

    instance_ids = list({item["instance_id"] for item in resp.get("Items", [])})
    if not instance_ids:
        return {"statusCode": 200, "body": {"abort": False, "stopped_instances": []}}

    # Check EC2 state for these instances
    try:
        desc = ec2.describe_instances(InstanceIds=instance_ids)
    except Exception as e:
        _log("ERROR", "EC2 describe failed", error=str(e))
        return {"statusCode": 200, "body": {"abort": False, "stopped_instances": []}}

    stopped = []
    for res in desc.get("Reservations", []):
        for inst in res.get("Instances", []):
            if inst.get("State", {}).get("Name") == "stopped":
                stopped.append(inst["InstanceId"])

    if stopped:
        _log("WARN", "Circuit-breaker: stopped instances detected", stopped=stopped, execution_id=execution_id)

    return {
        "statusCode": 200,
        "body": {
            "abort": len(stopped) > 0,
            "stopped_instances": stopped,
        },
    }
