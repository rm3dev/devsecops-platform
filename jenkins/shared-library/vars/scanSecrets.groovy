import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.FindingGate

/**
 * scanSecrets — gitleaks secret scanning (Phase 7).
 *
 * Runs TWICE by design when both flags are on:
 *   preBuildSecurity stage (params.preBuild=true) — fail fast BEFORE compiling
 *   Security Gates stage  ('secrets' flag)        — skipped automatically if
 *                                                   the pre-build scan already ran
 *
 * The workspace arrives via the 'source' stash WITHOUT .git, so gitleaks runs
 * in directory mode (--no-git). Reports are written with --redact: archived
 * JSON never contains secret material, and console output is limited to
 * rule/file/line (LOG-SAFE by contract, see FindingGate).
 *
 * Policy: security.secrets.block_on_detection — ANY finding blocks unless an
 * ACTIVE exception matches its RuleID or Fingerprint (register validated at
 * Discovery; expired exceptions gate again).
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('scanSecrets: "service" map is required')
    boolean preBuild = (params.preBuild ?: false) as boolean
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = preBuild ? 'Pre-Build Secrets Scan' : 'Secrets Scan'

    if (!preBuild && env.PREBUILD_SECRETS_DONE == 'true') {
        log.info(STAGE, "pre-build secrets scan already passed in this build — skipping duplicate scan")
        return
    }

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    if (!policy.isEnabled('secrets')) {
        log.stageSkipped('secrets', 'policy: secrets scanning disabled for this project')
        return
    }

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String report = "${env.WORKSPACE}/reports/gitleaks-${slug}.json"
    sh "mkdir -p '${env.WORKSPACE}/reports'"

    // --exit-code 0: gating is decided by FindingGate (policy + exceptions),
    // not by the scanner's own exit code.
    sh "gitleaks detect --no-git --redact " +
       "--source '${svc.path}' " +
       "--report-format json --report-path '${report}' " +
       "--exit-code 0"

    List findings = []
    if (fileExists(report)) {
        def raw = readJSON(file: report)
        if (raw instanceof List) {
            for (def f : raw) {
                findings << [
                    id      : (f.RuleID ?: 'unknown-rule') as String,
                    altId   : (f.Fingerprint ?: '') as String,   // exceptions may cite either
                    severity: 'detection',
                    detail  : "${f.File ?: '?'}:${f.StartLine ?: '?'} rule=${f.RuleID ?: '?'}".toString()
                ]
            }
        }
    }
    findings = findings.findAll { it.id }

    def verdict = FindingGate.evaluate(this, policy, log, 'secrets', STAGE, findings)
    FindingGate.writeVerdict(this, slug, STAGE, [verdict])
    archiveArtifacts artifacts: "reports/gitleaks-${slug}.json", allowEmptyArchive: true, fingerprint: false

    if (preBuild) { env.PREBUILD_SECRETS_DONE = 'true' }
    log.info(STAGE, "secrets scan clean (${verdict.total} finding(s), ${verdict.excepted} excepted)")
}
