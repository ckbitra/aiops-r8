"""
Maintenance Window Lambda - Checks if current time is within configured maintenance window.
"""

import json
import os
from datetime import datetime
from typing import Any

START_HOUR_UTC = int(os.environ.get("MAINTENANCE_START_HOUR_UTC", "2"))
END_HOUR_UTC = int(os.environ.get("MAINTENANCE_END_HOUR_UTC", "6"))
CHECK_MAINTENANCE_WINDOW = os.environ.get("CHECK_MAINTENANCE_WINDOW", "false").lower() == "true"


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Returns {within_window: true/false, current_hour: N}.
    If within_window is false, workflow should skip patching.
    """
    if not CHECK_MAINTENANCE_WINDOW:
        return {"statusCode": 200, "body": {"within_window": True, "current_hour": datetime.utcnow().hour}}

    current_hour = datetime.utcnow().hour
    start = START_HOUR_UTC
    end = END_HOUR_UTC

    if start <= end:
        within = start <= current_hour < end
    else:
        within = current_hour >= start or current_hour < end

    _log("INFO", "Maintenance window check", current_hour=current_hour, within_window=within)

    return {
        "statusCode": 200,
        "body": {
            "within_window": within,
            "current_hour": current_hour,
        },
    }
