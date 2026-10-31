import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.GitOpsRepo

/**
 * deployApplication — ArgoCD sync + health wait (Phase 8).
 *
 * Jenkins has NO cluster credentials for this: the argocd CLI talks to the
 * ArgoCD API as local account 'jenkins-cd', whose RBAC allows exactly
 * applications get/sync in projects dev|qa|uat|prod (kubernetes/argocd/
 * install-argocd.sh). Git is the only deployment channel — this step just
 * asks ArgoCD to reconcile what updateGitOps committed and waits for it.
 *
 * Connection env (secrets/argocd.env → agent-general container):
 *   ARGOCD_SERVER_URL  e.g. https://<host-ip>:30443 (lab NodePort, D-27)
 *   ARGOCD_OPTS        --insecure for the lab self-signed cert
 * Credential: argocd-auth-token (JCasC ← ARGOCD_AUTH_TOKEN), fail-closed.
 *
 * params:
 *   service  svc map (required — name is used for slug/logging)
 *   appName  ArgoCD app name (default: env GITOPS_APP_<slug> or "<slug>-<env>")
 *   env      target environment (default: env GITOPS_ENV_<slug> or gitops.defaultEnvironment)
 *
 * Sets env.DEPLOY_ENVIRONMENT on success (consumed by verifyDeployment, Phase 9).
 * artifact: reports/deploy-<slug>.json
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('deployApplication: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Deploy'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String slug = GitOpsRepo.slugify(svc.name as String)

    List envs = (cfg.get('environments', ['dev', 'qa', 'uat', 'prod'])) as List
    String targetEnv = (params.env ?: env["GITOPS_ENV_${slug}"] ?: cfg.get('gitops.defaultEnvironment', 'dev')) as String
    if (!envs.contains(targetEnv)) {
        error("${STAGE}: environment '${targetEnv}' is not a platform environment ${envs}")
    }
    String appName = (params.appName ?: env["GITOPS_APP_${slug}"] ?: "${slug}-${targetEnv}") as String
    int timeoutSec = (cfg.get('gitops.syncTimeoutSec', 600) as Number).intValue()

    String serverUrl = env.ARGOCD_SERVER_URL
    if (!serverUrl || serverUrl == 'SET_IN_PHASE_8') {
        error("${STAGE}: ARGOCD_SERVER_URL is missing on this agent — run kubernetes/scripts/00-bootstrap-cluster.sh, " +
              "then: docker compose -f docker-compose.yml --profile agents up -d agent-general")
    }
    String server = serverUrl.replaceFirst('^https?://', '')

    withCredentials([string(credentialsId: 'argocd-auth-token', variable: 'ARGO_TOKEN')]) {
        if (env.ARGO_TOKEN == 'SET_IN_PHASE_8' || !env.ARGO_TOKEN?.trim()) {
            error("${STAGE}: argocd-auth-token is still the Phase-8 placeholder — run kubernetes/argocd/install-argocd.sh " +
                  "(writes secrets/argocd.env), then: docker compose -f docker-compose.yml --profile core up -d jenkins")
        }

        String cliEnv = """export ARGOCD_SERVER='${server}'
export ARGOCD_AUTH_TOKEN="\${ARGO_TOKEN}"
export ARGOCD_OPTS="\${ARGOCD_OPTS:-}"
"""
        log.info(STAGE, "ArgoCD app '${appName}': triggering sync + waiting healthy (timeout ${timeoutSec}s)")
        int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
${cliEnv}
argocd app wait '${appName}' --sync --health --timeout ${timeoutSec}
""")

        String status = sh(returnStdout: true, script: """#!/usr/bin/env bash
set -uo pipefail
${cliEnv}
argocd app get '${appName}' -o json 2>/dev/null \\
  | jq -r '"sync=" + .status.sync.status + " health=" + (.status.health.status // "Unknown") + " revision=" + ((.status.sync.revision // "?")[0:8])' \\
  || echo 'status-unavailable'
""").trim()

        if (rc != 0) {
            String diag = sh(returnStdout: true, script: """#!/usr/bin/env bash
set -uo pipefail
${cliEnv}
argocd app get '${appName}' 2>&1 | tail -40 || true
""").trim()
            log.error(STAGE, "ArgoCD app '${appName}' did not reach sync+health (rc=${rc}; ${status})")
            echo "----- ArgoCD diagnostics (${appName}) -----\n${diag}"
            writeFile file: "reports/deploy-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                    app: appName, environment: targetEnv, result: 'FAILED', status: status])) + '\n'
            error("${STAGE}: deployment did not become healthy — see ArgoCD diagnostics above (rollback: platform/gitops-promotion with the previous DIGEST)")
        }

        env.DEPLOY_ENVIRONMENT = targetEnv
        log.info(STAGE, "app=${appName} ${status}")
        writeFile file: "reports/deploy-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                app        : appName,
                environment: targetEnv,
                result     : 'HEALTHY',
                status     : status,
                digest     : (env["IMAGE_DIGEST_${slug}"] ?: 'promoted/unknown'),
        ])) + '\n'
    }
}
