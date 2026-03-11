# Guardrails for Patching RHEL 8 and Windows Hosts

> **See also:** [17_all_guardrails.md](17_all_guardrails.md) – Complete list with AWS Console and Terraform verification steps.

## Guardrails Already in This Project

### 1. Pre-Patch Checks

| Guardrail | RHEL 8 | Windows |
|-----------|--------|---------|
| **Circuit-breaker** | Yes – blocks patching if a CVE caused a prior reboot failure | Same |
| **CVE analysis** | Yes – Bedrock decides if critical CVEs need patching | Same |
| **Pre-patch AMI** | Yes – `create_prepatch_ami` (default: true) | Same |
| **Dry-run** | Yes – `dry_run=true` logs only, no patches | Same |

### 2. Execution Controls

| Guardrail | RHEL 8 | Windows |
|-----------|--------|---------|
| **Maintenance window** | Yes – `check_maintenance_window` (default: true) | Same |
| **Instance exclusion** | Tag `PatchExcluded=true` skips instance | Same |
| **SSM agent health** | Yes – filters out instances not in SSM Managed state (default: true) | Same |
| **Canary/phased rollout** | Yes – `canary_batch_size` patches first N instances before rest | Same |
| **Batched patching** | Yes – default batch size 10, sequential batches | Same |
| **Failure detection** | Yes – 180s wait after each batch, then Failure Check | Same |
| **Circuit-breaker on stop** | Yes – EC2 stopped → record CVE → block future runs | Same |

### 3. Platform-Specific

| Guardrail | RHEL 8 | Windows |
|-----------|--------|--------|
| **Patch scope** | `dnf update --security -y` (security only) | Patch baseline: SecurityUpdates, CriticalUpdates; `enable_non_security=false` |
| **Patch baseline** | N/A (shell command) | CVE-focused baseline, MSRC Critical/Important |
| **Patch group** | N/A | `PatchGroup=aiops-r8-windows-cve` required |
| **Reboot** | Implicit (kernel updates) | `RebootOption=RebootIfNeeded` |

---

## Recommended Guardrails (Beyond Current Setup)

### General (Both Platforms)

1. **Maintenance window** – ✅ Implemented. Default `check_maintenance_window=true`. Set `maintenance_start_hour_utc` / `maintenance_end_hour_utc` for low-traffic hours.
2. **Canary / phased rollout** – ✅ Implemented. Set `canary_batch_size` (e.g. 1–2) to patch a small subset first, then expand.
3. **SSM agent health** – ✅ Implemented. Default `check_ssm_agent_health=true`. Filters out instances not in SSM Managed state; sends SNS alert when instances are excluded.
4. **Backup / AMI** – Keep `create_prepatch_ami=true` for critical hosts.
5. **Alerting** – Subscribe to the patch-alerts SNS topic for circuit-breaker, SSM exclusion, and Step Functions workflow failure events. When `alert_email` is set, you receive emails for all three.
6. **Approval gates** – For high-risk environments, consider manual approval before patching (future enhancement).

### RHEL 8–Specific

1. **SSM agent** – RHEL AMIs often lack SSM agent; ensure `user_data` installs it (as in `ec2-rhel8`).
2. **Repository access** – Instances need outbound access to Red Hat repos (or internal mirrors) for `dnf update`.
3. **Kernel updates** – Expect reboots; the 180s wait + Failure Check helps detect boot failures.
4. **Locked packages** – If you use `dnf versionlock`, security updates may be blocked; consider excluding critical packages from locks.
5. **Alternative command** – For older RHEL, `yum update --security -y` is used as fallback.

### Windows-Specific

1. **Patch group** – Every Windows instance must have `PatchGroup=aiops-r8-windows-cve` or it won't be patched by the baseline.
2. **Reboot behavior** – `RebootIfNeeded` can reboot mid-batch; the 180s wait helps detect failures.
3. **WSUS vs Windows Update** – If using WSUS, ensure it's reachable and configured correctly.
4. **Pending reboots** – Instances with pending reboots may behave differently; consider a pre-check.
5. **Patch baseline scope** – Current baseline is CVE-focused; add other classifications only if needed.

---

## Quick Reference: Configurable Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `check_maintenance_window` | `true` | Enforce maintenance window |
| `maintenance_start_hour_utc` | `2` | Window start (UTC) |
| `maintenance_end_hour_utc` | `6` | Window end (UTC) |
| `check_ssm_agent_health` | `true` | Filter out instances not in SSM Managed state |
| `canary_batch_size` | `0` | First batch size for canary rollout (0 = disabled) |
| `dry_run` | `false` | Log only, no patches |
| `create_prepatch_ami` | `true` | Create AMIs before patching |
| `batch_size` | `10` | Instances per batch |
| `use_batched_patching` | `true` | Use batched patching with failure checks |
| `CVE_BLOCK_TTL_DAYS` | `7` | Days to block a CVE after failure |
| `EXCLUSION_TAG_KEY` | `PatchExcluded` | Tag key for exclusion |
| `EXCLUSION_TAG_VALUE` | `true` | Tag value for exclusion |

---

## Summary

The project provides strong guardrails: circuit-breaker, pre-patch AMIs, batched patching with failure detection, instance exclusion, maintenance window (enabled by default), SSM agent health pre-check, and canary/phased rollout. For production, validate network access per platform and ensure Windows instances have the correct `PatchGroup` tag.
