pipeline {
    agent none

    environment {
        TF_PLUGIN_CACHE_DIR = '/var/lib/jenkins/.terraform.d/plugin-cache'
        SLACK_CHANNEL       = 'infrastructure-alerts'
    }

    stages {
        stage('Prepare Build Agents') {
            steps {
                script {
                    def prepareStages = [:]
                    3.times { i ->
                        prepareStages["Prepare Agent ${i+1}"] = {
                            node('ec2-fleet-agent') {
                                try {
                                    stage('Setup OpenTofu / Terraform') { 
                                       sh '''#!/bin/bash -xe
                                           if ! command -v tofu &> /dev/null; then
                                             echo "ERROR: OpenTofu binary not found"
                                             exit 1
                                           fi
                                           echo "Engine version: $(tofu --version)"
                                        '''
                                    }

                                    stage('Setup SSH & Credentials') {
                                        retry(3) {
                                            setupBaseCredentials()
                                            setupSSHForIaC()
                                            refreshAWSCredentials()
                                        }
                                    }

                                    sh "echo 'Agent ready' > ${env.WORKSPACE}/.agent_ready"
                                } catch (Exception e) {
                                    echo "Failed agent setup: ${e.getMessage()}"
                                    currentBuild.result = 'UNSTABLE'
                                    error("Agent pool preparation failed")
                                }
                            }
                        }
                    }
                    parallel prepareStages
                }
            }
        }

        stage('Parallel Account Drift Processing') {
            steps {
                script {
                    def targetAccounts = ['staging', 'development', 'production', 'marketing', 'datascience']

                    def parallelStages = [
                        'staging': {
                            node('ec2-fleet-agent') {
                                processAccount('staging')
                                stash includes: "infrastructure/terraform/staging/**/drift_results.txt", name: "staging-drift"
                            }
                        },
                        'production': {
                            node('ec2-fleet-agent') {
                                processAccount('production')
                                stash includes: "infrastructure/terraform/production/**/drift_results.txt", name: "production-drift"
                            }
                        },
                        'secondary_accounts': {
                            node('ec2-fleet-agent') {
                                targetAccounts.findAll { it != 'staging' && it != 'production' }.each { account ->
                                    processAccount(account)
                                    stash includes: "infrastructure/terraform/${account}/**/drift_results.txt", name: "${account}-drift"
                                }
                            }
                        }
                    ]

                    parallel parallelStages
                }
            }
        }

        stage('Aggregate Findings & Notify Slack') {
            agent { label 'ec2-fleet-agent' }
            steps {
                script {
                    def accounts = ['staging', 'development', 'production', 'marketing', 'datascience']
                    def summaryStats = [:]
                    def allResults = [:]
                    def problemsOutput = [:]

                    accounts.each { account ->
                        summaryStats[account] = [total: 0, no_drift: 0, with_drift: 0, errors: 0, failed: 0]
                        allResults[account] = [:]
                        problemsOutput[account] = []

                        try {
                            unstash "${account}-drift"
                            def accountDir = "${env.WORKSPACE}/infrastructure/terraform/${account}"
                            def findOutput = sh(script: "find ${accountDir} -name drift_results.txt -type f 2>/dev/null || true", returnStdout: true).trim()
                            def resultFiles = findOutput ? findOutput.readLines().findAll { it?.trim() } : []

                            if (!resultFiles) {
                                summaryStats[account].failed++
                                problemsOutput[account] << "ERROR: No drift results retrieved"
                            } else {
                                resultFiles.each { filePath ->
                                    def dirName = filePath.replace("${accountDir}/", "").replace("/drift_results.txt", "")
                                    def content = readFile(filePath)?.trim() ?: "EMPTY"
                                    def filteredContent = filterIaCOutput(content)
                                    def status = classifyDriftStatus(content)

                                    summaryStats[account].total++
                                    summaryStats[account][status]++
                                    allResults[account][dirName] = [status: status, content: filteredContent]

                                    if (status in ['with_drift', 'errors', 'failed']) {
                                        problemsOutput[account] << "${status == 'with_drift' ? 'Drift detected' : 'Execution error'} in module [${dirName}]"
                                    }
                                }
                            }
                        } catch (Exception e) {
                            summaryStats[account].failed++
                            problemsOutput[account] << "CRITICAL: Stash processing failure: ${e.message}"
                        }
                    }

                    def formattedText = generateTextReport(summaryStats, allResults)
                    def problemsText = generateProblemsReport(problemsOutput)

                    writeFile file: 'drift_summary.txt', text: formattedText
                    writeFile file: 'drift_problems.txt', text: problemsText
                    archiveArtifacts artifacts: 'drift_summary.txt, drift_problems.txt'

                    def hasProblems = summaryStats.any { _, s -> s.with_drift > 0 || s.errors > 0 || s.failed > 0 }
                    currentBuild.result = hasProblems ? 'UNSTABLE' : 'SUCCESS'

                    if (hasProblems) {
                        def summaryTable = new StringBuilder()
                        summaryTable << "```\nAccount        Total  Clean%  Drift  Errors\n---------------------------------------------\n"
                        summaryStats.each { acc, s ->
                            def cleanPct = s.total > 0 ? (s.no_drift / s.total * 100).toInteger() : 0
                            summaryTable << "${acc.padRight(14)} ${s.total.toString().padLeft(6)} ${(cleanPct.toString() + '%').padLeft(7)} ${s.with_drift.toString().padLeft(6)} ${s.errors.toString().padLeft(7)}\n"
                        }
                        summaryTable << "```"

                        try {
                            withCredentials([string(credentialsId: 'slack-webhook-token', variable: 'SLACK_TOKEN')]) {
                                slackSend(
                                    channel: "#${env.SLACK_CHANNEL}",
                                    color: 'warning',
                                    message: ":warning: *Multi-Account Infrastructure Drift Detected - Job #${env.BUILD_NUMBER}*\n${summaryTable.toString()}\n*Artifacts:* <${env.BUILD_URL}artifact/drift_summary.txt\vert{}Full Summary> \vert{} <${env.BUILD_URL}artifact/drift_problems.txt|Problem Modules>",
                                    token: env.SLACK_TOKEN,
                                    username: 'OpenTofu Drift Guardian',
                                    iconEmoji: ':terraform:'
                                )
                            }
                        } catch (Exception e) {
                            echo "Slack notification failed: ${e.message}"
                        }
                    }
                }
            }
        }
    }
}

