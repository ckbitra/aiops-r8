"""
Step Functions Failure Notifier Lambda - Sends SNS alert when patch workflow fails.
Triggered by EventBridge when Step Functions execution status is FAILED, ABORTED, or TIMED_OUT.
"""

import json
import os
import boto3
from typing import Any

sns = boto3.client("sns")

PATCH_ALERTS_TOPIC_ARN = os.environ.get("PATCH_ALERTS_TOPIC_ARN", "")


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Receives EventBridge event from Step Functions execution status change.
    Publishes to SNS when status is FAILED, ABORTED, or TIMED_OUT.
    """
    if not PATCH_ALERTS_TOPIC_ARN:
        _log("WARN", "PATCH_ALERTS_TOPIC_ARN not set, skipping SNS publish")
        return {"statusCode": 200, "body": {"skipped": True, "reason": "no_topic"}}

    try:
        detail = event.get("detail", {})
        status = detail.get("status", "")
        if status not in ("FAILED", "ABORTED", "TIMED_OUT"):
            _log("INFO", "Ignoring non-failure status", status=status)
            return {"statusCode": 200, "body": {"skipped": True, "reason": "status", "status": status}}

        execution_arn = detail.get("executionArn", "unknown")
        state_machine_arn = detail.get("stateMachineArn", "unknown")
        execution_name = detail.get("name", "unknown")
        cause = detail.get("cause", "No cause provided")
        error = detail.get("error", "")
        start_date = detail.get("startDate", "")
        stop_date = detail.get("stopDate", "")

        # Extract execution ID from ARN (last part after :)
        execution_id = execution_arn.split(":")[-1] if ":" in execution_arn else execution_arn

        subject = f"AIOps: Patch workflow FAILED - {execution_name}"
        message = (
            f"The AIOps R8 patch workflow execution has failed.\n\n"
            f"Execution Name: {execution_name}\n"
            f"Execution ID: {execution_id}\n"
            f"Status: {status}\n"
            f"Started: {start_date}\n"
            f"Stopped: {stop_date}\n\n"
        )
        if error:
            message += f"Error: {error}\n\n"
        message += f"Cause: {cause}\n\n"
        message += f"State Machine: {state_machine_arn}\n"
        message += f"Execution ARN: {execution_arn}"

        sns.publish(
            TopicArn=PATCH_ALERTS_TOPIC_ARN,
            Subject=subject,
            Message=message,
        )
        _log("INFO", "SNS alert sent for Step Functions failure", execution_name=execution_name, status=status)
        return {"statusCode": 200, "body": {"published": True, "execution_name": execution_name, "status": status}}

    except Exception as e:
        _log("ERROR", "Failed to publish SNS alert", error=str(e))
        raise
