# Mobily — Automations

Repository of automation scripts and Jenkins pipelines for the **Mobily** SingleView project. Scripts and pipelines developed across environments are published here incrementally.

## Repository structure

```
mobily-automations/
├── README.md
├── .gitignore
├── jenkins/
│   └── pipelines/                    # Jenkins declarative pipeline definitions (Groovy)
└── scripts/
    ├── .gitkeep                      # Placeholder for future standalone scripts
    └── PrePostReleaseScript/         # Pre/post-release health checks (manual, SV1)
        ├── PrePost_Release_Health_Checks.sh
        ├── health_check.conf
        └── README.md
```

## Folder descriptions

| Folder | Purpose |
|--------|---------|
| [`jenkins/`](jenkins/) | Jenkins automation assets. Currently contains pipeline scripts only; add shared Groovy libraries or job config here as the project grows. |
| [`jenkins/pipelines/`](jenkins/pipelines/) | Declarative Jenkins pipeline scripts (`.groovy`). Each file maps to one Jenkins **Pipeline** job. Pipelines validate agents, run work in parallel across labeled nodes, and archive combined reports. |
| [`scripts/`](scripts/) | Standalone scripts (bash, Python, etc.) that are **not** tied to a Jenkins job. Use subfolders per automation (for example `PrePostReleaseScript/`). |
| [`scripts/PrePostReleaseScript/`](scripts/PrePostReleaseScript/) | Pre- and post-release health validation for SingleView clusters. Run manually from the **SV1 Linux server** — not from Jenkins. See [PrePostReleaseScript](#prepostreleasescript) below and [`scripts/PrePostReleaseScript/README.md`](scripts/PrePostReleaseScript/README.md). |

## Jenkins pipelines

Create a **Pipeline** job in Jenkins, point it at the matching file under `jenkins/pipelines/`, and define the job parameters listed for each pipeline.

| Pipeline | File | Summary |
|----------|------|---------|
| **Filesystem application backup** | [`FileSystemApplicatonBackup.groovy`](jenkins/pipelines/FileSystemApplicatonBackup.groovy) | Validates nodes and disk space, runs parallel filesystem backup on all agents with the environment label. On SV1, exports SingleView tables and config items first. Uses `pigz` compression and produces one combined log artifact. |
| **Filesystem application restore** | [`FileSystemApplicatonRestore.groovy`](jenkins/pipelines/FileSystemApplicatonRestore.groovy) | Validates nodes, disk space, and presence of a restore archive, then removes existing application directories and extracts the backup tarball in parallel on all labeled nodes. Produces one combined restore report. |

### FileSystemApplicatonBackup.groovy

Four-stage pipeline:

1. **Validate node** — Ensures an agent exists with the label in `params.Environment` (20 s timeout).
2. **Validate disk space** — On all nodes with that label, verifies `ATA_HOME` is set and at least `params.REQUIRED_GB` GB are free; aborts if any node fails.
3. **Parallel backup** — On each node, runs SV1 config/table export (when applicable), builds the filesystem archive with `pigz`, and stashes per-node logs.
4. **Combine logs** — Unstashes all node logs and archives a single `BackupReport_${BUILD_NUMBER}.log` Jenkins artifact.

**Backup outputs (per node on the agent host):**

| Output | Location | When |
|--------|----------|------|
| Config items + SingleView table dumps | `$ATA_HOME/ConfigItemsBk_${BUILD_NUMBER}_$DATE/` | `ATA_INSTANCE=SV1` only |
| Filesystem archive | `$ATA_HOME/FSBackup_${BUILD_NUMBER}_$DATE.tar.gz` | All nodes |

**SV1: main SingleView tables and config items** — When `ATA_INSTANCE` is `SV1`, the pipeline creates `$ATA_HOME/ConfigItemsBk_${BUILD_NUMBER}_$DATE`, exports data into that folder, then continues with the filesystem backup.

*SingleView tables* (`da_dump` / `rt_dump` → CSV files):

| Command | Table / object |
|---------|----------------|
| `rt_dump` | `ATA_INSTANCE` |
| `da_dump` | `CE_PartitionResourceMapping` |
| `da_dump` | `ClusterResource` |
| `da_dump` | `ClusterStandby` |
| `da_dump` | `CustomerPartition` |
| `da_dump` | `CustomerPartitionRange` |
| `da_dump` | `EventErrorPartitionMap` |
| `da_dump` | `EventErrorPartitionRange` |
| `da_dump` | `EventPartitionRange` |
| `da_dump` | `InstanceGroup` |
| `da_dump` | `InstanceGroupMap` |
| `da_dump` | `InstanceStatus` |
| `da_dump` | `InstanceTypeGateway` |
| `da_dump` | `ScheduleReplicationGroup` |

*Config items* — `cfg -x config_items.ini` exports configuration items into the same `ConfigItemsBk_*` directory.

**Filesystem backup (all nodes)** — After the SV1 step (if applicable), copies a versioned `.profile` and builds `FSBackup_${BUILD_NUMBER}_$DATE.tar.gz` under `ATA_HOME` using parallel gzip (`pigz -p 4 -9`). Excludes logs, archives, releases, invoices, output paths, and other entries defined in the pipeline.

**Job parameters:**

| Parameter | Purpose |
|-----------|---------|
| `Environment` | Jenkins label for the target environment (e.g. prod, preprod) |
| `REQUIRED_GB` | Minimum free space required under `ATA_HOME` |

**Agent environment variables:**

| Variable | Purpose |
|----------|---------|
| `ATA_HOME` | Root of the SingleView installation (required) |
| `ATA_INSTANCE` | Instance identifier; when `SV1`, triggers table dumps and config export |

**Jenkins artifact:** `BackupReport_${BUILD_NUMBER}.log` (combined report from all nodes).

---

### FileSystemApplicatonRestore.groovy

Four-stage pipeline:

1. **Validate node** — Ensures an agent exists with the label in `params.Environment` (20 s timeout).
2. **Validate disk space and archive** — On each labeled node, verifies `ATA_HOME`, confirms `$ATA_HOME/$RESTORE_FILE` exists, and checks free space ≥ `REQUIRED_GB`; aborts with per-node reasons on failure.
3. **Parallel restore** — On each node, removes existing application directories (`admin`, `data`, `imp`, env files, etc.), extracts the restore archive with `pigz -dc`, and stashes per-node logs. **This stage performs a destructive restore** — stop application services before running in production.
4. **Combine logs** — Archives a single `Restore_Report_${BUILD_NUMBER}.log` Jenkins artifact.

**Job parameters:**

| Parameter | Purpose |
|-----------|---------|
| `Environment` | Jenkins label for the target environment |
| `REQUIRED_GB` | Minimum free space under `ATA_HOME` before restore |
| `RESTORE_FILE` | Filename of the backup tarball under `ATA_HOME` (e.g. `FSBackup_42_20250622.tar.gz`) |

**Agent environment variables:**

| Variable | Purpose |
|----------|---------|
| `ATA_HOME` | Root of the SingleView installation (required) |
| `ATA_INSTANCE` | Logged in reports; optional for restore logic |

**Jenkins artifact:** `Restore_Report_${BUILD_NUMBER}.log` (combined report from all nodes).

**Operational notes:**

- The restore archive must already exist on each node at `$ATA_HOME/$RESTORE_FILE` (typically produced by the backup pipeline).
- Stage 3 deletes listed directories under `ATA_HOME` before extraction. Coordinate application shutdown and post-restore validation (for example [`PrePostReleaseScript`](#prepostreleasescript)) before and after use.
- SV1 config/table backups (`ConfigItemsBk_*`) are separate from the filesystem tarball; restore those manually if required.

---

## Shell scripts

| Script | Path | Description |
|--------|------|-------------|
| Pre/post-release health checks | [`scripts/PrePostReleaseScript/PrePost_Release_Health_Checks.sh`](scripts/PrePostReleaseScript/PrePost_Release_Health_Checks.sh) | Orchestrator run **manually from SV1**. Discovers cluster instances via `da_dump InstanceStatus`, SSHs to each node, runs SingleView and Oracle checks, and prints PASS / WARN / FAIL with a release go/no-go summary. |
| Health check thresholds | [`scripts/PrePostReleaseScript/health_check.conf`](scripts/PrePostReleaseScript/health_check.conf) | Numeric thresholds sourced by the health check script (disk, memory, Oracle latency, tablespace usage, long-running SQL). |

### PrePostReleaseScript

**Where to run:** SV1 SingleView Linux server, logged in as the environment user. This version is **not** designed for Jenkins.

```bash
cd /path/to/scripts/PrePostReleaseScript
chmod +x PrePost_Release_Health_Checks.sh
./PrePost_Release_Health_Checks.sh health_check.conf
```

**Log output:** Each run creates `Validation_Checks_YYYYMMDD_HHMMSS.log` in the **current working directory**. The file persists after the script ends and contains the full check output and summary.

**Configurable thresholds** (in `health_check.conf`):

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_ATA_HOME_FREE_PCT` | 30 | Minimum free disk under `$ATA_HOME` (%) |
| `MIN_TMP_FREE_PCT` | 40 | Minimum free disk under `/tmp` (%) |
| `MIN_MEM_AVAILABLE_PCT` | 40 | Minimum available system memory (%) |
| `MAX_TNSPING_LATENCY_MS` | 200 | Maximum Oracle Net latency (ms) |
| `MAX_TABLESPACE_USED_PCT` | 80 | Maximum Oracle tablespace usage (%) |
| `ORASQL_EXEC_LIMIT` | 300 | Flag SQL at or above this duration (seconds) |

**Release decision:**

| Result | Action |
|--------|--------|
| Any FAIL | Do not install release until resolved |
| WARN only | May proceed; review warnings |
| All PASS | Release can be installed |

Full check list, topology matrix, and troubleshooting: [`scripts/PrePostReleaseScript/README.md`](scripts/PrePostReleaseScript/README.md).

---

## Using a pipeline in Jenkins

1. Create a **Pipeline** job (one job per pipeline file).
2. Under *Pipeline script from SCM*, set the repository URL and script path (for example `jenkins/pipelines/FileSystemApplicatonBackup.groovy`).
3. Define the job parameters (`Environment`, `REQUIRED_GB`, and for restore also `RESTORE_FILE`).
4. Ensure agents have `ATA_HOME` (and `ATA_INSTANCE` where needed) configured in the node environment.

## Adding new automation

1. Place Jenkins pipelines under `jenkins/pipelines/` and standalone scripts under `scripts/<name>/`.
2. Update this README: folder table (if new top-level folder), Jenkins pipelines table, and shell scripts table.
3. Commit and push to the remote repository.

## General requirements

| Area | Requirements |
|------|----------------|
| Jenkins | Access to Jenkins with nodes labeled by environment (`Environment` parameter) |
| Backup / restore | `tar`, `pigz`, `df`, `du`, and a POSIX shell on agents |
| SV1 backup | `rt_dump`, `da_dump`, and `cfg` on the agent PATH |
| Permissions | Read/write on `ATA_HOME` on agents (restore requires write and deletes directories) |
| Health checks | Run from **SV1** on Linux; passwordless SSH to cluster nodes; `ksh` on remotes; SingleView and Oracle utilities (`svstatus`, `cache_check`, `orasize`, `dbverify`, `orasql`, `tnsping`, `sqlplus`) |

## License

Internal use for the Mobily project unless another license is specified in this repository.
