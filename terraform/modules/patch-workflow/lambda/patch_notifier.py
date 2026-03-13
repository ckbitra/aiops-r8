"""
Patch Notifier Lambda - Sends SNS emails when patching starts and completes.
Uses the same patch-alerts topic (and email subscription) as failure alerts.
"""

import json
import os
from datetime import datetime
from typing import Any, List

import boto3

sns = boto3.client("sns")

PATCH_ALERTS_TOPIC_ARN = os.environ.get("PATCH_ALERTS_TOPIC_ARN", "")


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def _safe_get(obj: Any, *keys: str, default: Any = "") -> Any:
    """Safely traverse nested dict/object."""
    for key in keys:
        if obj is None:
            return default
        if isinstance(obj, dict):
            obj = obj.get(key)
        else:
            return default
    return obj if obj is not None else default


def _format_started_message(event: dict) -> tuple[str, str]:
    """Format subject and message for 'patching started' notification."""
    batches = event.get("batches", {})
    rhel = batches.get("rhel", {})
    windows = batches.get("windows", {})

    rhel_ids = rhel.get("batches", [])
    windows_ids = windows.get("batches", [])
    rhel_count = sum(len(b) for b in rhel_ids)
    windows_count = sum(len(b) for b in windows_ids)
    critical_cve_ids = rhel.get("critical_cve_ids", []) or windows.get("critical_cve_ids", [])

    subject = "AIOps: Patch workflow STARTED"
    message = (
        f"The AIOps R8 patch workflow has started.\n\n"
        f"Started at: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}\n\n"
        f"Target instances:\n"
        f"  - RHEL: {rhel_count} instance(s) in {len(rhel_ids)} batch(es)\n"
        f"  - Windows: {windows_count} instance(s) in {len(windows_ids)} batch(es)\n\n"
    )
    if critical_cve_ids:
        message += f"Critical CVEs to address: {', '.join(critical_cve_ids[:10])}\n"
        if len(critical_cve_ids) > 10:
            message += f"  ... and {len(critical_cve_ids) - 10} more\n"
    return subject, message


def _format_completed_message(event: dict) -> tuple[str, str]:
    """Format subject and message for 'patching completed' notification with final report."""
    # Get instance IDs from batches (what we actually patched) or discoveredInstances
    batches = event.get("batches", {})
    batches_body = _safe_get(batches, "Payload", "body") or batches
    rhel_data = batches_body.get("rhel", {})
    windows_data = batches_body.get("windows", {})
    rhel_batches = rhel_data.get("batches", [])
    windows_batches = windows_data.get("batches", [])
    rhel8_ids = [iid for batch in rhel_batches for iid in (batch if isinstance(batch, list) else [batch])]
    windows_ids = [iid for batch in windows_batches for iid in (batch if isinstance(batch, list) else [batch])]

    analyze = event.get("analyzeResult", {})
    analyze_body = _safe_get(analyze, "Payload", "body") or analyze
    critical_cve_ids = analyze_body.get("critical_cve_ids", [])

    # Workflow reached completion = all discovered instances were patched
    rhel_count = len(rhel8_ids)
    windows_count = len(windows_ids)

    subject = "AIOps: Patch workflow COMPLETED - Final Report"
    message = (
        f"The AIOps R8 patch workflow has completed successfully.\n\n"
        f"Completed at: {datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')}\n\n"
        f"=== Final Report ===\n\n"
        f"Patching Summary:\n"
        f"  - RHEL instances patched: {rhel_count}\n"
        f"  - Windows instances patched: {windows_count}\n"
        f"  - Total instances: {rhel_count + windows_count}\n\n"
    )
    if critical_cve_ids:
        message += f"CVEs addressed: {', '.join(critical_cve_ids[:15])}\n"
        if len(critical_cve_ids) > 15:
            message += f"  ... and {len(critical_cve_ids) - 15} more\n"
        message += "\n"

    rhel_list = ", ".join(rhel8_ids[:5]) if rhel8_ids else "None"
    if len(rhel8_ids) > 5:
        rhel_list += f" (+{len(rhel8_ids) - 5} more)"
    message += f"RHEL instances: {rhel_list}\n\n"

    win_list = ", ".join(windows_ids[:5]) if windows_ids else "None"
    if len(windows_ids) > 5:
        win_list += f" (+{len(windows_ids) - 5} more)"
    message += f"Windows instances: {win_list}\n\n"

    message += "Post-patch verification has been run on all instances.\n"

    return subject, message


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Sends SNS notification when patching starts or completes.
    action: 'started' | 'completed'
    """
    if not PATCH_ALERTS_TOPIC_ARN:
        _log("WARN", "PATCH_ALERTS_TOPIC_ARN not set, skipping SNS publish")
        return {"statusCode": 200, "body": {"skipped": True, "reason": "no_topic"}}

    try:
        action = event.get("action", "")
        if action == "started":
            subject, message = _format_started_message(event)
        elif action == "completed":
            subject, message = _format_completed_message(event)
        else:
            _log("WARN", "Unknown action, skipping", action=action)
            return {"statusCode": 200, "body": {"skipped": True, "reason": "unknown_action"}}

        sns.publish(
            TopicArn=PATCH_ALERTS_TOPIC_ARN,
            Subject=subject,
            Message=message,
        )
        _log("INFO", "SNS notification sent", action=action)
        return {"statusCode": 200, "body": {"published": True, "action": action}}

    except Exception as e:
        _log("ERROR", "Failed to publish SNS notification", error=str(e))
        raise
