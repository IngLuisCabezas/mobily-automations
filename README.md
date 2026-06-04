# Mobily — Automations

Repository of automation scripts and pipelines for the **Mobily** project. Scripts developed across environments (Jenkins, shell, etc.) are published here incrementally.

## Repository structure

```
mobily_project/
├── README.md
├── jenkins/
│   └── pipelines/          # Jenkins declarative pipelines
└── scripts/                # Standalone scripts (bash, Python, etc.)
```

| Folder | Contents |
|--------|----------|
| `jenkins/pipelines/` | Jenkins jobs (Groovy, declarative pipeline) |
| `scripts/` | Standalone scripts (bash, Python, etc.) |

## Included scripts

### Jenkins

| Script | Description |
|--------|-------------|
| [`jenkins/pipelines/FileSystemApplicatonBackup.groovy`](jenkins/pipelines/FileSystemApplicatonBackup.groovy) | **Application filesystem backup** on Jenkins nodes tagged by environment. Validates node availability and disk space, then runs backup in parallel. On SV1 nodes, also exports main SingleView tables and config items before creating the filesystem archive in `ATA_HOME`. |

#### FileSystemApplicatonBackup.groovy

Three-stage pipeline:

1. **Validate node** — Ensures an agent exists with the label in `params.Environment` (20 s timeout).
2. **Validate disk space** — On all nodes with that label, verifies `ATA_HOME` is set and at least `params.REQUIRED_GB` GB are free; aborts if any node fails.
3. **Parallel backup** — On each node, runs the backup steps below in order, then archives Jenkins logs as artifacts.

**Backup outputs (per node):**

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

**Filesystem backup (all nodes)** — After the SV1 step (if applicable), copies a versioned `.profile` and builds `FSBackup_${BUILD_NUMBER}_$DATE.tar.gz` under `ATA_HOME`, excluding logs, archives, releases, and other paths defined in the pipeline.

**Expected parameters (example):**

| Parameter | Purpose |
|-----------|---------|
| `Environment` | Jenkins label for the environment (e.g. prod, preprod) |
| `REQUIRED_GB` | Minimum free space required under `ATA_HOME` |

**Agent environment variables:**

- `ATA_HOME` — Root of the installation to back up (required).
- `ATA_INSTANCE` — Instance identifier; when set to `SV1`, triggers SingleView table dumps and config items export (required for SV1 backup).

**Post actions:** on success, archives `*.log` from each node; on failure or abort, informative console messages.

### Shell scripts

| Script | Description |
|--------|-------------|
| [`scripts/PrePostReleaseScript/`](scripts/PrePostReleaseScript/) | **Pre- and post-release health checks** for SingleView clusters. Discovers instances via `da_dump`, runs application, Oracle, and system checks on each node over SSH, and reports PASS / WARN / FAIL with a release go/no-go summary. Thresholds are configured in `health_check.conf`. |

#### PrePostReleaseScript

Run from a SingleView environment account:

```bash
./scripts/PrePostReleaseScript/PrePost_Release_Health_Checks.sh scripts/PrePostReleaseScript/health_check.conf
```

**Outputs:** timestamped log `Validation_Checks_YYYYMMDD_HHMMSS.log` in the working directory.

**Configurable thresholds** (in `health_check.conf`): `$ATA_HOME` and `/tmp` free space, available memory, Oracle TNS latency, tablespace usage, and long-running SQL duration.

**Release decision:**

| Result | Action |
|--------|--------|
| Any FAIL | Do not install release until resolved |
| WARN only | May proceed; review warnings |
| All PASS | Release can be installed |

Full check list, topology matrix, and troubleshooting: [`scripts/PrePostReleaseScript/README.md`](scripts/PrePostReleaseScript/README.md).

## Using a pipeline in Jenkins

1. Create a **Pipeline** job.
2. Under *Pipeline script from SCM* or *Pipeline script*, point to `jenkins/pipelines/<name>.groovy`.
3. Define parameters `Environment` and `REQUIRED_GB` on the job.
4. Ensure agents have `ATA_HOME` (and optionally `ATA_INSTANCE`) configured.

## Adding a new script

1. Place the file in the appropriate folder (`jenkins/pipelines/`, `scripts/`, etc.).
2. Update the **Included scripts** table in this README with name, path, and a short description.
3. Commit and push to GitHub.

## General requirements

- Access to Jenkins with nodes labeled by environment.
- For backup pipelines: `tar`, `df`, and a shell compatible with the script checks.
- On SV1 nodes: `rt_dump`, `da_dump`, and `cfg` available on the agent PATH.
- Read permissions on `ATA_HOME` on agents.
- For pre/post-release health checks: SSH access between cluster nodes, `ksh` on remote hosts, and Oracle/SingleView utilities on each node (`svstatus`, `cache_check`, `orasize`, `dbverify`, `orasql`, `tnsping`, `sqlplus`).

## License

Internal use for the Mobily project unless another license is specified in this repository.
