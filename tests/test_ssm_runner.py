"""Unit tests for SSM Runner Lambda logic."""

import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "terraform/modules/patch-workflow/lambda"))
from ssm_runner import _check_blocked_cves, _chunk_list


@patch.dict("os.environ", {"PATCH_FAILURES_TABLE": ""})
def test_check_blocked_cves_no_table():
    assert _check_blocked_cves(["CVE-2024-1234"]) == []


@patch.dict("os.environ", {"PATCH_FAILURES_TABLE": "test-table"})
@patch("ssm_runner.dynamodb")
def test_check_blocked_cves_empty(mock_dynamodb):
    mock_table = MagicMock()
    mock_table.query.return_value = {"Items": []}
    mock_dynamodb.Table.return_value = mock_table
    assert _check_blocked_cves(["CVE-2024-1234"]) == []


@patch("ssm_runner.PATCH_FAILURES_TABLE", "test-table")
@patch("ssm_runner.dynamodb")
def test_check_blocked_cves_blocked(mock_dynamodb):
    mock_table = MagicMock()
    mock_table.query.return_value = {"Items": [{"cve_id": "CVE-2024-1234"}]}
    mock_dynamodb.Table.return_value = mock_table
    assert _check_blocked_cves(["CVE-2024-1234"]) == ["CVE-2024-1234"]


def test_chunk_list():
    lst = ["a", "b", "c", "d", "e"]
    assert _chunk_list(lst, 2) == [["a", "b"], ["c", "d"], ["e"]]
    assert _chunk_list(lst, 5) == [["a", "b", "c", "d", "e"]]
    assert _chunk_list(lst, 10) == [["a", "b", "c", "d", "e"]]
    assert _chunk_list([], 5) == []
