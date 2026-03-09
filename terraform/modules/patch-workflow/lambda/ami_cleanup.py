"""
AMI Cleanup Lambda - Deregisters pre-patch AMIs and deletes snapshots after retention period.
Runs daily via EventBridge. AMIs with name prefix AI-Patch-* older than AMI_RETENTION_DAYS are removed.
"""

import os
import boto3
from datetime import datetime, timedelta
from typing import Any

ec2 = boto3.client("ec2")

AMI_RETENTION_DAYS = int(os.environ.get("AMI_RETENTION_DAYS", "7"))
AMI_NAME_PREFIX = os.environ.get("AMI_NAME_PREFIX", "AI-Patch-")


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Finds AMIs with AI-Patch-* prefix older than retention days,
    deregisters them and deletes associated snapshots.
    """
    cutoff = datetime.utcnow() - timedelta(days=AMI_RETENTION_DAYS)
    cutoff_str = cutoff.strftime("%Y-%m-%d")

    try:
        images = ec2.describe_images(
            Owners=["self"],
            Filters=[
                {"Name": "name", "Values": [f"{AMI_NAME_PREFIX}*"]},
                {"Name": "state", "Values": ["available"]},
            ],
        )
    except Exception as e:
        return {"statusCode": 500, "body": {"error": str(e), "deregistered": 0}}

    deregistered = 0
    errors = []

    for img in images.get("Images", []):
        created = img.get("CreationDate", "")[:10]
        if created < cutoff_str:
            ami_id = img["ImageId"]
            try:
                # Get snapshot IDs before deregistering
                snapshot_ids = []
                for bdm in img.get("BlockDeviceMappings", []):
                    ebs = bdm.get("Ebs", {})
                    if ebs.get("SnapshotId"):
                        snapshot_ids.append(ebs["SnapshotId"])

                ec2.deregister_image(ImageId=ami_id)
                deregistered += 1

                for snap_id in snapshot_ids:
                    try:
                        ec2.delete_snapshot(SnapshotId=snap_id)
                    except Exception as snap_err:
                        errors.append(f"Snapshot {snap_id}: {str(snap_err)}")
            except Exception as e:
                errors.append(f"AMI {ami_id}: {str(e)}")

    return {
        "statusCode": 200,
        "body": {
            "deregistered": deregistered,
            "errors": errors[:10],
        },
    }
