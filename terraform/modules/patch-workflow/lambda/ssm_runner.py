"""
SSM Runner Lambda - Runs SSM commands and waits for completion.
Circuit-breaker: pre-patch check for blocked CVEs, records patch executions.
Creates pre-patch AMIs before applying patches.
Supports: chunking (50 targets/command), dry-run, structured logging, metrics.
"""

import json
import os
import time
import boto3
from datetime import datetime, timedelta
from typing import Any, List

ssm = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
ec2 = boto3.client("ec2")
cloudwatch = boto3.client("cloudwatch")

PATCH_FAILURES_TABLE = os.environ.get("PATCH_FAILURES_TABLE", "")
PATCH_EXECUTIONS_TABLE = os.environ.get("PATCH_EXECUTIONS_TABLE", "")
PATCH_ALERTS_TOPIC_ARN = os.environ.get("PATCH_ALERTS_TOPIC_ARN", "")
CVE_BLOCK_TTL_DAYS = int(os.environ.get("CVE_BLOCK_TTL_DAYS", "7"))
AMI_RETENTION_DAYS = int(os.environ.get("AMI_RETENTION_DAYS", "7"))
SSM_CHUNK_SIZE = int(os.environ.get("SSM_CHUNK_SIZE", "50"))
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "AIOps/Patch")


def _log(level: str, msg: str, execution_id: str = "", **kwargs: Any) -> None:
    record = {"level": level, "message": msg, "execution_id": execution_id, **kwargs}
    print(json.dumps(record, default=str))


def _put_metric(metric_name: str, value: float = 1, dimensions: dict = None) -> None:
    try:
        dims = [{"Name": k, "Value": str(v)} for k, v in (dimensions or {}).items()]
        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{"MetricName": metric_name, "Value": value, "Dimensions": dims}],
        )
    except Exception:
        pass


