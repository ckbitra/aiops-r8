"""
CVE Analyzer Lambda - Uses Amazon Bedrock to analyze CVE findings
and recommend patch actions. Production-safe: only CVE-related patches.
Receives Amazon Inspector findings and sends to Bedrock.
Uses Converse API for compatibility with Claude, Titan, and other models.
"""

import json
import re
import time
import boto3
import os
from typing import Any, Optional, Tuple

bedrock = boto3.client("bedrock-runtime")
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.amazon.nova-2-lite-v1:0")
BEDROCK_MAX_RETRIES = int(os.environ.get("BEDROCK_MAX_RETRIES", "3"))


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def _extract_critical_cve_ids(inspector_result: dict) -> list:
    """Extract CVE IDs from CRITICAL and HIGH severity findings for circuit-breaker."""
    if not inspector_result:
        return []
    findings = inspector_result.get("findings", [])
    if isinstance(findings, str):
        return []
    cve_ids = []
    for f in findings:
        severity = (f.get("severity") or "").upper()
        if severity in ("CRITICAL", "HIGH"):
            ids = f.get("cveIds", [])
            if isinstance(ids, str):
                ids = [ids] if ids else []
            cve_ids.extend(ids)
    return list(set(c for c in cve_ids if c))


def _parse_bedrock_response(analysis: str) -> Tuple[bool, Optional[str]]:
    """
    Parse has_critical_cves from Bedrock response using JSON extraction.
    Returns (has_critical_cves, error_message). Default: (False, None) on parse failure.
    """
    if not analysis or not isinstance(analysis, str):
        return False, "Empty or invalid response"

    # Try to extract JSON block (may be wrapped in markdown or text)
    for match in re.finditer(r"\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", analysis):
        try:
            parsed = json.loads(match.group())
            val = parsed.get("has_critical_cves")
            if isinstance(val, bool):
                return val, None
        except json.JSONDecodeError:
            continue

    # Fallback: string matching (less reliable)
    alower = analysis.lower()
    if '"has_critical_cves":false' in alower or '"has_critical_cves": false' in alower:
        return False, None
    if '"has_critical_cves":true' in alower or '"has_critical_cves": true' in alower:
        return True, None

    return False, "Could not parse has_critical_cves from response"


def extract_inspector_context(inspector_result: dict) -> str:
    """Extract CVE context from Inspector findings result."""
    if not inspector_result:
        return "No Inspector findings"
    if isinstance(inspector_result, str):
        return inspector_result
    findings = inspector_result.get("findings", [])
    findings_count = inspector_result.get("findingsCount", len(findings))
    if not findings:
        return f"No active CVE findings (count: {findings_count})"
    return json.dumps({"findingsCount": findings_count, "findings": findings}, default=str)[:8000]


def invoke_bedrock(prompt: str, max_tokens: int = 2048) -> str:
    """Invoke Bedrock with retry and exponential backoff."""
    last_error = None
    for attempt in range(BEDROCK_MAX_RETRIES):
        try:
            response = bedrock.converse(
                modelId=MODEL_ID,
                messages=[{"role": "user", "content": [{"text": prompt}]}],
                inferenceConfig={"maxTokens": max_tokens, "temperature": 0.3},
            )
            content = response["output"]["message"]["content"]
            return content[0]["text"] if content else ""
        except Exception as e:
            last_error = e
            _log("WARN", "Bedrock invoke failed", attempt=attempt + 1, error=str(e))
            if attempt < BEDROCK_MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
    raise last_error


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Lambda handler for CVE analysis workflow.
    Defaults to has_critical_cves=False on parse failure or Bedrock error (safe: do not patch).
    """
    action = event.get("action", "analyze")

    if action == "analyze":
        inspector_findings = event.get("inspector_findings", {})
        rhel8_ids = event.get("rhel8_ids", [])
        windows_ids = event.get("windows_ids", [])

        # Fallback: rule-based from Inspector (CRITICAL/HIGH)
        critical_cve_ids = _extract_critical_cve_ids(inspector_findings)
        rule_based_has_critical = len(critical_cve_ids) > 0

        context_str = extract_inspector_context(inspector_findings)
        prompt = f"""You are a security operations expert. Analyze the following Amazon Inspector CVE findings for EC2 instances.

Amazon Inspector CVE Findings (EC2 instances in VPC):
RHEL8 instances: {rhel8_ids}
Windows instances: {windows_ids}

{context_str}

Provide a JSON response with exactly this structure (no other text):
{{"has_critical_cves": true or false, "summary": "brief summary", "recommendations": "detailed recommendations"}}

Rules:
- has_critical_cves: true if there are CRITICAL or HIGH severity findings, false if no findings or only LOW/MEDIUM
- summary: 1-2 sentences
- recommendations: patch prioritization, maintenance window, pre/post checklist (under 300 words)
"""

        try:
            analysis = invoke_bedrock(prompt, max_tokens=1024)
            has_critical_cves, parse_error = _parse_bedrock_response(analysis)
            if parse_error:
                _log("WARN", "Bedrock parse fallback to rule-based", parse_error=parse_error)
                has_critical_cves = rule_based_has_critical
        except Exception as e:
            _log("ERROR", "Bedrock failed, using rule-based fallback", error=str(e))
            has_critical_cves = rule_based_has_critical
            analysis = f"Fallback: {str(e)}"

        return {
            "statusCode": 200,
            "body": {
                "action": "analyze",
                "bedrock_analysis": analysis,
                "has_critical_cves": has_critical_cves,
                "critical_cve_ids": critical_cve_ids if has_critical_cves else [],
                "recommendation": "Apply CVE patches" if has_critical_cves else "No critical CVEs - skip patching",
            },
        }

    return {"statusCode": 400, "body": {"error": f"Unknown action: {action}"}}
