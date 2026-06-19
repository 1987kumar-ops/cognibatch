#!/bin/bash
# ============================================================================
# FAULT INJECTION SCRIPT: App-to-DB Network Block (Scenario D Trigger)
# ============================================================================
#
# ⚠️  CRITICAL: This fault script must ONLY be run AFTER the restore script
#    has been created, reviewed, and successfully tested in the environment.
#    This is a mandatory gate. See TESTING_CONFIRMATION.txt.
#
# Purpose:
#   Simulate a network policy or routing misconfiguration that blocks the
#   application tier from reaching the database tier. This is a realistic
#   failure mode where NSG rules or host-level firewall rules isolate the app.
#
# Scenario: App-to-DB routing failure (SCENARIO D in resilience_test_plan.md)
#
# Prerequisites:
#   - SSH access to vm-app (via Bastion)
#   - sudo privileges on vm-app
#   - Restore script has been tested and validated (see TESTING_CONFIRMATION.txt)
#
# What this script does:
#   1. Adds an iptables OUTPUT DROP rule that blocks all traffic from vm-app to vm-db IP
#   2. Confirms the rule is in effect
#   3. Validates that connectivity is blocked
#
# Execution:
#   - Manual execution on vm-app: `bash fault_script_scenario_d.sh`
#   - Or via Azure CLI: See embedded azure_cli_command below
#
# Expected failure signature:
#   - TCP connections to 10.0.2.10:5432 timeout or reset
#   - PostgreSQL connection attempts fail with "Connection refused" or timeout
#   - vm-db remains healthy but isolated from vm-app
#
# Exit codes:
#   0 = Success (rule added, connectivity blocked)
#   1 = Failure (rule not added or validation failed)
#
# ============================================================================

set -e  # Exit on any error

FAULT_START=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] === FAULT INJECTION START: Scenario D (App-to-DB Network Block) ==="

# Step 1: Add the iptables rule
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 1: Adding iptables OUTPUT DROP rule for 10.0.2.10..."
if sudo iptables -A OUTPUT -d 10.0.2.10 -j DROP; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ iptables rule added successfully"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✗ Failed to add iptables rule"
    exit 1
fi

# Step 2: Verify rule is in effect
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 2: Verifying iptables rule is in effect..."
if sudo iptables -L OUTPUT -n | grep -q "DROP.*10.0.2.10"; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ iptables rule confirmed in OUTPUT chain"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✗ iptables rule not found in OUTPUT chain"
    exit 1
fi

# Step 3: Validate that connectivity is blocked
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 3: Validating TCP connectivity is blocked to vm-db (10.0.2.10:5432)..."
if ! timeout 5 bash -c "</dev/tcp/10.0.2.10/5432" >/dev/null 2>&1; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ Port 5432 on vm-db is now unreachable (fault confirmed)"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✗ Port 5432 on vm-db is still reachable (fault NOT triggered)"
    # Attempt to clean up
    sudo iptables -D OUTPUT -d 10.0.2.10 -j DROP || true
    exit 1
fi

FAULT_END=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] === FAULT INJECTION COMPLETE: SUCCESS ==="
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Duration: from $FAULT_START to $FAULT_END"
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] INCIDENT WINDOW NOW OPEN. When ready, execute restore_script_scenario_d.sh"
exit 0
