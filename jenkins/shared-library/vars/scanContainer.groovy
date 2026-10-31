import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.FindingGate
import org.company.devsecops.RegistryAuth

/**
 * scanContainer — trivy scan of the PUSHED image, addressed BY DIGEST
 * (Phase 7). Runs on agent-security (dispatched inside the Image stage).
 *
 *   trivy image --scanners vuln,secret <repo>@<digest>
 *
 * * by-digest ⇒ the verdict belongs to the exact artifact Phase 8 promotes
 * * DBs pulled through Nexus ghcr-proxy (agents offline, D-16/D-24)
 * * policy tool 'container': block_on_critical/high + ignore_unfixed honored
 *   (default false — unfixed vulns are REPORTED, never silently dropped)
 * * secrets baked into image layers are treated as critical findings
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('scanContainer: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Image Scan'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    if (!policy.isEnabled('container')) {
        log.stageSkipped('imageScan', 'policy: container scanning disabled for this project')
        return
    }

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String imageRef = env["IMAGE_REF_${slug}"]
    String digest   = env["IMAGE_DIGEST_${slug}"]
    if (!imageRef || !digest) {
        error("${STAGE}: no pushed image recorded for '${svc.name}' — the imageBuild stage must run before imageScan")
    }
    String repoAtDigest = imageRef.replaceAll(/:[^:@\/]+$/, '') + '@' + digest
    boolean ignoreUnfixed = (policy.policy?.container?.ignore_unfixed == true)

    String report = "${env.WORKSPACE}/reports/trivy-image-${slug}.json"
    sh "mkdir -p '${env.WORKSPACE}/reports'"

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        String dockerCfg = RegistryAuth.writeDockerConfig(this, "img-${slug}")
        try {
            int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
export DOCKER_CONFIG='${dockerCfg}'
${RegistryAuth.trivyDbEnv(this)}
trivy image --scanners vuln,secret \\
  --severity CRITICAL,HIGH,MEDIUM,LOW \\
  ${ignoreUnfixed ? '--ignore-unfixed' : ''} \\
  --format json --output '${report}' \\
  '${repoAtDigest}'
""")
            if (rc != 0) {
                error("${STAGE}: trivy image scan failed (rc=${rc}) for ${repoAtDigest} — see console output")
            }
        } finally {
            RegistryAuth.cleanup(this, dockerCfg)
        }
    }

    List findings = []
    if (fileExists(report)) {
        def raw = readJSON(file: report)
        for (def res : (raw?.Results ?: [])) {
            for (def v : (res?.Vulnerabilities ?: [])) {
                findings << [
                    id      : (v.VulnerabilityID ?: '?') as String,
                    severity: ((v.Severity ?: 'LOW') as String).toLowerCase(),
                    detail  : "${res.Target ?: ''} ${v.PkgName ?: ''}@${v.InstalledVersion ?: ''}${v.FixedVersion ? ' → fix ' + v.FixedVersion : ' (no fix)'}".toString()
                ]
            }
            for (def s : (res?.Secrets ?: [])) {
                findings << [
                    id      : (s.RuleID ?: 'image-secret') as String,
                    severity: ((s.Severity ?: 'CRITICAL') as String).toLowerCase(),
                    detail  : "secret in image layer (${s.Category ?: '?'}) — ${s.RuleID ?: '?'}".toString()
                ]
            }
        }
    }

    def verdict = FindingGate.evaluate(this, policy, log, 'container', STAGE, findings)
    FindingGate.writeVerdict(this, slug, STAGE, [verdict])
    archiveArtifacts artifacts: "reports/trivy-image-${slug}.json", allowEmptyArchive: true, fingerprint: false
    log.info(STAGE, "image scan complete: ${repoAtDigest}")
}
