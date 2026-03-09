"""Unit tests for CVE Analyzer Lambda logic."""

import json
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "terraform/modules/patch-workflow/lambda"))
from cve_analyzer import _extract_critical_cve_ids, _parse_bedrock_response


def test_extract_critical_cve_ids_empty():
    assert _extract_critical_cve_ids({}) == []
    assert _extract_critical_cve_ids(None) == []
    assert _extract_critical_cve_ids({"findings": []}) == []


def test_extract_critical_cve_ids_critical_high():
    findings = [
        {"severity": "CRITICAL", "cveIds": ["CVE-2024-1234"]},
        {"severity": "HIGH", "cveIds": ["CVE-2024-5678"]},
        {"severity": "LOW", "cveIds": ["CVE-2024-9999"]},
    ]
    result = _extract_critical_cve_ids({"findings": findings})
    assert set(result) == {"CVE-2024-1234", "CVE-2024-5678"}


def test_extract_critical_cve_ids_dedupe():
    findings = [
        {"severity": "CRITICAL", "cveIds": ["CVE-2024-1234"]},
        {"severity": "HIGH", "cveIds": ["CVE-2024-1234"]},
    ]
    result = _extract_critical_cve_ids({"findings": findings})
    assert result == ["CVE-2024-1234"]


def test_parse_bedrock_response_true():
    analysis = '{"has_critical_cves": true, "summary": "test"}'
    val, err = _parse_bedrock_response(analysis)
    assert val is True
    assert err is None


def test_parse_bedrock_response_false():
    analysis = '{"has_critical_cves": false, "summary": "test"}'
    val, err = _parse_bedrock_response(analysis)
    assert val is False
    assert err is None


def test_parse_bedrock_response_fallback_string():
    analysis = 'Some text "has_critical_cves": false more text'
    val, err = _parse_bedrock_response(analysis)
    assert val is False
    assert err is None


def test_parse_bedrock_response_empty_default_false():
    val, err = _parse_bedrock_response("")
    assert val is False
    assert err is not None


def test_parse_bedrock_response_invalid_default_false():
    val, err = _parse_bedrock_response("no json here")
    assert val is False
