# How Bedrock Knows About CVEs and What Decisions to Make

Bedrock doesn't have built-in access to your CVEs. It only sees what the CVE Analyzer Lambda sends in the prompt.

## How Bedrock Gets CVE Data

1. **Inspector Findings Lambda** pulls findings from Inspector (severity, CVE IDs, affected packages, descriptions).
2. **CVE Analyzer Lambda** receives those findings and builds a prompt that includes:
   - Instance IDs (RHEL8, Windows)
   - The findings JSON (severity, `cveIds`, `affectedPackages`, `description`)
   - Instructions for the model

## What the Prompt Tells the Model

From the CVE Analyzer Lambda:

```python
prompt = f"""You are a security operations expert. Analyze the following Amazon Inspector CVE findings for EC2 instances.

{context_str}

Provide a JSON response with exactly this structure (no other text):
{{"has_critical_cves": true or false, "summary": "brief summary", "recommendations": "detailed recommendations"}}

Rules:
- has_critical_cves: true if there are CRITICAL or HIGH severity findings, false if no findings or only LOW/MEDIUM
- summary: 1-2 sentences
- recommendations: patch prioritization, maintenance window, pre/post checklist (under 300 words)
"""
```

So the model is given:
- The CVE findings in the prompt
- A clear rule: `has_critical_cves: true` if CRITICAL or HIGH, `false` if no findings or only LOW/MEDIUM

## How the Model Uses This

- **CVE data**: Comes only from the prompt (Inspector findings).
- **Decision logic**: Comes from the rules in the prompt.
- **General knowledge**: The model understands CVE, severity levels, and security concepts from training, but it does not query a CVE database.

## Flow Summary

```
Inspector findings (severity, CVE IDs, packages)
    → CVE Analyzer Lambda builds prompt
    → Bedrock receives prompt with findings + rules
    → Bedrock returns JSON with has_critical_cves
    → Lambda parses response and returns to Step Functions
```

So Bedrock's decision is driven by the Inspector findings and the rules in the prompt, not by any internal CVE database.
