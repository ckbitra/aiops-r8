"""Unit tests for SSM Agent Health Lambda."""

import json
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "terraform/modules/patch-workflow/lambda"))
from ssm_agent_health import lambda_handler


@patch("ssm_agent_health.CHECK_SSM_AGENT_HEALTH", False)
def test_ssm_agent_health_skipped():
    """When CHECK_SSM_AGENT_HEALTH=false, passes through without filtering."""
    result = lambda_handler({"rhel8_ids": ["i-1"], "windows_ids": ["i-w1"]}, None)
    assert result["statusCode"] == 200
    body = result["body"]
    assert body["rhel8_ids"] == ["i-1"]
    assert body["windows_ids"] == ["i-w1"]
    assert body.get("ssm_check_skipped") is True


@patch("ssm_agent_health.CHECK_SSM_AGENT_HEALTH", True)
@patch("ssm_agent_health.ssm")
def test_ssm_agent_health_filters_managed(ssm_mock):
    """Filters to only instances in SSM Managed (Online) state."""
    def paginate(**kwargs):
        yield {
            "InstanceInformationList": [
                {"InstanceId": "i-1", "PingStatus": "Online"},
                {"InstanceId": "i-w1", "PingStatus": "Online"},
            ]
        }
    ssm_mock.get_paginator.return_value.paginate.side_effect = paginate
    result = lambda_handler({
        "rhel8_ids": ["i-1", "i-2"],
        "windows_ids": ["i-w1"],
    }, None)
    assert result["statusCode"] == 200
    body = result["body"]
    assert body["rhel8_ids"] == ["i-1"]
    assert body["windows_ids"] == ["i-w1"]
    assert body["excluded_rhel"] == ["i-2"]
    assert body["excluded_windows"] == []
    assert body.get("ssm_check_skipped") is False
