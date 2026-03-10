# AIOps R8: Presentation Diagrams & Flowcharts

Mermaid diagrams for each presentation slide. Use in Markdown viewers or export to images.

---

## Slide 1: Title & Overview – Component Stack

```mermaid
flowchart TB
    subgraph Title["AIOps R8 - Production-Safe CVE Patching"]
        direction TB
        A["Automated CVE patching"]
        B["RHEL8 + Windows"]
        C["Amazon Inspector v2"]
        D["Bedrock (Nova 2 Lite)"]
        E["Step Functions + EventBridge"]
        F["CVE-only, production-safe"]
    end
    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
```

---

## Slide 2: The Problem – Pain Points

```mermaid
flowchart LR
    subgraph Problems["The Problem"]
        P1["Manual patching<br/>Error-prone, doesn't scale"]
        P2["Blind automation<br/>Unnecessary risk"]
        P3["Pre-patch scripts<br/>Inconsistent, hard to maintain"]
        P4["Need smart decision<br/>When to patch?"]
    end
    P1 --> P4
    P2 --> P4
    P3 --> P4
```

---

## Slide 3: The Solution – High-Level Flow

```mermaid
flowchart TB
    EB["EventBridge<br/>monthly schedule"]
    SF["Step Functions"]
    L1["1. Fetch Inspector findings<br/>Lambda"]
    L2["2. Analyze with Bedrock<br/>Lambda"]
    CHOICE{"3. Critical CVEs?"}
    APPLY["4. Apply patches<br/>Parallel: RHEL + Windows via SSM<br/>Circuit-breaker check, pre-patch AMIs"]
    POST["5. Post-patch verification<br/>Parallel"]
    SKIP["NotifyNoPatch<br/>Skip"]
    CB["Circuit-breaker: EC2 stopped → block CVE"]
    AMI["AMI cleanup: daily"]

    EB -->|Trigger| SF
    SF --> L1
    L1 --> L2
    L2 --> CHOICE
    CHOICE -->|Yes| APPLY
    CHOICE -->|No| SKIP
    APPLY --> POST
    APPLY -.->|on failure| CB
    CB -.-> AMI
```

---

## Slide 4: Architecture – Key Components

```mermaid
flowchart TB
    subgraph Data["Data Layer"]
        INSP["Amazon Inspector v2<br/>Discovers EC2, scans CVEs, stores findings"]
    end

    subgraph Orchestration["Orchestration"]
        SF["Step Functions<br/>Orchestrates, Choice gates patching"]
    end

    subgraph Lambdas["Lambda Layer"]
        L_INSP["Inspector Findings Lambda<br/>ListFindings API, filter by VPC"]
        L_ANALYZER["CVE Analyzer Lambda<br/>Bedrock → has_critical_cves"]
        L_SSM["SSM Runner Lambda<br/>Invokes SSM Run Command"]
    end

    subgraph AI["AI"]
        BEDROCK["Bedrock<br/>Analyzes severity, patch/no-patch"]
    end

    subgraph Execution["Execution"]
        SSM["Systems Manager<br/>dnf update --security (RHEL)<br/>Patch Baseline (Windows)"]
    end

    SF --> L_INSP
    L_INSP --> INSP
    SF --> L_ANALYZER
    L_ANALYZER --> BEDROCK
    SF --> L_SSM
    L_SSM --> SSM
```

---

## Slide 5: Inspector vs SSM Pre-Patch – Comparison

```mermaid
flowchart LR
    subgraph SSM["SSM Pre-Patch Scripts"]
        S1["Commands on each instance"]
        S2["Raw output"]
        S3["Custom SSM docs"]
        S4["Per-instance"]
        S5["Varies by OS"]
    end

    subgraph INSP["Amazon Inspector"]
        I1["AWS-managed service"]
        I2["Structured findings"]
        I3["No maintenance"]
        I4["EC2, ECR, Lambda"]
        I5["Unified CVE DB"]
    end

    SSM -.->|Replaced by| INSP
```

---

## Slide 6: AI in the Loop – Bedrock Decision Flow

```mermaid
flowchart TB
    subgraph Input["Input"]
        FINDINGS["Inspector findings<br/>severity, CVE IDs, packages"]
    end

    subgraph Bedrock["Bedrock (Nova 2 Lite)"]
        MODEL["us.amazon.nova-2-lite-v1:0"]
        ANALYZE["Analyze CVE severity"]
    end

    subgraph Output["Output"]
        FLAG["has_critical_cves<br/>true / false"]
        RECS["Recommendations"]
    end

    subgraph Decision["Decision"]
        CHOICE{"has_critical_cves?"}
        PATCH["Apply patches<br/>Parallel"]
        SKIP["NotifyNoPatch<br/>Skip"]
    end

    FINDINGS --> MODEL
    MODEL --> ANALYZE
    ANALYZE --> FLAG
    ANALYZE --> RECS
    FLAG --> CHOICE
    CHOICE -->|true| PATCH
    CHOICE -->|false| SKIP
```

---

## Slide 7: CVE-Only Patching – Production-Safe

```mermaid
flowchart TB
    subgraph RHEL["RHEL8"]
        DNF["dnf update --security -y"]
    end

    subgraph WIN["Windows"]
        PB["Patch Baseline<br/>SecurityUpdates, CriticalUpdates<br/>enable_non_security=false"]
    end

    subgraph Scope["Scope"]
        SEC["Security updates only"]
        NO_FEAT["No feature updates"]
        NO_OPT["No optional packages"]
    end

    DNF --> SEC
    PB --> SEC
    SEC --> NO_FEAT
    SEC --> NO_OPT
```