def processAccount(account) {
    stage("Scan Account: ${account}") {
        dir("${env.WORKSPACE}/infrastructure/terraform/${account}") {
            withEnv(["AWS_PROFILE=${account}", "TG_TF_PATH=tofu"]) {
                sh '''#!/bin/bash -xe
                    eval $(ssh-agent -s)
                    ssh-add ~/.ssh/id_rsa
                    
                    find . -mindepth 1 -maxdepth 1 -type d ! -name 'config' | while read dir; do
                        if [ -f "$dir/terragrunt.hcl" ] \vert{}\vert{} [ -f "$dir/main.tf" ]; then
                            mkdir -p "$dir"
                            (cd "$dir" && {
                                set +e
                                tofu init -input=false > init.log 2>&1
                                tofu plan -lock=false -no-color -detailed-exitcode > plan.log 2>&1
                                plan_status=$?
                                set -e

                                cat init.log plan.log > drift_results.txt
                                echo "=== DRIFT STATUS ===" >> drift_results.txt
                                case $plan_status in
                                    0) echo "STATUS: NO_DRIFT" >> drift_results.txt ;;
                                    1) echo "STATUS: ERROR" >> drift_results.txt ;;
                                    2) echo "STATUS: DRIFT_DETECTED" >> drift_results.txt ;;
                                    *) echo "STATUS: UNKNOWN" >> drift_results.txt ;;
                                esac
                            })
                        fi
                    done
                '''
            }
        }
    }
}

def setupBaseCredentials() {
    sh 'mkdir -p ~/.aws ~/.ssh /var/lib/jenkins/.terraform.d/plugin-cache'
}

def setupSSHForIaC() {
    sh 'touch ~/.ssh/id_rsa && chmod 600 ~/.ssh/id_rsa'
}

def refreshAWSCredentials() {
    sh '''
        cat > ~/.aws/config <<EOF
[default]
region = eu-west-1

[profile staging]
region = eu-west-1
role_arn = arn:aws:iam::111111111111:role/jenkins-drift-scanner
credential_source = Ec2InstanceMetadata

[profile production]
region = eu-west-1
role_arn = arn:aws:iam::222222222222:role/jenkins-drift-scanner
credential_source = Ec2InstanceMetadata

[profile development]
region = eu-west-1
role_arn = arn:aws:iam::333333333333:role/jenkins-drift-scanner
credential_source = Ec2InstanceMetadata
EOF
        chmod 600 ~/.aws/config
    '''
}

def classifyDriftStatus(String content) {
    if (!content) return "empty"
    def lc = content.toLowerCase()
    if (lc.contains('status: error') || lc.contains('error:')) return "errors"
    if (lc.contains('status: no_drift') || lc.contains('no changes')) return "no_drift"
    if (lc.contains('status: drift_detected') || lc.contains('will perform the following actions')) return "with_drift"
    return "unknown"
}

def filterIaCOutput(String content) {
    if (!content) return "EMPTY_CONTENT"
    return content.lines().filter { line ->
        line.contains('will perform') || line.contains('No changes') || line.contains('Error:') || line.contains('STATUS:')
    }.toList().join('\n')
}

def generateProblemsReport(problemsOutput) {
    def sb = new StringBuilder("=== DRIFT & EXECUTION ISSUES ===\n\n")
    problemsOutput.each { account, problems ->
        if (problems) {
            sb << "ACCOUNT: ${account.toUpperCase()}\n"
            problems.each { p -> sb << "  • ${p}\n" }
            sb << "\n"
        }
    }
    return sb.toString()
}

def generateTextReport(summaryStats, allResults) {
    def sb = new StringBuilder("=== MULTI-ACCOUNT DRIFT SUMMARY ===\n\n")
    summaryStats.each { acc, s ->
        sb << "${acc.padRight(15)} | Total: ${s.total} \vert{} Clean:${s.no_drift} | Drift: ${s.with_drift} \vert{} Errors:${s.errors}\n"
    }
    return sb.toString()
}
