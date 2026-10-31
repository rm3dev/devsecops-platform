import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.RegistryAuth

/**
 * generateSBOM — syft SBOM of the pushed image, addressed BY DIGEST (Phase 7).
 *
 * Formats (policy security.sbom.required = true → hard gate on failure):
 *   CycloneDX JSON  reports/sbom-cdx-<svc>.json
 *   SPDX JSON       reports/sbom-spdx-<svc>.json
 * Both are archived AND uploaded to Nexus raw-hosted under
 *   sbom/<team>/<service>/<digest-hex>.{cdx,spdx}.json
 * so downstream consumers (security reviews, Phase 9 attestations) can fetch
 * the SBOM for any deployed digest without touching Jenkins.
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('generateSBOM: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'SBOM'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    boolean required = policy.isSbomRequired()
    if (!required && !policy.isEnabled('sbom')) {
        log.stageSkipped('sbom', 'policy: SBOM generation disabled (note: org default marks SBOM as REQUIRED)')
        return
    }
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    boolean uploadToRaw = (cfg.get('security.sbom.uploadToRaw', true)) as boolean

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String imageRef = env["IMAGE_REF_${slug}"]
    String digest   = env["IMAGE_DIGEST_${slug}"]
    if (!imageRef || !digest) {
        error("${STAGE}: no pushed image recorded for '${svc.name}' — imageBuild must run before sbom")
    }
    String repoAtDigest = imageRef.replaceAll(/:[^:@\/]+$/, '') + '@' + digest
    String digestHex = digest.replaceFirst('^sha256:', '').take(16)

    String team = 'platform'
    def jobParts = (env.JOB_NAME ?: '').split('/')
    if (jobParts.length >= 2 && jobParts[0] == 'teams') { team = jobParts[1] }

    String cdx  = "${env.WORKSPACE}/reports/sbom-cdx-${slug}.json"
    String spdx = "${env.WORKSPACE}/reports/sbom-spdx-${slug}.json"
    sh "mkdir -p '${env.WORKSPACE}/reports'"

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        String dockerCfg = RegistryAuth.writeDockerConfig(this, "sbom-${slug}")
        try {
            int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
export DOCKER_CONFIG='${dockerCfg}'
syft '${repoAtDigest}' \\
  -o cyclonedx-json='${cdx}' \\
  -o spdx-json='${spdx}'
""")
            if (rc != 0) {
                if (required) {
                    error("${STAGE}: syft failed (rc=${rc}) and SBOM is REQUIRED by policy — build blocked")
                }
                log.warn(STAGE, "syft failed (rc=${rc}); SBOM not required by policy — continuing")
                return
            }
            if (uploadToRaw) {
                int upRc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
BASE='${nexusBase}/repository/${cfg.get('nexus.repositories.rawHosted', 'raw-hosted')}/sbom/${team}/${slug}'
curl -sf -u "\$NEXUS_USER:\$NEXUS_PASS" --upload-file '${cdx}'  "\$BASE/${digestHex}.cdx.json"  || exit 1
curl -sf -u "\$NEXUS_USER:\$NEXUS_PASS" --upload-file '${spdx}' "\$BASE/${digestHex}.spdx.json" || exit 1
""")
                if (upRc == 0) {
                    log.info(STAGE, "SBOMs uploaded → raw-hosted:sbom/${team}/${slug}/${digestHex}.{cdx,spdx}.json")
                } else {
                    log.warn(STAGE, "SBOM upload to raw-hosted failed — artifacts remain in the build (check nexus-deploy rights on raw-hosted)")
                }
            }
        } finally {
            RegistryAuth.cleanup(this, dockerCfg)
        }
    }

    writeFile file: "${env.WORKSPACE}/reports/sbom-manifest-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
        service: svc.name, image: repoAtDigest, digest: digest,
        formats: ['cyclonedx-json', 'spdx-json'],
        nexus  : uploadToRaw ? "sbom/${team}/${slug}/${digestHex}.{cdx,spdx}.json" : null
    ]))
    archiveArtifacts artifacts: "reports/sbom-*${slug}*.json", allowEmptyArchive: true, fingerprint: false
    log.info(STAGE, "SBOM generated for ${repoAtDigest}")
}
