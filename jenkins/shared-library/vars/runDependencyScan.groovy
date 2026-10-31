import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.FindingGate

/**
 * runDependencyScan — dependency vulnerability gating (Phase 7).
 * Two complementary scanners, ONE merged verdict under policy tool
 * 'dependencies' (per security-policy-default.yaml):
 *
 *   1. trivy fs      — lockfile/manifest vulns (fast; DB pulled through Nexus
 *                      ghcr-proxy: TRIVY_DB_REPOSITORY=registry.<domain>/…)
 *   2. OWASP Dependency-Check — deep NVD analysis (CLI baked into
 *                      agent-security; NVD mirror from the host-updated
 *                      /owasp-dc volume, scans run --noupdate, fully offline)
 *
 * Exceptions are matched by CVE/Vuln ID — one register entry covers both
 * scanners. Requires: security/scripts/20-dependency-check-db.sh has run at
 * least once (otherwise DC fails with a clear pointer to it).
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('runDependencyScan: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Dependency Scan'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    if (!policy.isEnabled('dependencies')) {
        log.stageSkipped('dependencyScan', 'policy: dependency scanning disabled for this project')
        return
    }
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    String dcDataDir = (cfg.get('security.dependencyCheck.dataDir', '/owasp-dc')) as String

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String trivyReport = "${env.WORKSPACE}/reports/trivy-fs-${slug}.json"
    String dcReportDir = "${env.WORKSPACE}/reports/dependency-check-${slug}"
    sh "mkdir -p '${env.WORKSPACE}/reports' '${dcReportDir}'"
    List findings = []

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        String dockerCfg = "${env.WORKSPACE}/.docker-sec-${slug}"
        try {
            // trivy DB pull goes through the platform registry (docker-group →
            // ghcr-proxy); the group connector requires basic auth.
            String authB64 = "${NEXUS_USER}:${NEXUS_PASS}".getBytes('UTF-8').encodeBase64().toString()
            writeFile file: "${dockerCfg}/config.json",
                      text: groovy.json.JsonOutput.toJson([auths: [("registry.${env.PLATFORM_DOMAIN}"): [auth: authB64]]])

            String registry = "registry.${env.PLATFORM_DOMAIN}"
            // ---------------------------------------------------- trivy fs --
            int trivyRc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
export DOCKER_CONFIG='${dockerCfg}'
export TRIVY_DB_REPOSITORY='${registry}/aquasecurity/trivy-db'
export TRIVY_JAVA_DB_REPOSITORY='${registry}/aquasecurity/trivy-java-db'
trivy fs --scanners vuln \\
  --severity CRITICAL,HIGH,MEDIUM,LOW \\
  --format json --output '${trivyReport}' \\
  '${svc.path}'
""")
            if (trivyRc != 0) {
                log.warn(STAGE, "trivy fs returned ${trivyRc} (DB pull issue?) — continuing with Dependency-Check only")
            }
            if (fileExists(trivyReport)) {
                def raw = readJSON(file: trivyReport)
                for (def res : (raw?.Results ?: [])) {
                    for (def v : (res?.Vulnerabilities ?: [])) {
                        findings << [
                            id      : (v.VulnerabilityID ?: '?') as String,
                            severity: ((v.Severity ?: 'LOW') as String).toLowerCase(),
                            detail  : "trivy-fs ${res.Target ?: ''} ${v.PkgName ?: ''}@${v.InstalledVersion ?: ''}".toString()
                        ]
                    }
                }
            }

            // --------------------------------------- OWASP Dependency-Check --
            int dcRc = sh(returnStatus: true, script:
                "dependency-check.sh --noupdate --dataDir '${dcDataDir}' " +
                "--project '${svc.name}' --scan '${svc.path}' " +
                "--format JSON --out '${dcReportDir}' " +
                "--failBuildCVSS 11")   // never fails by itself; FindingGate decides
            if (dcRc != 0) {
                String hint = sh(returnStdout: true, script:
                    "ls '${dcDataDir}' 2>/dev/null | head -3 || true").trim()
                if (!hint) {
                    error("${STAGE}: Dependency-Check data directory '${dcDataDir}' is EMPTY — run on the host: " +
                          "./security/scripts/20-dependency-check-db.sh (then retry)")
                }
                error("${STAGE}: dependency-check.sh failed (rc=${dcRc}) — see console output")
            }
            def dcJson = findFiles(glob: "reports/dependency-check-${slug}/*.json")
            if (dcJson && dcJson.length > 0) {
                def raw = readJSON(file: dcJson[0].path)
                for (def dep : (raw?.dependencies ?: [])) {
                    for (def v : (dep?.vulnerabilities ?: [])) {
                        String severity = (v.cvssv3?.baseSeverity ?: v.cvssv2?.severity ?:
                                           FindingGate.severityFromScore(v.cvssv3?.baseScore ?: v.cvssv2?.score)) as String
                        findings << [
                            id      : (v.name ?: '?') as String,
                            severity: severity.toLowerCase(),
                            detail  : "dependency-check ${dep.fileName ?: ''}".toString()
                        ]
                    }
                }
            } else {
                log.warn(STAGE, 'Dependency-Check produced no JSON report — treating as zero findings (check dataDir freshness)')
            }
        } finally {
            sh script: "rm -rf '${dockerCfg}'", returnStatus: true
        }
    }

    def verdict = FindingGate.evaluate(this, policy, log, 'dependencies', STAGE, findings)
    FindingGate.writeVerdict(this, slug, STAGE, [verdict])
    archiveArtifacts artifacts: "reports/trivy-fs-${slug}.json,reports/dependency-check-${slug}/**",
                     allowEmptyArchive: true, fingerprint: false
}
