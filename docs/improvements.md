# AIOps R8 Patching – Improvements (All Implemented)

This document describes the enhancements implemented in the AIOps R8 CVE patching workflow.

---

## 1. Circuit-Breaker: Halt Patching When CVE Causes Reboot Failure ✅ IMPLEMENTED

### Problem

If a CVE patch is applied and the node fails to reboot successfully, the project would continue patching other similar nodes with the same CVE. This can cause cascading failures—multiple nodes going offline instead of just one.

### Solution (Implemented)

The circuit-breaker is implemented with the following components:

| Component | Implementation |
|-----------|----------------|
| **Failure detection** | EventBridge rule `{project}-{env}-ec2-stopped-rule` listens for EC2 instance state `stopped` |
| **Failure store** | DynamoDB table `{project}-{env}-cve-patch-failures` (PK: cve_id, SK: failed_at) |
| **Patch tracking** | DynamoDB table `{project}-{env}-patch-executions` (PK: instance_id, SK: started_at) for correlation |
| **Pre-patch check** | Before SSM, SSM Runner Lambda queries the failure store for recent failures (within `CVE_BLOCK_TTL_DAYS`, default 7) |
| **Conditional execution** | If a failure is found, skip SSM patching and send SNS alert via `{project}-{env}-patch-alerts` topic |

### How It Works

1. **Patch execution tracking** – When SSM patching starts, SSM Runner Lambda records `instance_id`, `cve_ids`, `patch_mode`, `ssm_execution_id`, `started_at` in `patch_executions`.
2. **Failure detection** – When an EC2 instance transitions to `stopped`, EventBridge invokes the EC2 Stopped Handler Lambda. Lambda checks if that instance was patched recently (within `PATCH_CORRELATION_MINUTES`, default 45). If yes, it records the CVE(s) in `cve_patch_failures`.
3. **Pre-patch check** – Before starting SSM for a new patch, SSM Runner Lambda queries `cve_patch_failures` for each critical CVE. If any failure exists within the TTL, patching is skipped and an SNS alert is sent.
4. **Clearing the block** – Delete the failure record from `cve_patch_failures` for the CVE, or wait for TTL expiry (default 7 days).

### Configuration

| Environment Variable | Default | Purpose |
|---------------------|---------|---------|
| `PATCH_FAILURES_TABLE` | (from Terraform) | DynamoDB table for CVE failures |
| `PATCH_EXECUTIONS_TABLE` | (from Terraform) | DynamoDB table for patch tracking |
| `PATCH_ALERTS_TOPIC_ARN` | (from Terraform) | SNS topic for circuit-breaker alerts |
| `CVE_BLOCK_TTL_DAYS` | 7 | Days to block a CVE after a failure |
| `PATCH_CORRELATION_MINUTES` | 45 | Window to correlate instance stop with recent patch |

---

## 2. Automated Recovery from AMI When Patch Causes Boot Failure ✅ IMPLEMENTED

### Problem

When a patched node fails to reboot, recovery was manual. An engineer had to find the AMI and restore the node.

### Solution (Implemented)

| Component | Implementation |
|-----------|----------------|
| **Pre-patch AMI creation** | SSM Runner Lambda creates AMIs (`AI-Patch-{InstanceId}-{timestamp}-{patch_mode}`) before applying patches via EC2 `create_image` |
| **Failure detection** | Same EventBridge rule as circuit-breaker – EC2 instance state `stopped` |
| **AMI lookup** | EC2 Stopped Handler Lambda finds the most recent `AI-Patch-{InstanceId}-*` AMI |
| **Recovery action** | When `enable_auto_recovery=true`, Lambda launches a replacement instance from the AMI (same subnet, security groups, IAM profile) |

### Configuration

| Terraform Variable | Default | Purpose |
|--------------------|---------|---------|
| `enable_auto_recovery` | `false` | Set to `true` to enable automated recovery (launch replacement from AMI) |

### Considerations

- Recovery launches a new instance; load balancer, DNS, or ASG updates may need to be done manually or via additional automation
- Preserves subnet, security groups, and IAM instance profile when launching replacement

---

## 3. AMI Retention and Cleanup ✅ IMPLEMENTED

### Solution (Implemented)

| Component | Implementation |
|-----------|----------------|
| **Schedule** | EventBridge rule `{project}-{env}-ami-cleanup-schedule` – daily at 3:00 AM UTC |
| **Lambda** | `{project}-ami-cleanup` – finds AMIs with name prefix `AI-Patch-*` older than retention days |
| **Actions** | Deregisters AMIs and deletes associated EBS snapshots |

### Configuration

| Terraform Variable / Env | Default | Purpose |
|--------------------------|---------|---------|
| `ami_retention_days` | 7 | Days to retain pre-patch AMIs before cleanup |

---

## Summary

| Improvement | Priority | Effort | Status |
|-------------|----------|--------|--------|
| Circuit-breaker (halt patching on CVE failure) | High | Medium | ✅ Implemented |
| Automated recovery from AMI | Medium | High | ✅ Implemented (opt-in via `enable_auto_recovery`) |
| AMI retention and cleanup | Low | Low | ✅ Implemented |
