# End Goal: Customer Ask

## What the Customer Wants

**Automated, production-safe CVE patching that scales without risk.**

The customer needs to keep RHEL8 and Windows servers secure by applying critical security patches, while avoiding the operational risk and downtime that comes from blind or manual patching.

---

## The Core Ask

1. **Patch only when it matters**  
   Apply updates only when there are critical CVEs—not every minor update, not on a fixed schedule regardless of risk.

2. **Stay production-safe**  
   Limit patching to security-related updates. No feature updates, no optional packages, no changes that could introduce breaking behavior.

3. **Remove manual effort**  
   No more ad-hoc scripts, inconsistent pre-patch scans, or manual decisions about when to patch.

4. **Use structured, reliable data**  
   Base patch decisions on authoritative CVE data (severity, affected packages, IDs), not raw command output or custom scripts.

5. **Scale across the fleet**  
   Support RHEL8 and Windows across many instances without manual per-instance work.

---

## Success Criteria

| Outcome | Description |
|---------|-------------|
| **Security** | Critical CVEs are patched in a timely way |
| **Stability** | Only security updates are applied; production risk is minimized |
| **Automation** | Patching runs on a schedule with minimal human intervention |
| **Visibility** | Patch decisions are traceable; reports exist for audit and troubleshooting |
| **Consistency** | Same process for RHEL and Windows, driven by a single workflow |

---

## What “Done” Looks Like

- Critical vulnerabilities are identified automatically from a trusted source (Inspector).
- An AI-driven decision determines whether patching is needed based on severity and context.
- When needed, only security updates are applied—CVE-related patches only.
- RHEL8 and Windows instances are patched in parallel.
- Each run leaves an audit trail and local reports for compliance and debugging.
- The entire flow is automated, repeatable, and deployable via Infrastructure as Code.

---

## In One Sentence

**The customer wants to patch critical CVEs automatically and safely, without manual scripts or blind automation, using structured data and AI to decide when to act.**
