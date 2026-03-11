"""Unit tests for SFN Failure Notifier Lambda."""

import json
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "terraform/modules/patch-workflow/lambda"))
from sfn_failure_notifier import lambda_handler


@patch("sfn_failure_notifier.PATCH_ALERTS_TOPIC_ARN", "")
def test_sfn_failure_notifier_no_topic():
    """When PATCH_ALERTS_TOPIC_ARN is empty, skips publish."""
    event = {
        "detail": {
            "status": "FAILED",
            "executionArn": "arn:aws:states:us-east-2:123:execution:aiops-r8-patch-workflow:run-1",
            "name": "run-1",
            "cause": "Test cause",
        }
    }
    result = lambda_handler(event, None)
    assert result["statusCode"] == 200
    assert result["body"].get("skipped") is True


@patch("sfn_failure_notifier.PATCH_ALERTS_TOPIC_ARN", "arn:aws:sns:us-east-2:123:patch-alerts")
@patch("sfn_failure_notifier.sns")
def test_sfn_failure_notifier_publishes_on_failure(sns_mock):
    """When status is FAILED, publishes to SNS."""
    event = {
        "detail": {
            "status": "FAILED",
            "executionArn": "arn:aws:states:us-east-2:123:execution:aiops-r8-patch-workflow:run-1",
            "stateMachineArn": "arn:aws:states:us-east-2:123:stateMachine:aiops-r8-patch-workflow",
            "name": "run-1",
            "cause": "CircuitBreakerTriggered",
            "error": "Instance stopped after patch",
            "startDate": "2024-01-15T02:00:00Z",
            "stopDate": "2024-01-15T02:05:00Z",
        }
    }
    result = lambda_handler(event, None)
    assert result["statusCode"] == 200
    assert result["body"].get("published") is True
    sns_mock.publish.assert_called_once()
    call_kwargs = sns_mock.publish.call_args[1]
    assert "AIOps: Patch workflow FAILED" in call_kwargs["Subject"]
    assert "run-1" in call_kwargs["Message"]
    assert "CircuitBreakerTriggered" in call_kwargs["Message"]


@patch("sfn_failure_notifier.PATCH_ALERTS_TOPIC_ARN", "arn:aws:sns:us-east-2:123:patch-alerts")
@patch("sfn_failure_notifier.sns")
def test_sfn_failure_notifier_ignores_success(sns_mock):
    """When status is SUCCEEDED, does not publish."""
    event = {
        "detail": {
            "status": "SUCCEEDED",
            "name": "run-1",
        }
    }
    result = lambda_handler(event, None)
    assert result["statusCode"] == 200
    assert result["body"].get("skipped") is True
    assert result["body"].get("status") == "SUCCEEDED"
    sns_mock.publish.assert_not_called()
