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

        // Stage 2: Validate disk space on ALL nodes
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

                    for (n in nodes) {
                        def nodeName = n

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

                    if (failedNodes.size() > 0) {
                        error "Backup ABORTED. Nodes without required space: ${failedNodes}"
                    }

                    echo "All nodes have enough space. Proceeding to backup..."
                }
            }
        }

        // Stage 3: Backup in parallel all nodes
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
                                        CONFIG_BK_DIR="ConfigItemsBk_${BUILD_NUMBER}_\$DATE"

                                        if [ "\${ATA_INSTANCE}" = "SV1" ]; then
                                            echo "ATA_INSTANCE=SV1: backing up config items to \$CONFIG_BK_DIR"
                                            mkdir -p "\$ATA_HOME/\$CONFIG_BK_DIR"
                                            cd "\$ATA_HOME/\$CONFIG_BK_DIR"

                                            rt_dump -f ATA_INSTANCE.csv ATA_INSTANCE 2>&1
                                            da_dump -f CE_PartitionResourceMapping.csv CE_PartitionResourceMapping 2>&1
                                            da_dump -f ClusterResource.csv ClusterResource 2>&1
                                            da_dump -f ClusterStandby.csv ClusterStandby 2>&1
                                            da_dump -f CustomerPartition.csv CustomerPartition 2>&1
                                            da_dump -f CustomerPartitionRange.csv CustomerPartitionRange 2>&1
                                            da_dump -f EventErrorPartitionMap.csv EventErrorPartitionMap 2>&1
                                            da_dump -f EventErrorPartitionRange.csv EventErrorPartitionRange 2>&1
                                            da_dump -f EventPartitionRange.csv EventPartitionRange 2>&1
                                            da_dump -f InstanceGroup.csv InstanceGroup 2>&1
                                            da_dump -f InstanceGroupMap.csv InstanceGroupMap 2>&1
                                            da_dump -f InstanceStatus.csv InstanceStatus 2>&1
                                            da_dump -f InstanceTypeGateway.csv InstanceTypeGateway 2>&1
                                            da_dump -f ScheduleReplicationGroup.csv ScheduleReplicationGroup 2>&1
                                            cfg -x config_items.ini 2>&1

                                            cd "\$ATA_HOME"
                                            {
                                            echo "============================="
                                            echo "  CONFIG ITEMS BACKUP (SV1)"
                                            echo "  Directory : \$ATA_HOME/\$CONFIG_BK_DIR"
                                            echo "============================="
                                            } >> "\$LOG"
                                        fi

                                        cp .profile profile_${BUILD_NUMBER}_\$DATE

                                        tar --ignore-failed-read \
                                            --exclude='data/server/archive/*' \
                                            --exclude='data/server/log/*' \
                                            --exclude='data/server/log.old/*' \
                                            --exclude='data/server/config/tomcat/logs/*' \
                                            --exclude='data/server/invoices/*' \
                                            --exclude='data/server/output/*' \
                                            --exclude='admin/releases/*' \
                                            --exclude='sv/*.tar.gz' \
                                            --exclude="*.sok" \
                                            -zcf "\$ATA_HOME/\$FILE" \
                                            .cvsignore .gsenv .orapathenv .perlenv \
                                            diameterenv kafkaenv svhaenv pxenv \
                                            cmuplift admin csg_view CVS data diameter \
                                            kafka imp rel px svt \
                                            profile_${BUILD_NUMBER}_\$DATE \
                                            sv/\$(svversion | awk 'FNR==3') \
                                            *env || true

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