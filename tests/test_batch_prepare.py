"""Unit tests for Batch Prepare Lambda."""

import json
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "terraform/modules/patch-workflow/lambda"))
from batch_prepare import lambda_handler


def test_batch_prepare_empty():
    result = lambda_handler({"rhel8_ids": [], "windows_ids": [], "critical_cve_ids": []}, None)
    assert result["statusCode"] == 200
    body = result["body"]
    assert body["rhel"]["total_batches"] == 0
    assert body["windows"]["total_batches"] == 0


def test_batch_prepare_splits():
    result = lambda_handler({
        "rhel8_ids": ["i-1", "i-2", "i-3", "i-4", "i-5"],
        "windows_ids": ["i-w1", "i-w2"],
        "critical_cve_ids": ["CVE-2024-1234"],
        "batch_size": 2,
    }, None)
    assert result["statusCode"] == 200
    body = result["body"]
    assert body["rhel"]["total_batches"] == 3
    assert len(body["rhel"]["batches"][0]) == 2
    assert body["windows"]["total_batches"] == 1


def test_batch_prepare_canary():
    """Canary: first batch uses canary_batch_size, remaining use batch_size."""
    result = lambda_handler({
        "rhel8_ids": ["i-1", "i-2", "i-3", "i-4", "i-5", "i-6", "i-7"],
        "windows_ids": [],
        "critical_cve_ids": ["CVE-2024-1234"],
        "batch_size": 3,
        "canary_batch_size": 2,
    }, None)
    assert result["statusCode"] == 200
    body = result["body"]
    # First batch: 2 (canary), then batches of 3: [i-3,i-4,i-5], [i-6,i-7]
    assert body["rhel"]["total_batches"] == 3
    assert len(body["rhel"]["batches"][0]) == 2
    assert len(body["rhel"]["batches"][1]) == 3
    assert len(body["rhel"]["batches"][2]) == 2
