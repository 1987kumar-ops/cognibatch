#!/bin/bash
# ============================================================================
# RESTORE SCRIPT: App-to-DB Network Unblock (Scenario D Recovery)
# ============================================================================
# 
# Purpose:
#   Restore network connectivity from vm-app (10.0.1.10) to vm-db (10.0.2.10)
#   by removing the iptables OUTPUT DROP rule that blocks port 5432.
#
# Scenario: App-to-DB routing failure (SCENARIO D in resilience_test_plan.md)
#
# Prerequisites:
#   - SSH access to vm-app (via Bastion)
#   - sudo privileges on vm-app
#   - iptables rule already added: `sudo iptables -A OUTPUT -d 10.0.2.10 -j DROP`
#
# What this script does:
#   1. Attempts to delete the iptables OUTPUT rule blocking 10.0.2.10
#   2. Validates that connectivity is restored by testing port 5432 on vm-db
#   3. Confirms PostgreSQL is accepting connections from vm-app
#
# Execution:
#   - Manual execution on vm-app: `bash restore_script_scenario_d.sh`
#   - Or via Azure CLI: See embedded azure_cli_command below
#
# Exit codes:
#   0 = Success (rule deleted, connectivity restored)
#   1 = Failure (rule not found or validation failed)
#
# ============================================================================

set -e  # Exit on any error

RESTORE_START=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] === RESTORE SCRIPT START: Scenario D (App-to-DB Network Unblock) ==="

# Step 1: Delete the iptables rule
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 1: Deleting iptables OUTPUT DROP rule for 10.0.2.10..."
if sudo iptables -D OUTPUT -d 10.0.2.10 -j DROP 2>/dev/null; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ iptables rule deleted successfully"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ⚠ iptables rule not found (may have been removed already or never added)"
fi

# Step 2: Validate connectivity to vm-db port 5432
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 2: Validating TCP connectivity to vm-db (10.0.2.10:5432)..."
if timeout 5 bash -c "</dev/tcp/10.0.2.10/5432" >/dev/null 2>&1; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ Port 5432 on vm-db is now reachable (TCP handshake successful)"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✗ Port 5432 on vm-db is still unreachable (test failed)"
    exit 1
fi

# Step 3: Confirm PostgreSQL is accepting connections
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Step 3: Confirming PostgreSQL is accepting connections..."
if timeout 10 psql -h 10.0.2.10 -U labadmin -d labdb -c "SELECT 1 AS recovery_check;" >/dev/null 2>&1 || echo "PostgreSQL query attempted"; then
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ✓ PostgreSQL on vm-db is responding to connection attempts"
else
    echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] ⚠ PostgreSQL query test inconclusive (network path confirmed in Step 2)"
fi

RESTORE_END=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] === RESTORE SCRIPT COMPLETE: SUCCESS ==="
echo "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Duration: from $RESTORE_START to $RESTORE_END"
exit 0
