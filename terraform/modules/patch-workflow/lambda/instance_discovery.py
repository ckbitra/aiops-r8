"""
Instance Discovery Lambda - Discovers EC2 instances by tags at runtime.
Supports dynamic fleets (ASG, manually added instances) and exclusion tags.
"""

import json
import os
import boto3
from typing import Any, Dict, List, Optional, Tuple

ec2 = boto3.client("ec2")

VPC_ID = os.environ.get("VPC_ID", "")
DISCOVERY_TAG_KEY = os.environ.get("DISCOVERY_TAG_KEY", "Role")
DISCOVERY_TAG_VALUE = os.environ.get("DISCOVERY_TAG_VALUE", "patch-target")
EXCLUSION_TAG_KEY = os.environ.get("EXCLUSION_TAG_KEY", "PatchExcluded")
EXCLUSION_TAG_VALUE = os.environ.get("EXCLUSION_TAG_VALUE", "true")
RHEL_TAG_KEY = os.environ.get("RHEL_TAG_KEY", "OS")
RHEL_TAG_VALUE = os.environ.get("RHEL_TAG_VALUE", "rhel8")
WINDOWS_TAG_KEY = os.environ.get("WINDOWS_TAG_KEY", "OS")
WINDOWS_TAG_VALUES = os.environ.get("WINDOWS_TAG_VALUES", "windows,windows2022").split(",")


def _log(level: str, msg: str, **kwargs: Any) -> None:
    """Structured JSON logging."""
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def discover_instances(
    vpc_id: str,
    discovery_tag: Tuple[str, str],
    exclusion_tag: Tuple[str, str],
    os_filters: Dict[str, List[str]],
) -> Dict[str, List[str]]:
    """
    Discover EC2 instances by tags. Returns {rhel8_ids: [...], windows_ids: [...]}.
    Excludes instances with exclusion tag.
    """
    filters = [
        {"Name": "instance-state-name", "Values": ["running"]},
        {"Name": "vpc-id", "Values": [vpc_id]},
        {"Name": f"tag:{discovery_tag[0]}", "Values": [discovery_tag[1]]},
    ]

    paginator = ec2.get_paginator("describe_instances")
    all_instances = []
    for page in paginator.paginate(Filters=filters):
        for res in page.get("Reservations", []):
            for inst in res.get("Instances", []):
                tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
                if tags.get(exclusion_tag[0]) == exclusion_tag[1]:
                    continue
                all_instances.append({"id": inst["InstanceId"], "tags": tags})

    rhel8_ids = []
    windows_ids = []
    for inst in all_instances:
        tags = inst["tags"]
        os_val = tags.get(RHEL_TAG_KEY, "").lower()
        if os_val == RHEL_TAG_VALUE.lower():
            rhel8_ids.append(inst["id"])
        elif any(os_val == v.strip().lower() for v in WINDOWS_TAG_VALUES):
            windows_ids.append(inst["id"])

    return {"rhel8_ids": rhel8_ids, "windows_ids": windows_ids}


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Discovers instances by tags. Falls back to static IDs if use_static=true.
    Expected: vpc_id, rhel8_ids (fallback), windows_ids (fallback), use_dynamic_discovery
    """
    vpc_id = event.get("vpc_id") or VPC_ID
    use_dynamic = event.get("use_dynamic_discovery", True)
    fallback_rhel = event.get("rhel8_ids", [])
    fallback_windows = event.get("windows_ids", [])

    if not vpc_id:
        return {"statusCode": 400, "body": {"error": "vpc_id required"}}

    if use_dynamic:
        try:
            result = discover_instances(
                vpc_id=vpc_id,
                discovery_tag=(DISCOVERY_TAG_KEY, DISCOVERY_TAG_VALUE),
                exclusion_tag=(EXCLUSION_TAG_KEY, EXCLUSION_TAG_VALUE),
                os_filters={},
            )
            rhel8_ids = result["rhel8_ids"]
            windows_ids = result["windows_ids"]
            _log("INFO", "Discovered instances", rhel8_count=len(rhel8_ids), windows_count=len(windows_ids))
        except Exception as e:
            _log("ERROR", "Discovery failed, using fallback", error=str(e))
            rhel8_ids = fallback_rhel
            windows_ids = fallback_windows
    else:
        rhel8_ids = fallback_rhel
        windows_ids = fallback_windows

    return {
        "statusCode": 200,
        "body": {
            "rhel8_ids": rhel8_ids,
            "windows_ids": windows_ids,
        },
    }
