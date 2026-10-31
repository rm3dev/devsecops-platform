import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy

/**
 * THE standard microservice pipeline (master spec §8/§9).
 * Every service repository uses this single entry point:
 *
 *   @Library('devsecops-shared-library') _
 *   microservicePipeline(
 *       serviceName: 'payment-service',
 *       deploymentType: 'helm',
 *       environments: ['dev', 'qa', 'uat', 'prod']
 *   )
 *
 * Stage enablement is driven by config/platform-config.yaml flags. As delivery
 * phases land, flags flip and stages activate WITHOUT touching any repository's
 * Jenkinsfile — that is the incremental-enablement contract of this platform.
 *
 * args:
 *   serviceName    (required) logical service name
 *   deploymentType helm|kustomize (default from platform config)
 *   environments   subset of the org list (default: all)
 *   changedOnly    monorepo selective builds (default true on non-main branches)
 *   configFile     path to devsecops.yaml override (default: auto-discovered)
 */
def call(Map args = [:]) {
    if (!args.serviceName) { error("microservicePipeline: 'serviceName' is required") }

    pipeline {
        agent none

        options {
            timestamps()
            timeout(time: 90, unit: 'MINUTES')
            buildDiscarder(logRotator(numToKeepStr: '30', daysToKeepStr: '90', artifactNumToKeepStr: '10'))
            disableConcurrentBuilds()
        }

        environment {
            SERVICE_NAME     = "${args.serviceName}"
            DEPLOYMENT_TYPE  = "${args.deploymentType ?: ''}"
            FAILURE_STAGE    = ''
            IMAGE_DIGEST     = ''
            DEPLOY_ENVIRONMENT = ''
        }

        stages {

            // -----------------------------------------------------------------
            stage('Checkout') {
                agent { label 'general' }
                steps {
                    script {
                        def log = new PipelineLogger(this, args.serviceName as String)
                        checkout scm
                        env.GIT_COMMIT_HASH = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                        env.GIT_BRANCH_NAME = env.BRANCH_NAME ?: sh(script: 'git rev-parse --abbrev-ref HEAD', returnStdout: true).trim()
                        def author = sh(script: 'git log -1 --pretty=%an', returnStdout: true).trim()
                        def message = sh(script: 'git log -1 --pretty=%s', returnStdout: true).trim()
                        log.info('Checkout', "branch=${env.GIT_BRANCH_NAME} commit=${env.GIT_COMMIT_HASH.take(8)} author='${author}' subject='${message}'")
                        if (!env.GIT_COMMIT_HASH?.matches('[0-9a-f]{40}')) {
                            error('Checkout: could not resolve a valid commit hash — refusing to build unknown source')
                        }
                        // Every downstream stage runs on a different node/agent:
                        // ship the source tree via stash (excludes .git by design —
                        // all git metadata the pipeline needs is in env vars above).
                        stash name: 'source', includes: '**'
                        log.info('Checkout', "source stashed for downstream stage agents")
                    }
                }
            }

            // -----------------------------------------------------------------
            stage('Discovery & Validation') {
                agent { label 'general' }
                steps {
                    script {
                        def log = new PipelineLogger(this, args.serviceName as String)
                        def cfg = PlatformConfig.load(this, [servicePath: '.'])
                        env.STAGE_FLAGS_JSON = JsonOutput.toJson(collectStageFlags(cfg))

                        def changedOnly = args.containsKey('changedOnly') ? args.changedOnly as boolean :
                            (env.GIT_BRANCH_NAME != 'main' && env.GIT_BRANCH_NAME != 'develop')
                        def services = detectProject(servicePath: '.', changedOnly: changedOnly)

                        // If the caller named a specific service and this is a monorepo,
                        // restrict to it (it must exist in the discovery result).
                        if (services.size() > 1) {
                            def filtered = services.findAll { (it.name as String) == (args.serviceName as String) }
                            services = filtered ?: services
                            log.info('Discovery', filtered ?
                                "monorepo: selected declared service '${args.serviceName}'" :
                                "monorepo: '${args.serviceName}' not among discovered services — processing all changed services")
                        }

                        validateProject(services: services, config: cfg)
                        env.SERVICES_JSON = JsonOutput.toJson(services)
                        env.SERVICE_COUNT = "${services.size()}"

                        // Security policy + exception register are validated on EVERY run
                        SecurityPolicy.load(this, cfg, log)

                        if (services.isEmpty()) {
                            log.info('Discovery', 'no services selected (docs/CI-only change) — ending pipeline')
                            currentBuild.result = 'NOT_BUILT'
                            return
                        }
                    }
                }
            }

            // -----------------------------------------------------------------
            // Gated delivery stages. Each activates when its platform-config
            // flag flips (Phase 6/7/8/9). Until then the stage reports SKIP
            // with the exact reason — never silently absent.
            //
            // All delivery stages are `agent none`: runServiceStage allocates
            // the correct node PER SERVICE (language agent for build/test/
            // publish, security agent for scans, general for container/gitops/
            // verify) and unstashes the 'source' stash created at Checkout.
            // No stage-level allocation means no nested node() contention.
            // -----------------------------------------------------------------
            stage('Pre-Build Secrets Scan') {
                when { expression { stageFlagEnabled('preBuildSecurity') } }
                agent none
                steps {
                    script { runServiceStage('preBuild', args) }
                }
            }

            stage('Build & Test') {
                when { expression { stageFlagEnabled('build') || stageFlagEnabled('unitTests') || stageFlagEnabled('integrationTests') } }
                agent none
                steps {
                    script { runServiceStage('build', args) }
                }
            }

            stage('Quality Gate') {
                when { expression { stageFlagEnabled('quality') } }
                agent none
                steps {
                    script { runServiceStage('quality', args) }
                }
            }

            stage('Security Gates') {
                when { expression { stageFlagEnabled('sast') || stageFlagEnabled('dependencyScan') || stageFlagEnabled('secrets') } }
                agent none
                steps {
                    script { runServiceStage('security', args) }
                }
            }

            stage('Image Build') {
                when { expression { stageFlagEnabled('imageBuild') || stageFlagEnabled('imageScan') || stageFlagEnabled('sbom') || stageFlagEnabled('sign') } }
                agent none
                steps {
                    script { runServiceStage('image', args) }
                }
            }

            stage('Package & Publish') {
                when { expression { stageFlagEnabled('package') || stageFlagEnabled('publish') } }
                agent none
                steps {
                    script { runServiceStage('publish', args) }
                }
            }

            stage('GitOps & Deploy') {
                when { expression { stageFlagEnabled('gitops') } }
                agent none
                steps {
                    script { runServiceStage('gitops', args) }
                }
            }

            stage('Verify & Post-Deploy') {
                when { expression { stageFlagEnabled('verify') || stageFlagEnabled('postDeploy') } }
                agent none
                steps {
                    script { runServiceStage('verify', args) }
                }
            }

            // Stages that are gated OFF report themselves explicitly:
            stage('Stage Enablement Report') {
                agent { label 'general' }
                steps {
                    script {
                        if (currentBuild.result == 'NOT_BUILT') { return }
                        def log = new PipelineLogger(this, args.serviceName as String)
                        def cfg = PlatformConfig.load(this)
                        for (String stageKey : allStageKeys()) {
                            if (!cfg.isStageEnabled(stageKey)) {
                                log.stageSkipped(stageKey, cfg.stageSkipReason(stageKey))
                            }
                        }
                    }
                }
            }
        }

        post {
            always {
                node('general') {
                    script {
                        // Archive discovery + any reports produced by later-phase stages
                        catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
                            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true, fingerprint: false
                        }
                        def failureStage = env.FAILURE_STAGE ?: ''
                        notifyResult(
                            serviceName: args.serviceName as String,
                            event: currentBuild.currentResult in ['SUCCESS'] ? 'build_completed' : 'build_failed',
                            failureStage: failureStage,
                            imageDigest: env.IMAGE_DIGEST ?: ''
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// helpers (private to this vars script)
// ---------------------------------------------------------------------------

private List<String> allStageKeys() {
    return ['preBuildSecurity', 'build', 'unitTests', 'integrationTests', 'quality',
            'sast', 'dependencyScan', 'secrets', 'package', 'imageBuild', 'imageScan',
            'sbom', 'sign', 'publish', 'gitops', 'sync', 'verify', 'postDeploy']
}

private Map collectStageFlags(PlatformConfig cfg) {
    Map flags = [:]
    for (String key : allStageKeys()) { flags[key] = cfg.isStageEnabled(key) }
    return flags
}

private boolean stageFlagEnabled(String key) {
    if (currentBuild.result == 'NOT_BUILT') { return false }
    if (!env.STAGE_FLAGS_JSON) { return false }
    def flags = readJSON(text: env.STAGE_FLAGS_JSON)
    return flags[key] == true
}

/** Agent label per stage group: toolchain agents for build/test/publish,
 *  dedicated security agent for scans, general for container/gitops/verify. */
private String stageLabelFor(String group, Map svc) {
    switch (group) {
        case 'image':
        case 'gitops':
        case 'verify':
            return 'general'
        case 'preBuild':
        case 'security':
            return 'security'
        default:
            return agentLabelForService(svc)
    }
}

/**
 * Dispatcher for gated stages. Each branch delegates to the dedicated vars
 * step delivered by its phase (buildApplication, runSonarAnalysis, runSAST,
 * buildContainer, scanContainer, generateSBOM, signImage, publishArtifact,
 * updateGitOps, verifyDeployment …). The dispatcher exists now so stage
 * activation is a pure configuration event.
 */
private void runServiceStage(String group, Map args) {
    def log = new PipelineLogger(this, args.serviceName as String)
    env.FAILURE_STAGE = group
    def services = readJSON(text: env.SERVICES_JSON)
    int maxParallel = 5
    try {
        if (services.size() > 1) {
            log.info(group, "running '${group}' for ${services.size()} services (max parallel: ${maxParallel})")
        }
        def branches = [:]
        int i = 0
        for (Map svc : services) {
            if (i >= maxParallel) { break }   // hard concurrency cap per master spec §7
            String svcName = svc.name as String
            branches["${group}:${svcName}"] = {
                node(stageLabelFor(group, svc)) {
                    unstash 'source'
                    stage("${group} — ${svcName}") {
                        dispatchStage(group, svc, args)
                    }
                }
            }
            i++
        }
        parallel branches
    } finally {
        env.FAILURE_STAGE = ''
    }
}

private String agentLabelForService(Map svc) {
    def language = svc.language as String
    if (language == 'java') { return (svc.buildTool as String)?.contains('gradle') ? 'java-gradle' : 'java-maven' }
    def labelMap = [python: 'python', dotnet: 'dotnet', nodejs: 'node']
    return labelMap[language] ?: 'general'
}

/** Routes to the phase-delivered step for this stage group. */
private void dispatchStage(String group, Map svc, Map args) {
    // Each sub-step is individually flag-guarded: a group stage activates when
    // ANY of its flags is on, but only the enabled steps execute — so later
    // phases can flip one flag without the others' steps existing yet.
    switch (group) {
        case 'preBuild':
            if (stageFlagEnabled('preBuildSecurity'))   { scanSecrets(service: svc, config: args, preBuild: true) }
            break
        case 'build':
            if (stageFlagEnabled('build'))              { buildApplication(service: svc, config: args) }
            if (stageFlagEnabled('unitTests'))          { runUnitTests(service: svc, config: args) }
            if (stageFlagEnabled('integrationTests'))   { runIntegrationTests(service: svc, config: args) }
            break
        case 'quality':  runSonarAnalysis(service: svc, config: args); break
        case 'security':
            if (stageFlagEnabled('sast'))               { runSAST(service: svc, config: args) }
            if (stageFlagEnabled('dependencyScan'))     { runDependencyScan(service: svc, config: args) }
            if (stageFlagEnabled('secrets'))            { scanSecrets(service: svc, config: args) }
            break
        case 'image':
            if (stageFlagEnabled('imageBuild'))         { buildContainer(service: svc, config: args) }
            if (stageFlagEnabled('imageScan') || stageFlagEnabled('sbom') || stageFlagEnabled('sign')) {
                // trivy/syft/cosign live on agent-security ONLY. The current
                // node is 'general' — a DIFFERENT label, so this allocation
                // cannot contend with the outer executor (no deadlock).
                node('security') {
                    if (stageFlagEnabled('imageScan'))  { scanContainer(service: svc, config: args) }
                    if (stageFlagEnabled('sbom'))       { generateSBOM(service: svc, config: args) }
                    if (stageFlagEnabled('sign'))       { signImage(service: svc, config: args) }
                }
            }
            break
        case 'publish':
            if (stageFlagEnabled('package'))            { packageApplication(service: svc, config: args) }
            if (stageFlagEnabled('publish'))            { publishArtifact(service: svc, config: args) }
            break
        case 'gitops':
            if (stageFlagEnabled('gitops'))             { updateGitOps(service: svc, config: args) }
            if (stageFlagEnabled('sync'))               { deployApplication(service: svc, config: args) }
            break
        case 'verify':
            if (stageFlagEnabled('verify'))             { verifyDeployment(service: svc, config: args) }
            if (stageFlagEnabled('postDeploy'))         { runPostDeploy(service: svc, config: args) }
            break
        default: error("unknown stage group '${group}'")
    }
}
