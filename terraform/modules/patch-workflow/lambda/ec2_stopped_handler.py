"""
EC2 Stopped Handler Lambda - Circuit-breaker failure detection.
When an EC2 instance transitions to stopped, check if it was recently patched.
If yes, record the CVE(s) in cve_patch_failures to block future patches.
Optionally trigger automated recovery from pre-patch AMI.
"""

import os
import boto3
from datetime import datetime, timedelta
from typing import Any, Optional

dynamodb = boto3.resource("dynamodb")
ec2 = boto3.client("ec2")

PATCH_FAILURES_TABLE = os.environ.get("PATCH_FAILURES_TABLE", "")
PATCH_EXECUTIONS_TABLE = os.environ.get("PATCH_EXECUTIONS_TABLE", "")
PATCH_CORRELATION_MINUTES = int(os.environ.get("PATCH_CORRELATION_MINUTES", "45"))
ENABLE_AUTO_RECOVERY = os.environ.get("ENABLE_AUTO_RECOVERY", "false").lower() == "true"


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Handles EC2 instance state change (stopped).
    Checks if instance was recently patched; if so, records CVE(s) in failure store.
    """
    instance_id = event.get("detail", {}).get("instance-id")
    if not instance_id:
        return {"status": "skipped", "reason": "no instance-id"}

    failures_table = dynamodb.Table(PATCH_FAILURES_TABLE)
    executions_table = dynamodb.Table(PATCH_EXECUTIONS_TABLE)

    # Query patch_executions for this instance within correlation window
    cutoff = (datetime.utcnow() - timedelta(minutes=PATCH_CORRELATION_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        response = executions_table.query(
            KeyConditionExpression="instance_id = :iid AND started_at >= :cutoff",
            ExpressionAttributeValues={":iid": instance_id, ":cutoff": cutoff},
        )
    except Exception as e:
        return {"status": "error", "error": str(e)}

    items = response.get("Items", [])
    if not items:
        return {"status": "skipped", "reason": "no recent patch execution"}

    # Record each CVE from the patch execution(s) in cve_patch_failures
    now = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    ttl = int((datetime.utcnow() + timedelta(days=7)).timestamp())

    for item in items:
        cve_ids = item.get("cve_ids", [])
        if isinstance(cve_ids, str):
            cve_ids = [cve_ids] if cve_ids else []
        for cve_id in cve_ids:
            if cve_id:
                try:
                    failures_table.put_item(
                        Item={
                            "cve_id": cve_id,
                            "failed_at": now,
                            "instance_id": instance_id,
                            "ttl": ttl,
                        }
                    )
                except Exception as e:
                    return {"status": "partial_error", "error": str(e)}

    all_cve_ids = []
    for item in items:
        cids = item.get("cve_ids", [])
        if isinstance(cids, str):
            cids = [cids] if cids else []
        all_cve_ids.extend(cids)
    result = {"status": "recorded", "instance_id": instance_id, "cve_ids": list(set(all_cve_ids))}

    # Optional: trigger recovery (launch replacement from AMI)
    if ENABLE_AUTO_RECOVERY and items:
        ami_id = _find_prepatch_ami(instance_id, items)
        if ami_id:
            try:
                _launch_recovery_instance(instance_id, ami_id)
                result["recovery_launched"] = True
            except Exception as e:
                result["recovery_error"] = str(e)

    return result


def _find_prepatch_ami(instance_id: str, patch_items: list) -> Optional[str]:
    """Find the most recent AI-Patch-{InstanceId}-* AMI."""
    # Get instance details for subnet, security group, etc.
    try:
        desc = ec2.describe_instances(InstanceIds=[instance_id])
        instances = desc.get("Reservations", [{}])[0].get("Instances", [])
        if not instances:
            return None
        inst = instances[0]
        subnet_id = inst.get("SubnetId")
        sg_ids = [sg["GroupId"] for sg in inst.get("SecurityGroups", [])]
    except Exception:
        return None

    # Find AMIs with name AI-Patch-{instance_id}-*
    try:
        images = ec2.describe_images(
            Owners=["self"],
            Filters=[
                {"Name": "name", "Values": [f"AI-Patch-{instance_id}-*"]},
                {"Name": "state", "Values": ["available"]},
            ],
        )
        amis = sorted(images.get("Images", []), key=lambda x: x.get("CreationDate", ""), reverse=True)
        return amis[0]["ImageId"] if amis else None
    except Exception:
        return None


def _launch_recovery_instance(original_instance_id: str, ami_id: str) -> str:
    """Launch a replacement instance from the pre-patch AMI."""
    desc = ec2.describe_instances(InstanceIds=[original_instance_id])
    inst = desc.get("Reservations", [{}])[0].get("Instances", [{}])[0]
    if not inst:
        raise ValueError("Instance not found")

    subnet_id = inst.get("SubnetId")
    sg_ids = [sg["GroupId"] for sg in inst.get("SecurityGroups", [])]
    if not subnet_id or not sg_ids:
        raise ValueError("Cannot recover: missing subnet or security groups")

    run_params = {
        "ImageId": ami_id,
        "InstanceType": inst.get("InstanceType", "t3.micro"),
        "MinCount": 1,
        "MaxCount": 1,
        "SubnetId": subnet_id,
        "SecurityGroupIds": sg_ids,
        "TagSpecifications": [
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Name", "Value": f"{original_instance_id}-recovery"},
                    {"Key": "RecoveredFrom", "Value": original_instance_id},
                ],
            }
        ],
    }
    if inst.get("IamInstanceProfile", {}).get("Arn"):
        run_params["IamInstanceProfile"] = {"Arn": inst["IamInstanceProfile"]["Arn"]}

    resp = ec2.run_instances(**run_params)
    return resp["Instances"][0]["InstanceId"]
