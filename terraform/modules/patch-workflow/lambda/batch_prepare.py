"""
Batch Prepare Lambda - Splits instance IDs into batches and prepares full patch context.
Outputs structure for both RHEL and Windows for batched patching flow.
"""

import json
from typing import Any, List


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def _prepare_platform_batches(
    instance_ids: List[str],
    batch_size: int,
    patch_mode: str,
    document_name: str,
    parameters: dict,
    critical_cve_ids: List[str],
    canary_batch_size: int = 0,
) -> dict:
    if not instance_ids:
        return {"batches": [], "total_batches": 0, "critical_cve_ids": critical_cve_ids, "patch_mode": patch_mode, "document_name": document_name, "parameters": parameters}
    if canary_batch_size > 0 and len(instance_ids) > canary_batch_size:
        first_batch = instance_ids[:canary_batch_size]
        remaining = instance_ids[canary_batch_size:]
        remaining_batches = [remaining[i : i + batch_size] for i in range(0, len(remaining), batch_size)]
        batches = [first_batch] + remaining_batches
    else:
        batches = [instance_ids[i : i + batch_size] for i in range(0, len(instance_ids), batch_size)]
    return {
        "batches": batches,
        "total_batches": len(batches),
        "critical_cve_ids": critical_cve_ids,
        "patch_mode": patch_mode,
        "document_name": document_name,
        "parameters": parameters,
    }


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Prepares batches for RHEL and Windows.
    Input: rhel8_ids, windows_ids, batch_size, critical_cve_ids
    Output: { rhel: {...}, windows: {...} }
    """
    rhel8_ids = event.get("rhel8_ids", [])
    windows_ids = event.get("windows_ids", [])
    batch_size = int(event.get("batch_size", 10))
    canary_batch_size = int(event.get("canary_batch_size", 0))
    critical_cve_ids = event.get("critical_cve_ids", [])
    if batch_size < 1:
        batch_size = 10

    rhel = _prepare_platform_batches(
        rhel8_ids, batch_size, "rhel", "AWS-RunShellScript",
        {"commands": ["sudo dnf update --security -y || sudo yum update --security -y"]},
        critical_cve_ids,
        canary_batch_size=canary_batch_size,
    )
    windows = _prepare_platform_batches(
        windows_ids, batch_size, "windows", "AWS-RunPatchBaseline",
        {"Operation": "Install", "RebootOption": "RebootIfNeeded"},
        critical_cve_ids,
        canary_batch_size=canary_batch_size,
    )

    _log("INFO", "Prepared batches", rhel_batches=rhel["total_batches"], windows_batches=windows["total_batches"])

    return {
        "statusCode": 200,
        "body": {"rhel": rhel, "windows": windows},
    }
