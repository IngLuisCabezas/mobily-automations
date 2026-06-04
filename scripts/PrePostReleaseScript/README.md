# Pre- and Post-Release Health Checks

Shell automation that validates SingleView application, Oracle database, and system resources **before and after** a release installation. The script discovers all cluster instances, runs checks remotely on each node, and produces a consolidated PASS / WARN / FAIL summary.

## Files

| File | Purpose |
|------|---------|
| [`PrePost_Release_Health_Checks.sh`](PrePost_Release_Health_Checks.sh) | Main orchestrator: loads config, discovers instances, SSHs to each node, aggregates results |
| [`health_check.conf`](health_check.conf) | Thresholds and parameters (no commands are executed from this file) |

## Requirements

- Run from a SingleView environment user account with SSH access to all cluster nodes.
- **Local (orchestrator):** `bash`, `ssh`, `da_dump`, and a sourced environment (`~/.profile`).
- **Remote (each node):** `ksh`, SingleView utilities (`svstatus`, `sv_status`, `cache_check`, `cfg`, `cbtasks`, etc.), Oracle tools (`orasize`, `dbverify`, `orasql`, `tnsping`, `sqlplus`), and `$ATADBACONNECT` for database queries.
- Passwordless SSH from the execution host to each instance hostname returned by `da_dump InstanceStatus`.

## Usage

```bash
cd scripts/PrePostReleaseScript
chmod +x PrePost_Release_Health_Checks.sh
./PrePost_Release_Health_Checks.sh health_check.conf
```

The script writes a timestamped log in the current directory:

```text
Validation_Checks_YYYYMMDD_HHMMSS.log
```

Console output is also tee'd to that file.

## Configuration

Edit [`health_check.conf`](health_check.conf) to adjust thresholds:

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_ATA_HOME_FREE_PCT` | 30 | Minimum free disk space under `$ATA_HOME` (%) |
| `MIN_TMP_FREE_PCT` | 40 | Minimum free disk space under `/tmp` (%) |
| `MIN_MEM_AVAILABLE_PCT` | 40 | Minimum available system memory (%) |
| `MAX_TNSPING_LATENCY_MS` | 200 | Maximum acceptable Oracle Net latency (ms) |
| `MAX_TABLESPACE_USED_PCT` | 80 | Maximum Oracle tablespace usage (%) |
| `ORASQL_EXEC_LIMIT` | 300 | Flag SQL running at or above this duration (seconds) |

All threshold values must be numeric (digits only).

## How it works

1. **Load config** — Sources `health_check.conf` and validates required variables.
2. **Discover instances** — Parses hostnames from `da_dump InstanceStatus`.
3. **Classify topology** — For each node, determines:
   - `sv_type`: `1` single instance, `2` first node in multi-instance, `3` additional nodes
   - `sv_ha`: `1` if `HA_ACTIVE=1` in the environment, else `0`
4. **Remote execution** — SSHs to each host and runs checks in `ksh` based on `sv_type` and `sv_ha`.
5. **Aggregate summary** — Totals PASS, WARN, and FAIL counts across all nodes and prints a release recommendation.

## Checks performed

### Cluster and application (primarily SV1 / first node)

| Check | Tool / query | PASS | WARN | FAIL |
|-------|--------------|------|------|------|
| HA cluster resources | `sv_ha_ctl cluster_status` | No inactive resources | — | Inactive resources found |
| CB server status | `sv_status -cluster` | Healthy PE/CB lines | — | Unknown state, not running, restricted, etc. |
| STD process placement | `cfg STD -l ENABLED` | Exactly one STD, not on Standby PE | STD on Standby PE | Zero or multiple STD enabled |
| Control/background tasks | `cbtasks` | No tasks | Tasks present | — |
| Tablespace usage | `orasize` | All below threshold | Any above threshold | — |
| Datafile integrity | `dbverify` | No `table.diff` | — | `table.diff` found |
| Long-running SQL | `orasql -e <limit>` | No matching active SQL | Queries over limit | — |
| Unexpected Z tables | `sqlplus` on `all_tables` | None found | — | Z-prefixed tables exist |
| Debug configuration | `sqlplus` on config attributes | No debug enabled | — | Debug flags or `-d` args found |

### Per-node (all instances)

| Check | Tool | PASS | WARN | FAIL |
|-------|------|------|------|------|
| SingleView service status | `svstatus` | `<S90003> Singleview is running` | — | `<E*` / `<W*` errors |
| Cache integrity | `cache_check` | OK | — | Errors or non-zero exit |
| `$ATA_HOME` disk space | `df` | Free % ≥ threshold | Below threshold | — |
| `/tmp` disk space | `df` | Free % ≥ threshold | Below threshold | — |
| Available memory | `free -g` | Available % ≥ threshold | Below threshold | Unable to read memory |
| Oracle connectivity | `tnsping $ORACLE_SID` | Latency ≤ threshold | Latency above threshold | Invalid or missing ping |

Additional informational output from `sv_status` is printed on each node but is not scored.

## Result indicators

| Indicator | Meaning |
|-----------|---------|
| `[PASS]` | Check met expected criteria |
| `[WARN]` | Review recommended; installation may still proceed |
| `[FAIL]` | Must be investigated and remediated before release |

## Release decision (summary)

| Condition | Recommendation |
|-----------|----------------|
| One or more **FAIL** | Release **cannot** be installed until failures are resolved |
| **WARN** only (no FAIL) | Release **can** proceed; review warnings as needed |
| All **PASS** | Release **can** be installed |

## Topology matrix

Remote check sets depend on instance type and HA mode:

| sv_type | sv_ha | Scenario | Checks on SV1 / first node | Checks on other nodes |
|---------|-------|----------|----------------------------|------------------------|
| 1 | 0 | Single instance | Full SV1 + per-node | — |
| 2 | 0 | Multi-instance, non-HA (first node) | Full SV1 + per-node | Per-node only |
| 3 | 0 | Multi-instance, non-HA (additional) | — | Per-node only |
| 2 | 1 | Multi-instance HA (first node) | HA cluster + full SV1 + per-node | Per-node only |
| 3 | 1 | Multi-instance HA (additional) | — | Per-node only |

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `Usage: $0 <health_check.conf>` | Config file path not provided |
| `File not found` | Wrong path to config file |
| `Variable '...' is not set` | Missing or empty threshold in `health_check.conf` |
| SSH / remote errors | Host unreachable, key trust, or user mismatch |
| `Unable to run 'cfg STD -l ENABLED'` | SingleView tools not in PATH on remote node |
| Invalid tnsping | `$ORACLE_SID` unset or listener unavailable |

## Related automation

This script is intended for manual or pipeline use around Mobily release deployments. See the root [README](../../README.md) for Jenkins pipelines and other automations in this repository.
