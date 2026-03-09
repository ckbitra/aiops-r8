"""
Get Batch Lambda - Returns the batch at batch_index for batched patching loop.
"""

import json
from typing import Any


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Input: batches, batch_index, critical_cve_ids, patch_mode, document_name, parameters
    Output: instance_ids (for this batch), batch_index, total_batches, critical_cve_ids, ...
    """
    batches = event.get("batches", [])
    batch_index = int(event.get("batch_index", 0))
    critical_cve_ids = event.get("critical_cve_ids", [])
    patch_mode = event.get("patch_mode", "unknown")
    document_name = event.get("document_name", "")
    parameters = event.get("parameters", {})

    total_batches = len(batches)
    if batch_index >= total_batches or total_batches == 0:
        return {
            "statusCode": 200,
            "body": {
                "instance_ids": [],
                "batch_index": batch_index,
                "total_batches": total_batches,
                "done": True,
            },
        }

    instance_ids = batches[batch_index]
    _log("INFO", "Get batch", batch_index=batch_index, total_batches=total_batches, instance_count=len(instance_ids))

    return {
        "statusCode": 200,
        "body": {
            "instance_ids": instance_ids,
            "batch_index": batch_index,
            "total_batches": total_batches,
            "critical_cve_ids": critical_cve_ids,
            "patch_mode": patch_mode,
            "document_name": document_name,
            "parameters": parameters,
            "done": False,
        },
    }
