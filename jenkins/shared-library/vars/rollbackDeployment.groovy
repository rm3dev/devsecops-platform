import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.GitOpsRepo

/**
 * rollbackDeployment — GitOps-native rollback (D-12/D-32): re-pin the PREVIOUS
 * digest of an environment overlay and let ArgoCD reconcile back. Nothing is
 * rebuilt; the registry still holds every digest, so rollback is seconds.
 *
 * Previous-digest resolution walks the overlay file's OWN git history
 * (git log -- <overlay>), so interleaved commits from other services never
 * confuse it. The all-zeros seed placeholder is never a rollback target.
 *
 * Called automatically by verifyDeployment/runPostDeploy on failure when
 * gitops.autoRollback is enabled, and manually from any pipeline. The
 * triggering build STILL FAILS — rollback restores the service, it does not
 * forgive the change (every rollback is a visible `revert(gitops):` commit).
 *
 * params:
 *   service  svc map OR slug String (required)
 *   env      target environment (required)
 *   reason   free text, recorded in the commit message + report
 *   digest   explicit sha256:… to pin (skips git-history lookup)
 *   wait     default true → deployApplication (ArgoCD sync+health) after push
 */
def call(Map params = [:]) {
    String slug = (params.service instanceof Map) ?
            GitOpsRepo.slugify(params.service.name as String) :
            GitOpsRepo.slugify(params.service as String)
    if (!slug) { error('rollbackDeployment: "service" is required (slug or service map)') }
    String targetEnv = params.env as String
    if (!targetEnv) { error('rollbackDeployment: "env" is required') }

    def log = new PipelineLogger(this, slug)
    final String STAGE = 'Rollback'
    def cfg = PlatformConfig.load(this)
    List envs = (cfg.get('environments', ['dev', 'qa', 'uat', 'prod'])) as List
    if (!envs.contains(targetEnv)) { error("${STAGE}: '${targetEnv}' is not a platform environment ${envs}") }
    String reason = (params.reason ?: 'manual rollback') as String

    String prevDigest = params.digest as String
    String commitSha = ''

    withCredentials([string(credentialsId: 'gitops-commit-token', variable: 'GITOPS_TOKEN')]) {
        if (env.GITOPS_TOKEN == 'SET_IN_PHASE_8' || !env.GITOPS_TOKEN?.trim()) {
            error("${STAGE}: gitops-commit-token is still the placeholder — run gitlab/scripts/50-gitops-repository.sh")
        }
        GitOpsRepo.withClone(this, [url: GitOpsRepo.repoUrl(this, cfg),
                                    branch: cfg.get('gitops.branch', 'main')]) { String dir ->
            String overlayRel = "applications/${slug}/overlays/${targetEnv}/kustomization.yaml"
            String overlay = "${dir}/${overlayRel}"
            if (!fileExists(overlay)) { error("${STAGE}: ${overlayRel} not found in the gitops repository") }

            String imageName = GitOpsRepo.readImageName(this, overlay)
            if (!imageName) { error("${STAGE}: ${overlayRel} has no images[0].name") }
            String currentDigest = sh(returnStdout: true,
                    script: "yq '.images[0].digest // \"\"' '${overlay}'").trim()

            if (!prevDigest) {
                // Walk this overlay's own commit history for the previous real digest.
                String history = script_dir_git_log(dir, overlayRel)
                List candidates = history.readLines().findAll { it.trim() }
                for (String c : candidates.drop(1).take(8)) {
                    String d = sh(returnStdout: true, script:
                            "cd '${dir}' && git show '${c.trim()}':'${overlayRel}' 2>/dev/null | yq '.images[0].digest // \"\"'").trim()
                    if (GitOpsRepo.isDigest(d) && d != currentDigest && d != "sha256:${'0' * 64}") {
                        prevDigest = d
                        break
                    }
                }
                if (!prevDigest) {
                    error("${STAGE}: no previous digest found in the git history of ${overlayRel} " +
                          "(first deployment, or history too shallow) — pin one explicitly: digest: 'sha256:…'")
                }
            }
            if (!GitOpsRepo.isDigest(prevDigest)) { error("${STAGE}: invalid digest '${prevDigest}'") }
            if (prevDigest == currentDigest) {
                log.warn(STAGE, "overlay already at ${prevDigest.take(19)}… — nothing to roll back")
                return
            }

            log.info(STAGE, "rolling back ${slug}@${targetEnv}: ${currentDigest?.take(19)}… → ${prevDigest.take(19)}… (${reason})")
            GitOpsRepo.pinDigest(this, overlay, imageName, prevDigest)
            commitSha = GitOpsRepo.commitAndPush(this, dir,
                    "revert(gitops): rollback ${slug}@${targetEnv} → ${prevDigest.take(19)}… (${reason}) [skip ci]")
            writeFile file: "reports/rollback-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                    service    : slug,
                    environment: targetEnv,
                    from       : currentDigest,
                    to         : prevDigest,
                    reason     : reason,
                    commit     : commitSha ?: 'no-change',
            ])) + '\n'
        }
    }

    boolean wait = (params.wait == null) ? true : (params.wait as boolean)
    if (wait && commitSha && cfg.isStageEnabled('sync')) {
        log.info(STAGE, "waiting for ArgoCD to reconcile the rollback…")
        deployApplication(service: [name: slug, path: '.'], appName: "${slug}-${targetEnv}", env: targetEnv)
        log.info(STAGE, "rollback complete — ${slug}@${targetEnv} is back at ${prevDigest.take(19)}…")
    }
    // Phase 10: rollback_executed is a first-class notification event (master
    // spec §16) — fired for automatic AND manual rollbacks, fail-safe by design
    if (commitSha) {
        notifyResult(serviceName: slug, event: 'rollback_executed',
                environment: targetEnv, imageDigest: prevDigest)
    }
}

/** git log for one file (newest first), run inside the cloned repo. */
private String script_dir_git_log(String dir, String overlayRel) {
    return sh(returnStdout: true, script:
            "cd '${dir}' && git log --format=%H -n 12 -- '${overlayRel}'").trim()
}