def _check_blocked_cves(critical_cve_ids: list) -> List[str]:
    if not critical_cve_ids or not PATCH_FAILURES_TABLE:
        return []
    critical_cve_ids = critical_cve_ids if isinstance(critical_cve_ids, list) else []
    if not critical_cve_ids:
        return []

    table = dynamodb.Table(PATCH_FAILURES_TABLE)
    cutoff = (datetime.utcnow() - timedelta(days=CVE_BLOCK_TTL_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    blocked = []
    for cve_id in critical_cve_ids:
        try:
            resp = table.query(
                KeyConditionExpression="cve_id = :cid AND failed_at >= :cutoff",
                ExpressionAttributeValues={":cid": cve_id, ":cutoff": cutoff},
            )
            if resp.get("Items"):
                blocked.append(cve_id)
        except Exception as e:
            _log("WARN", "DynamoDB query failed", cve_id=cve_id, error=str(e))
    return blocked


def _create_prepatch_amis(instance_ids: List[str], patch_mode: str, create_ami: bool = True) -> dict:
    if not create_ami or not instance_ids:
        return {}
    timestamp = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    result = {}
    for instance_id in instance_ids:
        try:
            name = f"AI-Patch-{instance_id}-{timestamp}-{patch_mode}"
            resp = ec2.create_image(InstanceId=instance_id, Name=name, NoReboot=True)
            result[instance_id] = resp.get("ImageId", "")
        except Exception as e:
            _log("WARN", "AMI creation failed", instance_id=instance_id, error=str(e))
            result[instance_id] = ""
    return result


def _record_patch_execution(instance_ids: List[str], cve_ids: list, ssm_execution_id: str, patch_mode: str) -> None:
    if not PATCH_EXECUTIONS_TABLE:
        return
    table = dynamodb.Table(PATCH_EXECUTIONS_TABLE)
    now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    ttl = int((datetime.utcnow() + timedelta(days=AMI_RETENTION_DAYS + 7)).timestamp())
    for instance_id in instance_ids:
        try:
            table.put_item(
                Item={
                    "instance_id": instance_id,
                    "started_at": now,
                    "cve_ids": cve_ids or [],
                    "ssm_execution_id": ssm_execution_id,
                    "patch_mode": patch_mode,
                    "ttl": ttl,
                }
            )
        except Exception as e:
            _log("WARN", "DynamoDB put_item failed", instance_id=instance_id, error=str(e))


def _send_blocked_alert(blocked_cves: List[str]) -> None:
    if not PATCH_ALERTS_TOPIC_ARN or not blocked_cves:
        return
    try:
        sns.publish(
            TopicArn=PATCH_ALERTS_TOPIC_ARN,
            Subject="AIOps: CVE patching blocked (circuit-breaker)",
            Message=f"CVE(s) blocked—previous patch caused reboot failure: {', '.join(blocked_cves)}. Patching skipped.",
        )
    except Exception as e:
        _log("WARN", "SNS publish failed", error=str(e))


def _chunk_list(lst: List, size: int) -> List[List]:
    return [lst[i : i + size] for i in range(0, len(lst), size)]


def wait_for_command(command_id: str, instance_ids: List[str], timeout_sec: int = 600) -> dict:
    poll_interval = 5
    elapsed = 0
    while elapsed < timeout_sec:
        all_done = True
        outputs = []
        for instance_id in instance_ids:
            try:
                inv = ssm.get_command_invocation(CommandId=command_id, InstanceId=instance_id)
                status = inv.get("Status", "Pending")
                if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                    outputs.append({
                        "InstanceId": instance_id,
                        "Status": status,
                        "Output": inv.get("StandardOutputContent", ""),
                        "Error": inv.get("StandardErrorContent", ""),
                    })
                else:
                    all_done = False
            except ssm.exceptions.InvocationDoesNotExist:
                all_done = False
        if all_done and len(outputs) == len(instance_ids):
            return {"CommandId": command_id, "Invocations": outputs}
        time.sleep(poll_interval)
        elapsed += poll_interval
    return {"CommandId": command_id, "Status": "TimedOut", "Invocations": []}


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Runs SSM command and waits for completion.
    Supports dry_run (log only, no SSM), chunking (SSM_CHUNK_SIZE), structured logging, metrics.
    """
    execution_id = event.get("execution_id", context.aws_request_id if context else "")
    document_name = event.get("document_name")
    instance_ids = event.get("instance_ids", [])
    targets = event.get("targets")
    parameters = event.get("parameters", {})
    critical_cve_ids = event.get("critical_cve_ids", [])
    patch_mode = event.get("patch_mode", "unknown")
    dry_run = event.get("dry_run", False)
    create_ami = event.get("create_prepatch_ami", True)

    if not document_name:
        return {"statusCode": 400, "body": {"error": "document_name required"}}

    if isinstance(critical_cve_ids, str):
        try:
            critical_cve_ids = json.loads(critical_cve_ids) if critical_cve_ids.startswith("[") else []
        except json.JSONDecodeError:
            critical_cve_ids = []

    blocked = _check_blocked_cves(critical_cve_ids)
    if blocked:
        _send_blocked_alert(blocked)
        _put_metric("PatchBlocked", dimensions={"patch_mode": patch_mode})
        _log("INFO", "Patching blocked by circuit-breaker", execution_id=execution_id, blocked_cves=blocked)
        return {
            "statusCode": 200,
            "body": {
                "blocked": True,
                "blocked_cves": blocked,
                "message": "Patching skipped—CVE(s) blocked by circuit-breaker",
            },
        }

    if targets:
        instance_ids = targets[0].get("Values", []) if targets else []

    if not instance_ids:
        return {"statusCode": 400, "body": {"error": "instance_ids or targets required"}}

    if dry_run:
        _log("INFO", "Dry-run: would patch instances", execution_id=execution_id, instance_ids=instance_ids)
        _put_metric("PatchDryRun", value=len(instance_ids), dimensions={"patch_mode": patch_mode})
        return {
            "statusCode": 200,
            "body": {"dry_run": True, "instance_ids": instance_ids, "message": "Dry-run: no patches applied"},
        }

    _put_metric("PatchRunStarted", value=len(instance_ids), dimensions={"patch_mode": patch_mode})

    _create_prepatch_amis(instance_ids, patch_mode, create_ami=create_ami)

    formatted_params = {}
    for k, v in parameters.items():
        formatted_params[k] = [v] if isinstance(v, str) else v

    chunks = _chunk_list(instance_ids, SSM_CHUNK_SIZE)
    all_invocations = []
    command_ids = []

    for chunk in chunks:
        if targets:
            send_params = {
                "DocumentName": document_name,
                "Parameters": formatted_params,
                "Targets": [{"Key": "InstanceIds", "Values": chunk}],
            }
        elif document_name == "AWS-RunPatchBaseline":
            send_params = {
                "DocumentName": document_name,
                "Parameters": formatted_params,
                "Targets": [{"Key": "InstanceIds", "Values": chunk}],
            }
        else:
            send_params = {
                "DocumentName": document_name,
                "Parameters": formatted_params,
                "InstanceIds": chunk,
            }

        resp = ssm.send_command(**send_params)
        command_id = resp["Command"]["CommandId"]
        command_ids.append(command_id)
        _record_patch_execution(chunk, critical_cve_ids, command_id, patch_mode)
        result = wait_for_command(command_id, chunk)
        all_invocations.extend(result.get("Invocations", []))

    failed = sum(1 for inv in all_invocations if inv.get("Status") in ("Failed", "TimedOut", "Cancelled"))
    _put_metric("PatchRunCompleted", dimensions={"patch_mode": patch_mode})
    if failed > 0:
        _put_metric("InstancePatchFailed", value=failed, dimensions={"patch_mode": patch_mode})
    _put_metric("InstancePatched", value=len(all_invocations) - failed, dimensions={"patch_mode": patch_mode})

    _log("INFO", "Patch batch completed", execution_id=execution_id, total=len(all_invocations), failed=failed)

    return {"statusCode": 200, "body": {"CommandIds": command_ids, "Invocations": all_invocations}}
