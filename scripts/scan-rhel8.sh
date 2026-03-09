#!/bin/bash
# =============================================================================
# RHEL8 CVE Scan Script
# =============================================================================
# Scans RHEL8 instances for CVE-related security updates.
# Run via SSM Run Command or directly on the instance.
# Report output: /var/log/aiops/rhel8_scan_report.txt
# =============================================================================

REPORT_DIR="${REPORT_DIR:-/var/log/aiops}"
REPORT_FILE="${REPORT_DIR}/rhel8_scan_report.txt"
TIMESTAMP=$(date -Iseconds)
HOSTNAME=$(hostname)

mkdir -p "$REPORT_DIR"

{
  echo "=========================================="
  echo "RHEL8 CVE Security Scan Report"
  echo "=========================================="
  echo "Scan Date: $TIMESTAMP"
  echo "Hostname: $HOSTNAME"
  echo ""

  echo "=== System Information ==="
  if [ -f /etc/redhat-release ]; then
    cat /etc/redhat-release
  fi
  uname -a
  echo ""

  echo "=== Available Security Updates (CVE) ==="
  if command -v dnf &> /dev/null; then
    dnf updateinfo list security 2>/dev/null || echo "No security update info available"
    echo ""
    echo "--- Pending security updates ---"
    dnf check-update --security 2>/dev/null || echo "No pending security updates"
  elif command -v yum &> /dev/null; then
    yum updateinfo list security 2>/dev/null || echo "No security update info available"
    echo ""
    echo "--- Pending security updates ---"
    yum check-update --security 2>/dev/null || echo "No pending security updates"
  else
    echo "No package manager found (dnf/yum)"
  fi
  echo ""

  echo "=== Installed Security-Related Packages (recent) ==="
  rpm -qa --last 2>/dev/null | head -20
  echo ""

  echo "=========================================="
  echo "Report stored at: $REPORT_FILE"
  echo "=========================================="
} > "$REPORT_FILE" 2>&1

echo "RHEL8 scan complete. Report: $REPORT_FILE"
cat "$REPORT_FILE"
