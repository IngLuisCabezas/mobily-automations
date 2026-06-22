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
                                    echo "  Hostname       : \${HOST}"
                                    echo "  ATA_INSTANCE   : \${INST}"
                                    echo "  Jenkins node   : ${nodeName}"
                                    echo "  ATA_HOME       : \$ATA_HOME"
                                    echo "  Restore archive: \$RESTORE_PATH"
                                    echo "  Archive size   : \${ARCHIVE_GB} GB (compressed)"
                                    echo "  Available      : \${AVAILABLE_GB} GB (required: ${params.REQUIRED_GB} GB)"
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

        // Stage 3: Fylesystem respote process
        stage('Stage 3: FilesystemRestore process') {
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
                                        cd "\$ATA_HOME" || exit 1

                                        echo "=== Restore archive on server ==="
                                        ls -larth "\$RESTORE_PATH"

                                        AVAILABLE_GB=\$(df -BG "\$ATA_HOME" | awk 'NR==2 {gsub("G","",\$4); print \$4}')
                                        ARCHIVE_GB=\$(du -BG "\$RESTORE_PATH" | awk '{gsub("G","",\$1); print \$1}')
                                        SIZE_H=\$(ls -lh "\$RESTORE_PATH" 2>/dev/null | awk '{print \$5}')

                                        {
                                        echo "  Restore started  : \$(date '+%Y-%m-%d %H:%M:%S')"
                                        } >> "\$LOG"
                                        echo "--- Restore commands ---"
                                        ls -arlthd  admin data imp cmuplift CVS rel sv svhaenv kafka kafkaenv px pxenv diameter diameterenv  .orapathenv .perlenv .gsenv .cvsignore || true
                                        rm -rf admin data imp cmuplift CVS rel sv svhaenv kafka kafkaenv px pxenv diameter diameterenv  .orapathenv .perlenv .gsenv .cvsignore || true
										echo "--- Remove done ---"
										tar -I "pigz -dc" -xf  "\$RESTORE_FILE"
										ls -arlthd  admin data imp cmuplift CVS rel sv svhaenv kafka kafkaenv px pxenv diameter diameterenv  .orapathenv .perlenv .gsenv .cvsignore || true
										echo "--- un tar done ---"
                                        {
                                        echo "  Restore finished  : \$(date '+%Y-%m-%d %H:%M:%S')"
                                        } >> "\$LOG"                                  
								  """
                                    stash name: "backup-log-${nodeName}",
                                    includes: "artifact_${nodeName}.log",
                                    allowEmpty: true

                                }
                            }
                        }
                    }

                    parallel branches
                }
            }
        }

        // Stage 4: Combine all node logs into one Jenkins artifact
        stage('Stage 4: Combine logs into one artifact') {
            steps {
                script {
                    def nodes = []
                    Jenkins.instance.nodes.each { n ->
                        if (n.getLabelString().contains(params.Environment)) {
                            nodes << n.getNodeName()
                        }
                    }

                    def combinedLog = "Restore_Report_${BUILD_NUMBER}.log"

                    node("${params.Environment}") {
                        sh """
                            rm -f ${combinedLog}
                            {
                            echo "=========================================="
                            echo "  COMBINED RESTORE REPORT"
                            echo "  Build        : ${BUILD_NUMBER}"
                            echo "  Environment  : ${params.Environment}"
                            echo "  Generated    : \$(date '+%Y-%m-%d %H:%M:%S')"
                            echo "  Nodes        : ${nodes.join(', ')}"
                            echo "=========================================="
                            echo ""
                            } > ${combinedLog}
                        """

                        for (n in nodes) {
                            unstash "backup-log-${n}"
                            sh """
                                {
                                echo "=========================================="
                                echo "  NODE: ${n}"
                                echo "=========================================="
                                cat artifact_${n}.log 2>/dev/null || echo "(no log found for ${n})"
                                echo ""
                                } >> ${combinedLog}
                                rm -f artifact_${n}.log
                            """
                        }

                        archiveArtifacts artifacts: "${combinedLog}", fingerprint: true
                    }
                }
            }
        }
    }

  post {
        success {
            echo 'Restore stage completed — combined log archived in Stage 4'
        }

        aborted {
            echo 'Node not available or timeout reached'
        }

        failure {
            echo 'Validation failed'
        }
    }
}
