pipeline {
    agent none
    
    stages {

        // ✅ Stage 1: Validate node availability
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

        // ✅ Stage 2: Validate disk space on ALL nodes
        stage('Stage 2: Validate disk space on ALL nodes') {
            steps {
                script {

                    def nodes = []

                    Jenkins.instance.nodes.each { n ->
                        if (n.getLabelString().contains(params.Environment)) {
                            nodes << n.getNodeName()
                        }
                    }

                    echo "Nodes found: ${nodes}"

                    def failedNodes = []

                    // 🔎 VALIDATION
                    for (n in nodes) {
                        def nodeName = n   // ✅ FIX

                        node(nodeName) {
                            def status = sh(
                                script: """
                                    HOST=\$(hostname)
                                    INST="\${ATA_INSTANCE:-<not set>}"
                                    LOG="\$WORKSPACE/artifact_${nodeName}.log"
                                    if [ -z "\${ATA_HOME:-}" ]; then
                                        exit 2
                                    fi

                                    AVAILABLE_GB=\$(df -BG "\$ATA_HOME" | awk 'NR==2 {gsub("G","",\$4); print \$4}')

                                    {
                                    echo "=============================="
                                    echo "  Hostname     : \${HOST}"
                                    echo "  ATA_INSTANCE : \${INST}"
                                    echo "  Jenkins node : ${nodeName}"
                                    echo "  ATA_HOME     : \$ATA_HOME"
                                    echo "  Available    : \${AVAILABLE_GB} GB (required: ${params.REQUIRED_GB} GB)"
                                    echo "=============================="
                                    } > "\$LOG"
                                    
                                    if [ "\$AVAILABLE_GB" -lt "${params.REQUIRED_GB}" ]; then
                                        exit 1
                                    fi

                                    exit 0
                                """,
                                returnStatus: true
                            )

                            if (status != 0) {
                                failedNodes << nodeName
                            }
                        }
                    }

                    // ❌ Abort if any node fails
                    if (failedNodes.size() > 0) {
                        error "Backup ABORTED. Nodes without required space: ${failedNodes}"
                    }

                    echo "All nodes have enough space. Proceeding to backup..."
                }
            }
        }
   
        // ✅ Stage 3: Backup in parallel all nodes
        stage('Stage 3: Backup in parallel all nodes') {
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

                                timeout(time: 3, unit: 'HOURS') {

                                    sh """
                            
                                        HOST=\$(hostname)
                                        INST="\${ATA_INSTANCE:-<not set>}"
                                        LOG="\$WORKSPACE/artifact_${nodeName}.log"

                                        echo "Running backup on ${nodeName}"

                                        trap "echo 'Stopping backup'; kill 0; exit 1" TERM INT

                                        if [ -z "\${ATA_HOME:-}" ]; then
                                            echo "ERROR: ATA_HOME not defined"
                                            exit 1
                                        fi

                                        cd "\$ATA_HOME"

                                        DATE=\$(date +%Y%m%d)
                                        FILE="FSBackup_${BUILD_NUMBER}_\$DATE.tar.gz"

                                        cp .profile profile_${BUILD_NUMBER}_\$DATE

                                        tar --ignore-failed-read \
                                            --exclude='data/server/archive/*' \
                                            --exclude='data/server/log/*' \
                                            --exclude='data/server/log.old/*' \
                                            --exclude='data/server/config/tomcat/logs/*' \
                                            --exclude='admin/releases/*' \
                                            --exclude='sv/*.tar.gz' \
                                            --exclude="*.sok" \
                                            -zcf "\$FILE" \
                                            .cvsignore .gsenv .orapathenv .perlenv \
                                            diameterenv kafkaenv svhaenv pxenv \
                                            cmuplift admin csg_view CVS data diameter \
                                            kafka imp rel px  svt \
                                            profile_${BUILD_NUMBER}_\$DATE \
                                            sv/\$(svversion | awk 'FNR==3') \
                                            *env

                                        echo "Backup finished on ${nodeName}"
                                        ls -lh "\$ATA_HOME/\$FILE"

                                        SIZE=\$(ls -lh "\$ATA_HOME/\$FILE" 2>/dev/null | awk '{print \$5}')
                                        {
                                        echo "============================="
                                        echo "  BACKUP COMPLETED"
                                        echo "  Date          : \$(date '+%Y-%m-%d %H:%M:%S')"
                                        echo "  Archive file  : \$FILE"
                                        echo "  Full path     : \$ATA_HOME/\$FILE"
                                        echo "  Size          : \${SIZE:-unknown}"
                                        echo "============================="
                                        echo ""
                                        } >> "\$LOG"
                                    """
                                }
                            }
                        }
                    }

                    // ✅ CORRECT PLACE
                    parallel branches
                }
            }
        }

    }

    post {
        success {
            echo 'Backup stage completed'
            script {
                def nodes = []
                Jenkins.instance.nodes.each { n ->
                    if (n.getLabelString().contains(params.Environment)) {
                        nodes << n.getNodeName()
                    }
                }
                // 📦 Archive artifacts from EACH node
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
            echo 'Validation failed'
        }      
    }
}
