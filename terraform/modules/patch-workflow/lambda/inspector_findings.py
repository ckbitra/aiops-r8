"""
Inspector Findings Lambda - Fetches Amazon Inspector v2 CVE findings for EC2 instances.
Replaces SSM pre-patch scans with structured Inspector vulnerability data.
"""

import json
import os
import boto3
from typing import Any, List

inspector = boto3.client("inspector2")

MAX_RESULTS = int(os.environ.get("INSPECTOR_MAX_RESULTS", "500"))
FINDINGS_SUMMARY_LIMIT = int(os.environ.get("FINDINGS_SUMMARY_LIMIT", "100"))


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def get_findings_for_vpc(vpc_id: str, max_results: int = 500) -> List[dict]:
    """Fetch active Inspector findings for EC2 instances in the VPC with pagination."""
    all_findings = []
    next_token = None

    filter_criteria = {
        "findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}],
        "resourceType": [{"comparison": "EQUALS", "value": "AwsEc2Instance"}],
        "ec2InstanceVpcId": [{"comparison": "EQUALS", "value": vpc_id}],
    }

    while len(all_findings) < max_results:
        params = {
            "filterCriteria": filter_criteria,
            "maxResults": min(100, max_results - len(all_findings)),
        }
        if next_token:
            params["nextToken"] = next_token

        response = inspector.list_findings(**params)
        findings = response.get("findings", [])
        all_findings.extend(findings)

        next_token = response.get("nextToken")
        if not next_token or len(all_findings) >= max_results:
            break

    return all_findings[:max_results]


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Fetches Inspector findings for EC2 instances in the specified VPC.
    Expected event: vpc_id, rhel8_ids, windows_ids (optional, for context)
    """
    vpc_id = event.get("vpc_id")
    if not vpc_id:
        return {"statusCode": 400, "body": {"error": "vpc_id required"}}

    max_results = int(event.get("max_results", MAX_RESULTS))
    summary_limit = int(event.get("findings_summary_limit", FINDINGS_SUMMARY_LIMIT))

    try:
        findings = get_findings_for_vpc(vpc_id, max_results=max_results)

        summary = []
        for f in findings:
            pvd = f.get("packageVulnerabilityDetails") or {}
            severity = f.get("severity", "UNKNOWN")
            cve_ids = [v.get("id", "") for v in pvd.get("vulnerabilityIds", []) if v.get("id")]
            packages = [p.get("name", "") for p in pvd.get("vulnerablePackages", []) if p.get("name")]

            summary.append({
                "severity": severity,
                "cveIds": cve_ids[:5],
                "affectedPackages": packages[:5],
                "description": (f.get("description") or "")[:200],
            })

        summary = summary[:summary_limit]
        _log("INFO", "Fetched Inspector findings", findings_count=len(findings), summary_count=len(summary))

        return {
            "statusCode": 200,
            "body": {
                "findingsCount": len(findings),
                "findings": summary,
                "rawFindingsCount": len(findings),
            },
        }
    except Exception as e:
        _log("ERROR", "Inspector fetch failed", error=str(e))
        return {"statusCode": 500, "body": {"error": str(e), "findings": []}}
