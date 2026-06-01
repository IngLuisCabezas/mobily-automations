pipeline {
    agent none

    stages {

        // Stage 1: Validate node availability
        stage('Stage 1: Validate node availability') {
            steps {
                script {
                    try {
                        timeout(time: 20, unit: 'SECONDS') {
                            node("${params.Environment}") {
                                echo "Node with label ${params.Environment} allocated"
                            }
                        }
                    } catch (err) {
                        error "No available node for label ${params.Environment} within 20 seconds"
                    }
                }
            }
        }

        // Stage 2: Validate REQUIRED_GB disk space and restore archive on all nodes
        stage('Stage 2: Validate disk space and backup.tar.gz on all nodes') {
            steps {
                script {

                    def nodes = []

                    Jenkins.instance.nodes.each { n ->
                        if (n.getLabelString().contains(params.Environment)) {
                            nodes << n.getNodeName()
                        }
                    }

                    echo "Nodes found: ${nodes}"

                    def failedNodes = [:]

                    for (n in nodes) {
                        def nodeName = n

                        node(nodeName) {
                            def status = sh(
                                script: """
                                    HOST=\$(hostname)
                                    INST="\${ATA_INSTANCE:-<not set>}"
                                    LOG="\$WORKSPACE/artifact_${nodeName}.log"
                                    RESTORE_FILE="${params.RESTORE_FILE}"

                                    if [ -z "\${ATA_HOME:-}" ]; then
                                        exit 2
                                    fi

                                    RESTORE_PATH="\$ATA_HOME/\$RESTORE_FILE"
                                    if [ ! -f "\$RESTORE_PATH" ]; then
                                        exit 3
                                    fi

                                    AVAILABLE_GB=\$(df -BG "\$ATA_HOME" | awk 'NR==2 {gsub("G","",\$4); print \$4}')
                                    ARCHIVE_GB=\$(du -BG "\$RESTORE_PATH" | awk '{gsub("G","",\$1); print \$1}')

                                    {
                                    echo "=============================="
                                    echo "  RESTORE PRE-CHECK (Stage 2)"
                                    echo "  Hostname       : \${HOST}"
                                    echo "  ATA_INSTANCE   : \${INST}"
                                    echo "  Jenkins node   : ${nodeName}"
                                    echo "  ATA_HOME       : \$ATA_HOME"
                                    echo "  Restore archive: \$RESTORE_PATH"
                                    echo "  Archive size   : \${ARCHIVE_GB} GB (compressed)"
                                    echo "  Available      : \${AVAILABLE_GB} GB (required: ${params.REQUIRED_GB} GB)"
                                    echo "  Archive exists : yes"
                                    echo "=============================="
                                    } > "\$LOG"

                                    if [ "\$AVAILABLE_GB" -lt "${params.REQUIRED_GB}" ]; then
                                        exit 1
                                    fi

                                    exit 0
                                """,
                                returnStatus: true
                            )

                            if (status == 1) {
                                failedNodes[nodeName] = 'insufficient disk space for restore'
                            } else if (status == 2) {
                                failedNodes[nodeName] = 'ATA_HOME not set'
                            } else if (status == 3) {
                                failedNodes[nodeName] = "restore file not found (${params.RESTORE_FILE})"
                            } else if (status != 0) {
                                failedNodes[nodeName] = "check failed (exit ${status})"
                            }
                        }
                    }

                    if (failedNodes.size() > 0) {
                        error "Restore ABORTED. Failed nodes: ${failedNodes}"
                    }

                    echo "All nodes: agent available, restore archive present, and enough space for restore. Proceeding to pre-restore report..."
                }
            }
        }

        // Stage 3: Pre-restore report only (no rm, no untar) — restore commands commented for review
        stage('Stage 3: FilesystemRestore pre-check (no restore executed)') {
            steps {
                script {
                    def nodes = []

                    Jenkins.instance.nodes.each { n ->
                        if (n.getLabelString().contains(params.Environment)) {
                            nodes << n.getNodeName()
                        }
                    }

                    def branches = [:]

                    for (n in nodes) {
                        def nodeName = n

                        branches[nodeName] = {
                            node(nodeName) {

                                timeout(time: 1, unit: 'HOURS') {

                                    sh """
                                        HOST=\$(hostname)
                                        INST="\${ATA_INSTANCE:-<not set>}"
                                        LOG="\$WORKSPACE/artifact_${nodeName}.log"
                                        RESTORE_FILE="${params.RESTORE_FILE}"

                                        echo "FilesystemRestore pre-check on ${nodeName}"

                                        if [ -z "\${ATA_HOME:-}" ]; then
                                            echo "ERROR: ATA_HOME not defined"
                                            exit 1
                                        fi

                                        RESTORE_PATH="\$ATA_HOME/\$RESTORE_FILE"
                                        cd "\$ATA_HOME"

                                        echo "=== Restore archive on server ==="
                                        ls -larth "\$RESTORE_PATH"

                                        AVAILABLE_GB=\$(df -BG "\$ATA_HOME" | awk 'NR==2 {gsub("G","",\$4); print \$4}')
                                        ARCHIVE_GB=\$(du -BG "\$RESTORE_PATH" | awk '{gsub("G","",\$1); print \$1}')
                                        SIZE_H=\$(ls -lh "\$RESTORE_PATH" 2>/dev/null | awk '{print \$5}')

                                        {
                                        echo "============================="
                                        echo "  FILES SYSTEM RESTORE REPORT"
                                        echo "  (validation only — no files removed, no extract run)"
                                        echo "  Date             : \$(date '+%Y-%m-%d %H:%M:%S')"
                                        echo "  Hostname         : \${HOST}"
                                        echo "  ATA_INSTANCE     : \${INST}"
                                        echo "  Jenkins node     : ${nodeName}"
                                        echo "  ATA_HOME         : \$ATA_HOME"
                                        echo "  Restore archive  : \$RESTORE_PATH"
                                        echo "  Archive size     : \${SIZE_H:-unknown} (\${ARCHIVE_GB} GB compressed)"
                                        echo "  Available space  : \${AVAILABLE_GB} GB (required: ${params.REQUIRED_GB} GB)"
                                        echo "  Ready to restore : yes (checks passed)"
                                        echo "============================="
                                        echo ""
                                        echo "  --- Restore commands (NOT executed; uncomment when approved) ---"
                                        echo "  # cd \"\$ATA_HOME\""
                                        echo "  # tar -xzf \"\$RESTORE_PATH\""
                                        echo "  #"
                                        echo "  # Optional: stop application services before restore, then start after."
                                        echo "  # Optional SV1: restore ConfigItemsBk_* CSV/config from separate backup if used."
                                        echo "  --- End commented restore ---"
                                        echo ""
                                        } >> "\$LOG"

                                        echo "============================="
                                        echo "  FILES SYSTEM RESTORE REPORT"
                                        echo "  (validation only — no files removed, no extract run)"
                                        echo "  Restore archive  : \$RESTORE_PATH"
                                        echo "  Archive size     : \${SIZE_H:-unknown}"
                                        echo "  Available space  : \${AVAILABLE_GB} GB (required: ${params.REQUIRED_GB} GB)"
                                        echo "============================="
                                        echo ""
                                        echo "--- Restore commands (NOT executed; uncomment when approved) ---"
                                        echo "# cd \"\$ATA_HOME\""
                                        echo "# tar -xzf \"\$RESTORE_PATH\""
                                        echo "#"
                                        echo "# Optional: stop application services before restore, then start after."
                                        echo "--- End commented restore ---"
                                    """
                                }
                            }
                        }
                    }

                    parallel branches
                }
            }
        }

    }

    post {
        success {
            echo 'FilesystemRestore validation completed'
            script {
                def nodes = []
                Jenkins.instance.nodes.each { n ->
                    if (n.getLabelString().contains(params.Environment)) {
                        nodes << n.getNodeName()
                    }
                }
                for (n in nodes) {
                    node(n) {
                        archiveArtifacts artifacts: '*.log', fingerprint: true, allowEmptyArchive: true
                    }
                }
            }
        }

        aborted {
            echo 'Node not available or timeout reached'
        }

        failure {
            echo 'FilesystemRestore validation failed'
        }
    }
}
