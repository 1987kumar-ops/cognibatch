# Azure CLI Commands: Fault Injection & Restore (Scenario D)

## Deployment context
```bash
RESOURCE_GROUP="rg-ailab-arunkumar"
APP_VM="vm-app"
DB_VM="vm-db"
DB_IP="10.0.2.10"
DB_PORT="5432"
```

## Pre-flight Go/No-Go check
Confirm all VMs are running and connectivity is baseline healthy:
```bash
# Check vm-app is running
az vm get-instance-view -g $RESOURCE_GROUP -n $APP_VM --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv

# Check vm-db is running
az vm get-instance-view -g $RESOURCE_GROUP -n $DB_VM --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv

# Confirm baseline connectivity (should show CONNECTED)
az vm run-command invoke -g $RESOURCE_GROUP -n $APP_VM --command-id RunShellScript --scripts "bash -lc 'timeout 5 bash -c \"</dev/tcp/$DB_IP/$DB_PORT\" >/dev/null 2>&1 && echo CONNECTED || echo BLOCKED'"
```

## FAULT INJECTION: Add iptables OUTPUT DROP rule to vm-app
```bash
az vm run-command invoke \
  -g $RESOURCE_GROUP \
  -n $APP_VM \
  --command-id RunShellScript \
  --scripts "sudo iptables -A OUTPUT -d $DB_IP -j DROP"
```

## VALIDATE FAULT: Confirm connectivity is blocked
```bash
az vm run-command invoke \
  -g $RESOURCE_GROUP \
  -n $APP_VM \
  --command-id RunShellScript \
  --scripts "bash -lc 'timeout 5 bash -c \"</dev/tcp/$DB_IP/$DB_PORT\" >/dev/null 2>&1 && echo CONNECTED || echo BLOCKED'"
```

Expected: `BLOCKED`

## RESTORE: Delete the iptables rule from vm-app
```bash
az vm run-command invoke \
  -g $RESOURCE_GROUP \
  -n $APP_VM \
  --command-id RunShellScript \
  --scripts "sudo iptables -D OUTPUT -d $DB_IP -j DROP || true"
```

## VALIDATE RESTORE: Confirm connectivity is restored
```bash
az vm run-command invoke \
  -g $RESOURCE_GROUP \
  -n $APP_VM \
  --command-id RunShellScript \
  --scripts "bash -lc 'timeout 5 bash -c \"</dev/tcp/$DB_IP/$DB_PORT\" >/dev/null 2>&1 && echo CONNECTED || echo BLOCKED'"
```

Expected: `CONNECTED`

## Confirmation that PostgreSQL is healthy on vm-db (during incident)
```bash
az vm run-command invoke \
  -g $RESOURCE_GROUP \
  -n $DB_VM \
  --command-id RunShellScript \
  --scripts "sudo -u postgres psql -d labdb -c 'select 1'"
```

Expected output: Should show `(1 row)` — confirms DB itself is healthy, only network connectivity is blocked.
