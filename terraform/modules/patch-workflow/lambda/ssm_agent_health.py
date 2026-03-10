"""
SSM Agent Health Lambda - Verifies instances are SSM-managed before patching.
Filters out instances not in Managed/Online state to avoid patch failures.
"""

import json
import os
import boto3
from typing import Any, List

ssm = boto3.client("ssm")
sns = boto3.client("sns")

PATCH_ALERTS_TOPIC_ARN = os.environ.get("PATCH_ALERTS_TOPIC_ARN", "")
CHECK_SSM_AGENT_HEALTH = os.environ.get("CHECK_SSM_AGENT_HEALTH", "true").lower() == "true"


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def _get_managed_instance_ids(instance_ids: List[str]) -> List[str]:
    """Return instance IDs that are in SSM Managed state (Online)."""
    if not instance_ids:
        return []
    try:
        paginator = ssm.get_paginator("describe_instance_information")
        managed = []
        for page in paginator.paginate():
            for info in page.get("InstanceInformationList", []):
                iid = info.get("InstanceId")
                if iid in instance_ids and info.get("PingStatus") == "Online":
                    managed.append(iid)
        return managed
    except Exception as e:
        _log("ERROR", "SSM describe_instance_information failed", error=str(e))
        return []


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Filters rhel8_ids and windows_ids to only include SSM-managed instances.
    Input: rhel8_ids, windows_ids
    Output: { rhel8_ids, windows_ids, excluded_rhel, excluded_windows }
    """
    if not CHECK_SSM_AGENT_HEALTH:
        rhel8_ids = event.get("rhel8_ids", [])
        windows_ids = event.get("windows_ids", [])
        return {
            "statusCode": 200,
            "body": {
                "rhel8_ids": rhel8_ids,
                "windows_ids": windows_ids,
                "excluded_rhel": [],
                "excluded_windows": [],
                "ssm_check_skipped": True,
            },
        }

    rhel8_ids = event.get("rhel8_ids", [])
    windows_ids = event.get("windows_ids", [])
    if isinstance(rhel8_ids, str):
        rhel8_ids = [rhel8_ids] if rhel8_ids else []
    if isinstance(windows_ids, str):
        windows_ids = [windows_ids] if windows_ids else []

    all_ids = list(rhel8_ids) + list(windows_ids)
    managed_ids = set(_get_managed_instance_ids(all_ids))

    managed_rhel = [i for i in rhel8_ids if i in managed_ids]
    managed_windows = [i for i in windows_ids if i in managed_ids]
    excluded_rhel = [i for i in rhel8_ids if i not in managed_ids]
    excluded_windows = [i for i in windows_ids if i not in managed_ids]

    if excluded_rhel or excluded_windows:
        _log(
            "WARN",
            "Excluded instances not SSM-managed",
            excluded_rhel=excluded_rhel,
            excluded_windows=excluded_windows,
        )
        if PATCH_ALERTS_TOPIC_ARN:
            try:
                sns.publish(
                    TopicArn=PATCH_ALERTS_TOPIC_ARN,
                    Subject="AIOps: Instances excluded (not SSM-managed)",
                    Message=(
                        f"Instances excluded from patching (not in SSM Managed state):\n"
                        f"RHEL: {excluded_rhel}\nWindows: {excluded_windows}"
                    ),
                )
            except Exception as e:
                _log("WARN", "SNS alert failed", error=str(e))

    return {
        "statusCode": 200,
        "body": {
            "rhel8_ids": managed_rhel,
            "windows_ids": managed_windows,
            "excluded_rhel": excluded_rhel,
            "excluded_windows": excluded_windows,
            "ssm_check_skipped": False,
        },
    }
