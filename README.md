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
| [`jenkins/pipelines/FileSystemApplicatonBackup.groovy`](jenkins/pipelines/FileSystemApplicatonBackup.groovy) | **Application filesystem backup** pipeline on Jenkins nodes tagged by environment. Validates node availability, checks disk space on all nodes with the label, and runs backup in parallel. |

#### FileSystemApplicatonBackup.groovy

Three-stage pipeline:

1. **Validate node** — Ensures an agent exists with the label in `params.Environment` (20 s timeout).
2. **Validate disk space** — On all nodes with that label, verifies `ATA_HOME` is set and at least `params.REQUIRED_GB` GB are free; aborts if any node fails.
3. **Parallel backup** — On each node, optionally dumps config items when `ATA_INSTANCE=SV1`, then creates a `.tar.gz` of the application tree (excluding logs, archives, and releases per script rules), copies a versioned `.profile`, and archives logs as Jenkins artifacts.

**SV1 config items backup** (branch `backup_pipeline`): when `ATA_INSTANCE` is `SV1`, the pipeline creates `$ATA_HOME/ConfigItemsBk_${BUILD_NUMBER}_$DATE`, runs `rt_dump`, `da_dump`, and `cfg -x config_items.ini` into that folder, then continues with the filesystem `.tar.gz` written to `$ATA_HOME`.

**Expected parameters (example):**

| Parameter | Purpose |
|-----------|---------|
| `Environment` | Jenkins label for the environment (e.g. prod, preprod) |
| `REQUIRED_GB` | Minimum free space required under `ATA_HOME` |

**Agent environment variables:**

- `ATA_HOME` — Root of the installation to back up (required).
- `ATA_INSTANCE` — Optional; recorded in logs.

**Post actions:** on success, archives `*.log` from each node; on failure or abort, informative console messages.

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
- Read permissions on `ATA_HOME` on agents.

## License

Internal use for the Mobily project unless another license is specified in this repository.
