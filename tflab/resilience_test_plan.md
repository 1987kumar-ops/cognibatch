# Azure Resilience Test Plan for `tflab`

## Environment summary
- Resource group: `rg-ailab-arunkumar`
- App VM: `vm-app` (Ubuntu 22.04, Standard_B2ms, private IP `10.0.1.10`)
- DB VM: `vm-db` (Ubuntu 22.04, Standard_B2ms, private IP `10.0.2.10`, PostgreSQL 14, `max_connections=20`)
- Windows VM: `vm-win` (Windows Server 2022, Standard_B2s, private IP `10.0.1.20`, IIS reporting service)
- Bastion: `bastion-ailab` Basic SKU is the only remote access path
- NSG controls:
  - SSH/RDP limited to Bastion subnet `10.0.3.0/27`
  - PostgreSQL `5432` allowed only from app subnet `10.0.1.0/24`
- Storage account: Standard LRS, soft-delete 7 days
- All VMs have auto-shutdown schedules at `20:00 UTC` daily

> All commands below assume Azure CLI access via Cloud Shell or an interactive Bastion session where `az login` and the proper subscription are configured.

---

## Common Go/No-Go checks before every scenario
1. Confirm all three VMs are running:
```bash
az vm get-instance-view -g rg-ailab-arunkumar -n vm-app --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
az vm get-instance-view -g rg-ailab-arunkumar -n vm-db --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
az vm get-instance-view -g rg-ailab-arunkumar -n vm-win --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
```
2. Confirm Bastion is provisioned:
```bash
az network bastion show -g rg-ailab-arunkumar -n bastion-ailab --query provisioningState -o tsv
```
3. Confirm there are no existing active test artifacts from a prior run:
   - Linux: no `yes`, no test disk fill file, no test `iptables` drop rule, no test DB sleep sessions
   - Windows: `W3SVC` is running
4. Confirm recovery window is available and the test will be aborted if recovery exceeds 5 minutes.

---

## SCENARIO A: App CPU exhaustion

**Name:** `App CPU saturation`

**Description:** Simulates a realistic compute pressure event on `vm-app`, where a Java payment service could be starved of CPU resources and become unresponsive under load.

**Failure type:** COMPUTE

**Blast radius:**
- `vm-app`: severe, service latency and request timeouts expected.
- `vm-db`: minimal, should remain healthy if client requests are limited.
- `vm-win`: unaffected.

**Go/No-Go check:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "ps -ef | grep -E 'yes > /dev/null' | grep -v grep || true"
```

**Trigger:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "for i in \\$(seq 1 2); do nohup yes > /dev/null 2>&1 & done"
```

**Expected impact:**
- `vm-app`: CPU usage approaches 100%, new JVM threads slow, payment service responses degrade.
- `vm-db`: unaffected in itself, but app-to-DB call volume may drop.
- `vm-win`: unaffected.

**Recovery:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "pkill -f '^yes$' || true"
```

**Validation:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "if pgrep -f '^yes$' >/dev/null; then exit 1; else echo OK; fi"
```

**RTO target:** 5 minutes

---

## SCENARIO B: PostgreSQL connection exhaustion

**Name:** `DB connection pool exhaustion`

**Description:** Simulates PostgreSQL hitting its configured connection limit, a likely failure mode for a low-capacity DB with aggressive app pooling.

**Failure type:** DATABASE

**Blast radius:**
- `vm-db`: high, new connections rejected with `too many connections`.
- `vm-app`: medium-high, payment service errors or retries on DB access.
- `vm-win`: unaffected.

**Go/No-Go check:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-db --command-id RunShellScript --scripts "sudo -u postgres psql -d labdb -c 'select 1'"
```

**Trigger:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-db --command-id RunShellScript --scripts "for i in \\$(seq 1 20); do nohup sudo -u postgres psql -d labdb -c 'select pg_sleep(300);' > /tmp/db_conn_test_\\$i.log 2>&1 & done"
```

**Expected impact:**
- `vm-db`: accepts existing sessions but rejects new inbound DB sessions.
- `vm-app`: new requests that need DB connections fail or timeout.
- `vm-win`: unaffected.

**Recovery:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-db --command-id RunShellScript --scripts "pkill -f 'select pg_sleep(300)' || true"
```

**Validation:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-db --command-id RunShellScript --scripts "sudo -u postgres psql -d labdb -c 'select 1'"
```

**RTO target:** 5 minutes

---

## SCENARIO C: App disk fill

**Name:** `App disk exhaustion`

**Description:** Simulates root filesystem exhaustion on `vm-app`, a realistic outcome of runaway log growth or temp-file generation in a production service.

**Failure type:** STORAGE

**Blast radius:**
- `vm-app`: high, writes fail and the payment service may return errors.
- `vm-db`: unaffected.
- `vm-win`: unaffected.

**Go/No-Go check:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "test -f /tmp/vm_app_disk_fill_test && exit 1 || echo CLEAN"
```

**Trigger:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "sudo fallocate -l 24G /tmp/vm_app_disk_fill_test || sudo dd if=/dev/zero of=/tmp/vm_app_disk_fill_test bs=1M count=24000"
```

**Expected impact:**
- `vm-app`: disk writes fail, app log and temp writes may error.
- `vm-db`: unaffected.
- `vm-win`: unaffected.

**Recovery:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "sudo rm -f /tmp/vm_app_disk_fill_test"
```

**Validation:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "df -h /tmp | awk 'NR==2 {print \$5}'"
```

**RTO target:** 5 minutes

---

## SCENARIO D: App-to-DB network block

**Name:** `App-to-DB routing failure`

