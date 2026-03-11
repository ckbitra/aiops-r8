# AIOps R8 – Suggested Improvements

Recommendations for enhancing the project across reliability, scalability, observability, and operational flexibility.

---

## 1. Circuit-Breaker: Stop Within Same Run (High Priority) ✅ IMPLEMENTED

**Implementation:** Batched patching with mid-run failure detection.

- Step Functions Map state over batches (configurable `batch_size`, default 10)
- After each batch: PatchBatch → Wait 180s → CheckFailure Lambda
- If any recently patched instance is `stopped`, Choice → Fail → Parallel Catch → NotifyFailure
- RHEL and Windows each have their own batched Map (sequential batches per platform)

---

## 2. Scalability Limits ✅ IMPLEMENTED

- **Inspector:** `INSPECTOR_MAX_RESULTS` (default 500), `FINDINGS_SUMMARY_LIMIT` (default 100)
- **SSM:** Chunking via `SSM_CHUNK_SIZE` (default 50); multiple commands per batch
- **AMI creation:** Optional via `create_prepatch_ami`; fire-and-forget

| Previous limits (resolved) | Component | Limit | Impact |
|-----------|-------|--------|
| Inspector findings | `max_results=100` in `inspector_findings.py` | Large fleets may miss findings |
| Findings summary | `summary[:50]` – only first 50 findings to Bedrock | Bedrock may not see full picture |
| SSM Run Command | 50 targets per command (some documents) | 100 instances may need 2+ commands |
| AMI creation | Sequential in Lambda; EC2 rate limits | 100 AMIs could take minutes; possible throttling |

**Suggested improvements:**

- Make `max_results` configurable (env var or Terraform variable); add pagination for very large result sets.
- For SSM: split `instance_ids` into chunks of 50; send multiple commands; aggregate results.
- For AMI creation: consider async (fire-and-forget) with Step Functions Wait for “AMI ready” before patching, or accept that AMIs may still be pending when patching starts.

---

## 3. Dynamic Instance Discovery ✅ IMPLEMENTED

- **Instance Discovery Lambda:** Queries EC2 by tags (`Role=patch-target`, `OS=rhel8`/`windows`)
- **Exclusion:** Tag `PatchExcluded=true` excludes instances
- **Fallback:** When `use_dynamic_discovery=false`, uses static Terraform IDs

---

## 4. Bedrock Reliability and Parsing ✅ IMPLEMENTED

- **Default:** `has_critical_cves=False` on parse failure
- **Parsing:** JSON extraction via regex; fallback to string matching
- **Retry:** `BEDROCK_MAX_RETRIES` (default 3) with exponential backoff
- **Fallback:** Rule-based from Inspector (CRITICAL/HIGH) when Bedrock fails

---

## 5. Observability ✅ IMPLEMENTED

- **Structured logging:** JSON logs with `execution_id`, `instance_id`, `level`, `message` in Lambdas
- **Metrics:** PatchRunStarted, PatchRunCompleted, PatchBlocked (namespace AIOps/Patch)
- **SNS subscription:** Optional alert_email Terraform variable
- **Patch history:** DynamoDB table patch-history (structure in place)

- Optional: store patch run summary in DynamoDB or S3 for a simple “patch history” view.

---

## 6. Instance Exclusion and Maintenance Windows ✅ IMPLEMENTED

- **Exclusion:** Tag `PatchExcluded=true` (configurable) – Instance Discovery filters these out
- **Maintenance window:** `maintenance_start_hour_utc`, `maintenance_end_hour_utc`; `check_maintenance_window` (default: true)
- **SSM agent health:** `check_ssm_agent_health` (default: true) – filters out instances not in SSM Managed state
- **Canary rollout:** `canary_batch_size` – first batch patches fewer instances, then remaining batches
- **Dry-run:** `dry_run=true` – SSM Runner logs only, no patches applied

---

## 7. Testing ✅ IMPLEMENTED

- **Unit tests:** `tests/test_cve_analyzer.py`, `tests/test_ssm_runner.py`, `tests/test_batch_prepare.py`, `tests/test_ssm_agent_health.py`
- **CI/CD:** `.github/workflows/test.yml` – runs pytest on push/PR

---

## 8. Multi-Account and Multi-Region

**Current gap:** Single account, single region.

**Suggested improvements:**

- Inspector: use delegated administrator for multi-account scanning.
- Terraform: use workspaces or separate state per account/region.
- Step Functions: support cross-account Lambda invocation if needed.
- Document a multi-account deployment pattern.

---

## 9. Recovery Integration

**Current gap:** Auto-recovery launches a new instance but does not update ASG, load balancer, or DNS.

**Suggested improvements:**

- If instance is in an ASG: terminate the failed instance and let ASG replace it (optionally from the pre-patch AMI as launch template).
- If instance is in a target group: add logic to register the new instance.
- Make recovery behavior configurable (e.g., “launch only” vs “launch and register”).

---

## 10. Error Handling and Alerting

**Implemented:**

- **Step Functions failure notification** – EventBridge rule `aiops-r8-{env}-sfn-failure-rule` listens for Step Functions execution status FAILED, ABORTED, or TIMED_OUT. SFN Failure Notifier Lambda publishes to the patch-alerts SNS topic. When `alert_email` is set, operators receive an email with execution details, error, and cause.

**Remaining gaps:**

- Exceptions in Lambda are often caught and ignored (`except Exception: pass`).
- No dead-letter or fallback for failed Lambda invocations.

**Suggested improvements:**

- Replace silent `pass` with logging and, where appropriate, re-raise or return error status.
- Configure Lambda dead-letter queues (DLQ) for failed invocations.
- Add retry policies for transient failures (e.g., DynamoDB throttling).

---

## 11. Cost Optimization

**Current considerations:**

- Pre-patch AMIs for 100 instances: 100 EBS snapshots; cost scales with instance count and retention.
- Lambda: 12 functions; some run daily (AMI cleanup) or on every EC2 stop.

**Suggested improvements:**

- Make AMI creation optional (e.g., `create_prepatch_ami = false` for non-critical workloads).
- Option to create AMIs only for a subset (e.g., first batch in canary).
- Add cost allocation tags to all resources.
- Document cost implications for large fleets (e.g., 1000+ instances).

---

## 12. Security Hardening

**Suggested improvements:**

- Restrict IAM policies: avoid `Resource = "*"` where possible; scope to specific resources (e.g., VPC, instance IDs).
- Enable encryption for DynamoDB tables (AWS default; verify in Terraform).
- Consider VPC endpoints for Lambda (SSM, DynamoDB, etc.) to avoid internet egress.
- Secrets: use Secrets Manager for any sensitive config instead of env vars.

---

## Summary Matrix

| Improvement | Priority | Effort | Impact |
|-------------|----------|--------|--------|
| Batched patching (stop within run) | High | Medium | Prevents cascading failures in same run |
| Bedrock default to no-patch on error | High | Low | Reduces risk of over-patching |
| Dynamic instance discovery | Medium | Medium | Supports ASGs and changing fleets |
| Observability (metrics, structured logs) | Medium | Medium | Easier operations and debugging |
| Instance exclusion / dry-run | Medium | Low | More control over patching |
| Scalability (SSM chunks, Inspector pagination) | Medium | Medium | Supports large fleets |
| Unit tests | Medium | Medium | Safer changes |
| Error handling and alerting (SFN failure SNS) | Medium | Low | ✅ Implemented – SNS on workflow failure |
| Recovery (ASG/LB integration) | Low | High | Better automation |
| Multi-account support | Low | High | Enterprise deployment |
