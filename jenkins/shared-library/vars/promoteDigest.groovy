import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.GitOpsRepo

/**
 * promoteDigest — promote an ALREADY-BUILT (scanned, signed, SBOMed) image
 * digest from one environment to the next (master spec: the same digest moves
 * dev→qa→uat→prod; artifacts are never rebuilt for promotion — D-12/D-26).
 *
 * Backed by the seeded job platform/gitops-promotion (JCasC 60-jobs.yaml);
 * callable from any pipeline too. Rollback is the same mechanism: pass an
 * explicit older DIGEST.
 *
 * Kyverno verify-image-signature re-checks the cosign signature at admission
 * in the target cluster, so promotion cannot smuggle unsigned images.
 *
 * params:
 *   service    slug String (applications/<slug>) or svc map (required)
 *   targetEnv  required — qa|uat|prod|dev
 *   sourceEnv  where to read the pinned digest (default: predecessor of
 *              targetEnv in platform environments order)
 *   digest     explicit sha256:… — overrides sourceEnv (rollback/hotfix)
 *   wait       default true → deployApplication (ArgoCD sync+health) after push
 *
 * artifact: reports/gitops-promotion-<slug>.json
 */
def call(Map params = [:]) {
    String slug = (params.service instanceof Map) ?
            GitOpsRepo.slugify(params.service.name as String) :
            GitOpsRepo.slugify(params.service as String)
    if (!slug) { error('promoteDigest: "service" is required (slug or service map)') }

    def log = new PipelineLogger(this, slug)
    final String STAGE = 'Promotion'
    def cfg = PlatformConfig.load(this)

    List envs = (cfg.get('environments', ['dev', 'qa', 'uat', 'prod'])) as List
    String targetEnv = params.targetEnv as String
    if (!envs.contains(targetEnv)) {
        error("${STAGE}: targetEnv '${targetEnv}' is not a platform environment ${envs}")
    }
    String digest = params.digest as String
    String sourceEnv = params.sourceEnv as String
    if (!digest) {
        if (!sourceEnv) {
            int idx = envs.indexOf(targetEnv)
            if (idx <= 0) {
                error("${STAGE}: '${targetEnv}' has no predecessor environment — pass digest: explicitly (dev digests come from builds)")
            }
            sourceEnv = envs[idx - 1]
        }
        if (!envs.contains(sourceEnv)) {
            error("${STAGE}: sourceEnv '${sourceEnv}' is not a platform environment ${envs}")
        }
        if (sourceEnv == targetEnv) { error("${STAGE}: sourceEnv == targetEnv ('${targetEnv}')") }
    }

    withCredentials([string(credentialsId: 'gitops-commit-token', variable: 'GITOPS_TOKEN')]) {
        if (env.GITOPS_TOKEN == 'SET_IN_PHASE_8' || !env.GITOPS_TOKEN?.trim()) {
            error("${STAGE}: gitops-commit-token is still the Phase-8 placeholder. On the host run: " +
                  "./gitlab/scripts/50-gitops-repository.sh && docker compose -f docker-compose.yml --profile core up -d jenkins")
        }

        GitOpsRepo.withClone(this, [url: GitOpsRepo.repoUrl(this, cfg),
                                    branch: cfg.get('gitops.branch', 'main')]) { String dir ->
            String appPath = "${dir}/applications/${slug}"
            if (!fileExists("${appPath}/base/kustomization.yaml")) {
                error("${STAGE}: no GitOps app 'applications/${slug}' — check the slug (SERVICE parameter)")
            }
            String tgtOverlay = "${appPath}/overlays/${targetEnv}/kustomization.yaml"
            if (!fileExists(tgtOverlay)) {
                error("${STAGE}: applications/${slug}/overlays/${targetEnv}/ does not exist")
            }
            if (!digest) {
                String srcOverlay = "${appPath}/overlays/${sourceEnv}/kustomization.yaml"
                if (!fileExists(srcOverlay)) {
                    error("${STAGE}: source overlay missing: applications/${slug}/overlays/${sourceEnv}/")
                }
                digest = GitOpsRepo.readDigest(this, srcOverlay)
                log.info(STAGE, "digest read from ${sourceEnv}: ${digest.substring(7, 19)}…")
            }
            if (!GitOpsRepo.isDigest(digest)) { error("${STAGE}: invalid digest '${digest}'") }

            // Promotion pins the SAME image entry the target overlay already
            // references — no registry knowledge needed here.
            String imageName = GitOpsRepo.readImageName(this, tgtOverlay)
            if (!imageName) { error("${STAGE}: ${tgtOverlay} has no images[0].name to pin") }

            GitOpsRepo.pinDigest(this, tgtOverlay, imageName, digest)
            String via = params.digest ? 'explicit' : sourceEnv
            String sha = GitOpsRepo.commitAndPush(this, dir,
                    "chore(gitops): promote ${slug} ${via}→${targetEnv} @ ${digest.substring(7, 19)}… [skip ci]")
            if (sha) {
                log.info(STAGE, "pushed ${sha.take(8)} — ${slug}: ${via} → ${targetEnv} @ ${digest.substring(7, 19)}…")
            } else {
                log.info(STAGE, "${slug}@${targetEnv} already pinned to this digest (no commit)")
            }
            writeFile file: "reports/gitops-promotion-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                    service    : slug,
                    from       : via,
                    to         : targetEnv,
                    image      : imageName,
                    digest     : digest,
                    argoApp    : "${slug}-${targetEnv}",
                    commit     : sha ?: 'no-change',
            ])) + '\n'
        }
    }

    boolean wait = (params.wait == null) ? true : (params.wait as boolean)
    if (wait && cfg.isStageEnabled('sync')) {
        deployApplication(service: [name: slug, path: '.'], appName: "${slug}-${targetEnv}", env: targetEnv)
    } else if (wait) {
        log.stageSkipped('sync', 'platform flag sync disabled — promotion pushed; ArgoCD auto-sync still reconciles')
    }
}
