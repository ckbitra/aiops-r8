# Bedrock vs. Systems Manager in the Patching Process

## Overview

This document explains the benefits of using Bedrock (LLM) in the patching process compared to using Systems Manager alone.

## Systems Manager Alone

- **Deterministic**: Runs predefined commands (e.g., `dnf update --security`, Patch Baseline)
- **No interpretation**: Executes patches but doesn't understand CVE context or risk
- **Fixed logic**: Same behavior regardless of environment or business impact
- **Limited prioritization**: Applies patches in a fixed order (e.g., by severity)

## What Bedrock Adds

| Benefit | Description |
|---------|-------------|
| **Context-aware analysis** | Interprets scan output and CVE descriptions instead of treating them as raw text |
| **Prioritization** | Recommends which CVEs to patch first based on severity, exploitability, and environment |
| **Risk assessment** | Explains impact and trade-offs (e.g., reboot, compatibility) in natural language |
| **Adaptive recommendations** | Can adjust guidance for dev vs. prod, maintenance windows, or compliance needs |
| **Audit trail** | Produces written reasoning for patch decisions, useful for compliance and reviews |
| **Pre/post checklist** | Generates tailored pre-patch and post-patch steps based on the current scan |

## Example

**SSM only**: "Apply all security updates" → executes without further reasoning.

**With Bedrock**: "Scan shows CVE-2024-1234 (Critical) and CVE-2024-5678 (Medium). CVE-2024-1234 is actively exploited; prioritize it. CVE-2024-5678 affects a service you may not use. Recommend patching during the next maintenance window and rebooting after."

## Summary

Systems Manager handles **execution** (scanning, applying patches). Bedrock handles **decision support** (interpretation, prioritization, and reasoning). Together they support a more intelligent, auditable, and context-aware patching process.