**Description:** Simulates a network policy/meticulous routing failure where `vm-app` cannot reach `vm-db`, reflecting failures in host-level firewall rules or subnet routing.

**Failure type:** NETWORK

**Blast radius:**
- `vm-app`: high, DB-dependent payment workflows fail.
- `vm-db`: low, still healthy but isolated from the app.
- `vm-win`: unaffected.

**Go/No-Go check:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "bash -lc 'timeout 5 bash -c "</dev/tcp/10.0.2.10/5432" >/dev/null 2>&1 && echo CONNECTED || echo DISCONNECTED'"
```

**Trigger:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "sudo iptables -A OUTPUT -d 10.0.2.10 -j DROP"
```

**Expected impact:**
- `vm-app`: DB connection attempts time out or immediately fail.
- `vm-db`: healthy, but isolated from `vm-app`.
- `vm-win`: unaffected.

**Recovery:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "sudo iptables -D OUTPUT -d 10.0.2.10 -j DROP || true"
```

**Validation:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-app --command-id RunShellScript --scripts "bash -lc 'timeout 5 bash -c "</dev/tcp/10.0.2.10/5432" >/dev/null 2>&1 && echo CONNECTED || echo BLOCKED'"
```

**RTO target:** 5 minutes

---

## SCENARIO E: Windows IIS service down

**Name:** `Reporting service outage`

**Description:** Simulates the IIS reporting service on `vm-win` stopping unexpectedly, a realistic application failure that impacts Windows-hosted web functionality.

**Failure type:** APPLICATION

**Blast radius:**
- `vm-win`: high for IIS-based reporting.
- `vm-app`: unaffected unless it depends on `vm-win` for reporting.
- `vm-db`: unaffected.

**Go/No-Go check:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-win --command-id RunPowerShellScript --scripts "(Get-Service W3SVC).Status"
```
```

**Trigger:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-win --command-id RunPowerShellScript --scripts "Stop-Service W3SVC -Force"
```

**Expected impact:**
- `vm-win`: IIS stops and web reporting endpoints become unavailable.
- `vm-app`: unaffected if it is not dependent on `vm-win`.
- `vm-db`: unaffected.

**Recovery:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-win --command-id RunPowerShellScript --scripts "Start-Service W3SVC"
```

**Validation:**
```bash
az vm run-command invoke -g rg-ailab-arunkumar -n vm-win --command-id RunPowerShellScript --scripts "(Get-Service W3SVC).Status"
```

**RTO target:** 5 minutes

---

## SCENARIO F: Auto-shutdown / unexpected VM stop

**Name:** `Scheduled shutdown event`

**Description:** Simulates an unexpected VM stop event on `vm-app` or `vm-db` to validate restart recovery and the impact of the existing auto-shutdown schedule.

**Failure type:** COMPUTE / SCHEDULED MAINTENANCE

**Blast radius:**
- Stopped VM: severe for services hosted on that VM.
- Non-stopped VMs: unaffected.

**Go/No-Go check:**
```bash
az vm get-instance-view -g rg-ailab-arunkumar -n vm-app --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
az vm get-instance-view -g rg-ailab-arunkumar -n vm-db --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
```

**Trigger:**
```bash
az vm stop -g rg-ailab-arunkumar -n vm-app
```

**Expected impact:**
- `vm-app`: payment service unavailable until VM restarts.
- `vm-db`: unaffected if not stopped.
- `vm-win`: unaffected.

**Recovery:**
```bash
az vm start -g rg-ailab-arunkumar -n vm-app
```

**Validation:**
```bash
az vm get-instance-view -g rg-ailab-arunkumar -n vm-app --query "instanceView.statuses[?contains(code,'PowerState')].displayStatus" -o tsv
```

**RTO target:** 5 minutes

---

## Priority order by risk to the payment service
1. `DB connection pool exhaustion` (Scenario B)
2. `App-to-DB routing failure` (Scenario D)
3. `App CPU saturation` (Scenario A)
4. `App disk exhaustion` (Scenario C)
5. `Scheduled shutdown event` (Scenario F)
6. `Reporting service outage` (Scenario E)

---

## Dependency map
- Run `Scenario F` (stop/start event) before scenarios that require the VM state to be running, only if you need to test VM recovery independently.
- `Scenario B` and `Scenario D` are independent of each other and should be validated before `Scenario A` and `Scenario C` if the goal is to isolate infrastructure versus application failure modes.
- `Scenario E` is independent and can be executed at any time after confirming `vm-win` is healthy.
- `Scenario C` should follow `Scenario A` if you want to verify root-cause detection for compute pressure versus storage pressure on the same host.

---

## Known gaps and non-testable resilience risks
- **Single-instance VMs**: There is no load-balanced or multi-instance deployment for `vm-app`, `vm-db`, or `vm-win`. True failover and HA cannot be validated safely in this lab without redesigning the architecture.
- **No backup/restore test for DB or storage**: Soft-delete is configured on storage, but there is no safe in-place backup and restore test for PostgreSQL or the storage account without risking data state or requiring a rebuild.
- **No public endpoint redundancy**: Bastion is a single access path. Testing Bastion failure would require provisioning a second Bastion or a separate jump host, which is outside the current environment.
- **No Azure Availability Set/Zone placement**: There is no zone-redundant or availability-set topology to test hardware or zone failures safely.
- **Application-level Java heap and thread exhaustion**: The payment service is only simulated by CPU and disk stress. A real Java heap exhaustion or GC storm test is not safe with unknown app internals.

---

## Notes
- All triggers and recoveries use Azure CLI or Azure VM run-command and are reversible.
- No test issues permanent data loss.
- Use the documented `az vm run-command invoke` commands when you cannot directly SSH/RDP through Bastion.
