# AIOps R8: Cost Analysis

## DynamoDB Cost (Circuit-Breaker & Patch Tracking)

The project uses two DynamoDB tables: `cve-patch-failures` (blocked CVEs) and `patch-executions` (patch tracking). With 1000 nodes, the workflow is still **one execution per schedule** (e.g., monthly). Writes scale with instances patched per run.


| Factor                          | 4 nodes                | 1000 nodes                                  |
| ------------------------------- | ---------------------- | ------------------------------------------- |
| Executions/year                 | ~12                    | ~12                                         |
| Writes/run (patch_executions)   | ~4–8                   | ~1000–2000                                  |
| Writes/run (cve_patch_failures) | Rare (only on failure) | Rare                                        |
| Payload size                    | ~5 KB                  | ~10–20 KB (more findings, still summarized) |


DynamoDB cost: **~$1–10/year** on-demand for typical usage. Circuit-breaker tables use TTL for automatic cleanup.

---

## Overall Project Cost with 1000 Nodes

What scales with 1000 nodes:


| Component          | 4 nodes             | 1000 nodes             | Notes                                           |
| ------------------ | ------------------- | ---------------------- | ----------------------------------------------- |
| **EC2**            | ~$50–200/mo         | ~$12,500–50,000/mo     | Main cost driver; depends on instance type      |
| **Inspector**      | Free tier / minimal | ~$0.10/CVE finding     | More instances → more findings                  |
| **SSM**            | Minimal             | ~$0.005/instance/month | Run Command pricing                             |
| **Lambda**         | Negligible          | ~$2–10/mo              | 12 functions; EC2 stopped, AMI cleanup run daily |
| **Step Functions** | Negligible          | ~$1–2/mo               | Same state transitions                          |
| **DynamoDB**       | Negligible          | ~$1–5/year             | Circuit-breaker tables (on-demand)              |
| **SNS**            | Negligible          | ~$0.50/year            | Patch alerts (low volume)                       |
| **Bedrock**        | ~$0.01/run          | ~$0.01–0.05/run        | Similar prompt size (summarized)                |
| **EventBridge**    | Free                | Free                   | Same schedule                                   |


Rough order of magnitude for the **patch workflow** (excluding EC2):

- **4 nodes**: ~$5–20/month
- **1000 nodes**: ~$50–200/month (mostly Inspector findings + SSM)

---

## Summary


| What You're Asking About    | Cost with 1000 nodes               |
| --------------------------- | ---------------------------------- |
| **DynamoDB only**           | ~$1–5/year (almost unchanged)      |
| **Patch workflow (no EC2)** | ~$50–200/month                     |
| **EC2 + workflow**          | Dominated by EC2 (~$12K–50K/month) |