---

## Slide 8: Schedule & Triggers

```mermaid
flowchart TB
    subgraph Schedule["EventBridge Schedule"]
        CRON["cron(0 2 ? * 3#2 *)"]
        TIME["2:00 AM UTC"]
        DAY["2nd Tuesday of month"]
    end

    subgraph Manual["Manual Trigger"]
        CMD["aws stepfunctions start-execution"]
    end

    subgraph Context["Context"]
        PT["Patch Tuesday = 1st Tuesday"]
        GAP["1 week gap for testing"]
    end

    CRON --> TIME
    CRON --> DAY
    PT --> GAP
    DAY --> GAP
```

---

## Slide 9: Report Locations

```mermaid
flowchart LR
    subgraph RHEL["RHEL8"]
        R1["/var/log/aiops/<br/>post_patch_report.txt"]
    end

    subgraph WIN["Windows"]
        W1["C:\\aiops\\reports\\<br/>post_patch_report.txt"]
    end

    subgraph Content["Report Content"]
        C1["Remaining security updates"]
        C2["Last applied patches"]
    end

    R1 --> Content
    W1 --> Content
```

---

## Slide 10: Cost Overview

```mermaid
flowchart TB
    subgraph Small["4 Nodes"]
        S1["Patch workflow: ~$5-20/mo"]
        S2["With EC2: ~$50-200/mo"]
    end

    subgraph Large["1000 Nodes"]
        L1["Patch workflow: ~$50-200/mo"]
        L2["With EC2: ~$12K-50K/mo"]
    end

    subgraph Drivers["Cost Drivers"]
        D1["Lambda, SF, Bedrock: low"]
        D2["Inspector: scales with findings"]
        D3["SSM: ~$0.005/instance/mo"]
    end

    Small --> Drivers
    Large --> Drivers
```

---

## Slide 11: Where Are Patch Decisions Stored?

```mermaid
flowchart TB
    subgraph Current["Current (Out of Box)"]
        SF_HIST["Step Functions<br/>execution history"]
        CW["CloudWatch Logs<br/>Lambda invocations"]
    end

    subgraph Optional["Optional (Compliance)"]
        DDB["DynamoDB"]
        S3["S3"]
    end

    subgraph Flow["Data Flow"]
        F1["CVE Analyzer"]
        F2["has_critical_cves"]
        F3["Step Functions state"]
    end

    F1 --> F2
    F2 --> F3
    F3 --> SF_HIST
    F3 -.->|Add for audit| DDB
    F3 -.->|Add for audit| S3
```

---

## Slide 12: Infrastructure as Code

```mermaid
flowchart TB
    subgraph Terraform["Terraform"]
        TF["terraform apply"]
    end

    subgraph Modules["Modules"]
        M1["VPC"]
        M2["EC2 RHEL8"]
        M3["EC2 Windows"]
        M4["Patch Workflow"]
    end

    subgraph PatchWorkflow["Patch Workflow Module"]
        PW1["Lambdas x3"]
        PW2["Step Functions"]
        PW3["EventBridge"]
        PW4["aws_inspector2_enabler"]
    end

    TF --> M1
    TF --> M2
    TF --> M3
    TF --> M4
    M4 --> PW1
    M4 --> PW2
    M4 --> PW3
    M4 --> PW4
```

---

## Slide 13: Key Takeaways

```mermaid
flowchart LR
    T1["Inspector + Bedrock + SSM"]
    T2["CVE-only, production-safe"]
    T3["AI-gated patching"]
    T4["Parallel execution"]
    T5["Terraform IaC"]

    T1 --> T2
    T2 --> T3
    T3 --> T4
    T4 --> T5
```

---

## Appendix: Step Functions State Machine

```mermaid
stateDiagram-v2
    [*] --> FetchInspectorFindings
    FetchInspectorFindings --> AnalyzeCVEs
    AnalyzeCVEs --> CheckCriticalCVEs
    CheckCriticalCVEs --> ApplyPatches: has_critical_cves = true
    CheckCriticalCVEs --> NotifyNoPatch: has_critical_cves = false
    ApplyPatches --> PostPatch
    PostPatch --> [*]
    NotifyNoPatch --> [*]
```

---

## Appendix: End-to-End Sequence Diagram

```mermaid
sequenceDiagram
    participant EB as EventBridge
    participant SF as Step Functions
    participant L_INSP as Inspector Lambda
    participant INSP as Inspector v2
    participant L_ANALYZER as CVE Analyzer
    participant BEDROCK as Bedrock
    participant L_SSM as SSM Runner
    participant SSM as Systems Manager
    participant RHEL as RHEL8
    participant WIN as Windows

    EB->>SF: Trigger (2nd Tuesday)
    SF->>L_INSP: FetchInspectorFindings
    L_INSP->>INSP: ListFindings
    INSP-->>L_INSP: CVE findings
    L_INSP-->>SF: findings
    SF->>L_ANALYZER: AnalyzeCVEs
    L_ANALYZER->>BEDROCK: CVE analysis
    BEDROCK-->>L_ANALYZER: has_critical_cves
    L_ANALYZER-->>SF: result
    alt Critical CVEs
        SF->>L_SSM: ApplyPatches (Parallel)
        L_SSM->>SSM: SendCommand
        SSM->>RHEL: dnf update --security
        SSM->>WIN: RunPatchBaseline
        SF->>L_SSM: PostPatch (Parallel)
    else No critical CVEs
        SF->>SF: NotifyNoPatch
    end
```
