import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig

/**
 * buildContainer — build & push the service image via rootless BuildKit
 * (Phase 6; decisions D-04, D-23). Runs on the 'general' agent (buildctl +
 * crane baked in Phase 3) against buildkitd on the internal agents network.
 *
 * Image reference convention (D-23 — NEVER a 'latest' tag anywhere):
 *   registry.<PLATFORM_DOMAIN>/<team-folder>/<service>:<branch>-<sha9>-<build>
 * pushed to Nexus docker-hosted THROUGH the docker-group connector
 * (Traefik terminates TLS on :443 → nexus:8085).
 *
 * Outputs (parallel-monorepo-safe):
 *   env.IMAGE_REF_<slug>      full tagged reference
 *   env.IMAGE_DIGEST_<slug>   sha256 digest AFTER push (immutable identity —
 *                             Phase 8 GitOps pins exactly this value)
 *   env.IMAGE_REF / IMAGE_DIGEST  also set when the build has a single service
 *   reports/image-<slug>.json archived manifest
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('buildContainer: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Image Build'

    if (!svc.hasDockerfile) {
        log.stageSkipped('imageBuild', "service '${svc.name}' has no Dockerfile — nothing to build")
        return
    }

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String buildkitAddr = (cfg.get('registry.buildkitAddr', 'tcp://buildkitd:1234')) as String

    String domain = env.PLATFORM_DOMAIN
    if (!domain) { error("${STAGE}: PLATFORM_DOMAIN is not set in the controller environment") }
    String registryHost = "registry.${domain}"

    // Team folder = second segment of the job's full name (teams/<team>/<repo>/<branch>)
    String teamSlug = 'platform'
    def jobParts = (env.JOB_NAME ?: '').split('/')
    if (jobParts.length >= 2 && jobParts[0] == 'teams') { teamSlug = jobParts[1] }

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String branchSlug = ((env.GIT_BRANCH_NAME ?: 'main') as String).replaceAll('[^a-zA-Z0-9._-]', '-').take(40)
    String sha9 = (env.GIT_COMMIT_HASH ?: 'unknown').take(9)
    String tag = "${branchSlug}-${sha9}-${env.BUILD_NUMBER}"
    String imageRef = "${registryHost}/${teamSlug}/${slugifyName(svc.name as String)}:${tag}"

    String dockerfilePath = (svc.dockerfiles && !svc.dockerfiles.isEmpty()) ?
        ((svc.path == '.' ? '' : svc.path + '/') + svc.dockerfiles[0]) : ((svc.path == '.' ? '' : svc.path + '/') + 'Dockerfile')
    String dfDir  = dockerfilePath.contains('/') ? dockerfilePath.substring(0, dockerfilePath.lastIndexOf('/')) : '.'
    String dfName = dockerfilePath.substring(dockerfilePath.lastIndexOf('/') + 1)

    log.info(STAGE, "image=${imageRef}")
    log.info(STAGE, "context=${svc.path} dockerfile=${dockerfilePath} buildkit=${buildkitAddr}")

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        String dockerCfg = "${env.WORKSPACE}/.docker-${slug}"
        try {
            // Registry auth for buildctl push + crane (agent trusts the internal
            // CA — baked into agent-general at image build time).
            String authB64 = "${NEXUS_USER}:${NEXUS_PASS}".getBytes('UTF-8').encodeBase64().toString()
            writeFile file: "${dockerCfg}/config.json", text: JsonOutput.toJson([
                auths: [(registryHost): [auth: authB64]]
            ])

            int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -euo pipefail
export DOCKER_CONFIG='${dockerCfg}'
buildctl --addr '${buildkitAddr}' build \\
  --frontend dockerfile.v0 \\
  --local context='${svc.path}' \\
  --local dockerfile='${dfDir}' \\
  --opt filename='${dfName}' \\
  --opt build-arg:SERVICE_NAME='${svc.name}' \\
  --opt build-arg:GIT_COMMIT='${env.GIT_COMMIT_HASH ?: ''}' \\
  --opt build-arg:BUILD_NUMBER='${env.BUILD_NUMBER}' \\
  --opt build-arg:BASE_REGISTRY='${registryHost}' \\
  --output type=image,name='${imageRef}',push=true
""")
            if (rc != 0) {
                int probe = sh(returnStatus: true, script:
                    "buildctl --addr '${buildkitAddr}' debug workers >/dev/null 2>&1")
                if (probe != 0) {
                    error("${STAGE}: cannot reach BuildKit at ${buildkitAddr} — start it with: " +
                          "docker compose -f docker-compose.yml --profile core --profile build up -d buildkitd")
                }
                error("${STAGE}: buildctl build/push failed (rc=${rc}) — see console output above")
            }

            String digest = sh(returnStdout: true, script:
                "DOCKER_CONFIG='${dockerCfg}' crane digest '${imageRef}'").trim()
            if (!digest?.startsWith('sha256:')) { error("${STAGE}: could not resolve pushed digest for ${imageRef}") }

            env["IMAGE_REF_${slug}"]    = imageRef
            env["IMAGE_DIGEST_${slug}"] = digest
            if ((env.SERVICE_COUNT ?: '1') == '1') {
                env.IMAGE_REF    = imageRef
                env.IMAGE_DIGEST = digest
            }
            log.info(STAGE, "pushed ${imageRef} @ ${digest}")

            writeFile file: "${env.WORKSPACE}/reports/image-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                service : svc.name,
                image   : imageRef,
                tag     : tag,
                digest  : digest,
                registry: registryHost,
                team    : teamSlug,
                commit  : env.GIT_COMMIT_HASH ?: '',
                build   : env.BUILD_NUMBER
            ]))
            archiveArtifacts artifacts: 'reports/image-*.json', allowEmptyArchive: true, fingerprint: false
        } finally {
            sh script: "rm -rf '${dockerCfg}'", returnStatus: true   // registry auth off disk
        }
    }
}

private String slugifyName(String s) {
    return (s ?: 'service').replaceAll('[^a-z0-9._-]', '-').toLowerCase()
}
