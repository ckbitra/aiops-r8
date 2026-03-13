"""
Inspector Findings Lambda - Fetches Amazon Inspector v2 CVE findings for EC2 instances.
Replaces SSM pre-patch scans with structured Inspector vulnerability data.
"""

import json
import os
import boto3
from typing import Any, List

inspector = boto3.client("inspector2")
sts = boto3.client("sts")

MAX_RESULTS = int(os.environ.get("INSPECTOR_MAX_RESULTS", "500"))
FINDINGS_SUMMARY_LIMIT = int(os.environ.get("FINDINGS_SUMMARY_LIMIT", "100"))


def _log(level: str, msg: str, **kwargs: Any) -> None:
    record = {"level": level, "message": msg, **kwargs}
    print(json.dumps(record, default=str))


def _get_findings_with_filter(filter_criteria: dict, max_results: int = 500) -> List[dict]:
    """Fetch Inspector findings with given filter criteria."""
    all_findings = []
    next_token = None

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


def get_findings_for_vpc(vpc_id: str, max_results: int = 500) -> List[dict]:
    """Fetch active Inspector findings for EC2 instances in the VPC with pagination."""
    # Try both resourceType values (Inspector API may use AWS_EC2_INSTANCE or AwsEc2Instance)
    for resource_type in ("AWS_EC2_INSTANCE", "AwsEc2Instance"):
        filter_criteria = {
            "findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}],
            "resourceType": [{"comparison": "EQUALS", "value": resource_type}],
            "ec2InstanceVpcId": [{"comparison": "EQUALS", "value": vpc_id}],
        }
        findings = _get_findings_with_filter(filter_criteria, max_results)
        if findings:
            return findings
    return []


def get_findings_for_instances(instance_ids: List[str], max_results: int = 500) -> List[dict]:
    """Fetch findings for specific EC2 instances (fallback when VPC filter returns 0)."""
    if not instance_ids:
        return []

    try:
        account_id = sts.get_caller_identity()["Account"]
        region = boto3.session.Session().region_name or "us-east-2"
    except Exception:
        return []

    # Build resourceId filters - Inspector uses full instance ARN
    resource_filters = [
        {"comparison": "EQUALS", "value": f"arn:aws:ec2:{region}:{account_id}:instance/{iid}"}
        for iid in instance_ids[:10]  # API allows max 10 per filter
    ]
    if not resource_filters:
        return []

    for resource_type in ("AWS_EC2_INSTANCE", "AwsEc2Instance"):
        filter_criteria = {
            "findingStatus": [{"comparison": "EQUALS", "value": "ACTIVE"}],
            "resourceType": [{"comparison": "EQUALS", "value": resource_type}],
            "resourceId": resource_filters,
        }
        findings = _get_findings_with_filter(filter_criteria, max_results)
        if findings:
            return findings
    return []


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Fetches Inspector findings for EC2 instances in the specified VPC.
    Falls back to instance-based filter when VPC filter returns 0 (Inspector may
    associate findings with instance ARN rather than VPC in some cases).
    Expected event: vpc_id, rhel8_ids, windows_ids (optional, for context)
    """
    vpc_id = event.get("vpc_id")
    if not vpc_id:
        return {"statusCode": 400, "body": {"error": "vpc_id required"}}

    rhel8_ids = event.get("rhel8_ids") or []
    windows_ids = event.get("windows_ids") or []
    if isinstance(rhel8_ids, str):
        rhel8_ids = [rhel8_ids] if rhel8_ids else []
    if isinstance(windows_ids, str):
        windows_ids = [windows_ids] if windows_ids else []
    all_instance_ids = list(rhel8_ids) + list(windows_ids)

    max_results = int(event.get("max_results", MAX_RESULTS))
    summary_limit = int(event.get("findings_summary_limit", FINDINGS_SUMMARY_LIMIT))

    try:
        findings = get_findings_for_vpc(vpc_id, max_results=max_results)
        _log("INFO", "VPC filter result", vpc_id=vpc_id, findings_count=len(findings))

        # Fallback: if VPC filter returns 0 but we have instances, try instance-based filter
        if len(findings) == 0 and all_instance_ids:
            _log("INFO", "VPC filter returned 0, trying instance-based filter", instance_count=len(all_instance_ids))
            findings = get_findings_for_instances(all_instance_ids, max_results=max_results)
            _log("INFO", "Instance filter result", findings_count=len(findings))

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
