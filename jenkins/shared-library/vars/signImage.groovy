import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.RegistryAuth

/**
 * signImage — cosign signature on the pushed image DIGEST (Phase 7).
 *
 *   cosign sign --key <pem> <repo>@sha256:<digest>
 *
 * Key material: JCasC credentials 'cosign-signing-key' (base64 PEM) and
 * 'cosign-signing-key-password', fed from secrets/cosign.env which
 * security/scripts/10-cosign-keys.sh provisions. Placeholder values are
 * FAIL-CLOSED. Phase 11 moves the key into Vault with rotation; Phase 8's
 * Kyverno policy admits ONLY images carrying this signature (cosign.pub).
 *
 * Signing by digest (never by tag) is what makes the signature travel with
 * the promoted artifact across environments (master spec: same digest,
 * promoted — never rebuilt).
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('signImage: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Image Signing'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    if (!policy.isSigningRequired() && !policy.isEnabled('signing')) {
        log.stageSkipped('sign', 'policy: image signing disabled (note: org default marks signing as REQUIRED)')
        return
    }

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String imageRef = env["IMAGE_REF_${slug}"]
    String digest   = env["IMAGE_DIGEST_${slug}"]
    if (!imageRef || !digest) {
        error("${STAGE}: no pushed image recorded for '${svc.name}' — imageBuild must run before sign")
    }
    String repoAtDigest = imageRef.replaceAll(/:[^:@\/]+$/, '') + '@' + digest

    withCredentials([string(credentialsId: 'cosign-signing-key', variable: 'COSIGN_KEY_B64'),
                     string(credentialsId: 'cosign-signing-key-password', variable: 'COSIGN_PASSWORD'),
                     usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {

        if (env.COSIGN_KEY_B64 == 'SET_IN_PHASE_7' || !env.COSIGN_KEY_B64?.trim()) {
            error("${STAGE}: cosign key credential is still the Phase-7 placeholder. On the host run: " +
                  "./security/scripts/10-cosign-keys.sh && docker compose -f docker-compose.yml --profile core up -d jenkins")
        }

        String dockerCfg = RegistryAuth.writeDockerConfig(this, "sign-${slug}")
        String keyFile   = "${env.WORKSPACE}/.cosign-${slug}.key"
        try {
            // Key PEM materialized ephemerally from the masked credential env.
            sh """#!/usr/bin/env bash
set -euo pipefail
printf '%s' "\$COSIGN_KEY_B64" | base64 -d > '${keyFile}'
chmod 600 '${keyFile}'
"""
            int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
export DOCKER_CONFIG='${dockerCfg}'
export COSIGN_PASSWORD="\$COSIGN_PASSWORD"
cosign sign --yes --key '${keyFile}' '${repoAtDigest}'
""")
            if (rc != 0) {
                if (policy.isSigningRequired()) {
                    error("${STAGE}: cosign sign failed (rc=${rc}) and signing is REQUIRED by policy — build blocked")
                }
                log.warn(STAGE, "cosign sign failed (rc=${rc}); signing not required by policy — continuing")
                return
            }

            writeFile file: "${env.WORKSPACE}/reports/sign-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                service   : svc.name,
                image     : repoAtDigest,
                digest    : digest,
                signedWith: 'cosign-signing-key (platform keypair; Vault-managed from Phase 11)',
                verifiedBy: 'Kyverno verifyImages (Phase 8) using secrets/cosign/cosign.pub'
            ]))
            archiveArtifacts artifacts: "reports/sign-${slug}.json", allowEmptyArchive: true, fingerprint: false
            log.info(STAGE, "signed ${repoAtDigest} (cosign, key-based)")
        } finally {
            // private key never survives the step
            sh script: "rm -f '${keyFile}'; rm -rf '${dockerCfg}'", returnStatus: true
        }
    }
}
