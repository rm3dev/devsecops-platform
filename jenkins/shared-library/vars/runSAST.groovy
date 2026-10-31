import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.SecurityPolicy
import org.company.devsecops.FindingGate

/**
 * runSAST — semgrep static analysis (Phase 7).
 *
 * Rules: OFFLINE rulesets baked into agent-security at image build time
 * (/opt/semgrep-rules: p/default, p/owasp-top-ten, p/security-audit incl.
 * Dockerfile rules) — agents never reach semgrep.dev (D-16). Refresh = rebuild
 * the agent image (rules pinned with the image, auditable).
 *
 * Severity mapping (semgrep has 3 levels; policy has 4):
 *   ERROR → high, WARNING → medium, INFO → low
 * With org defaults (block_on_critical + block_on_high) every ERROR finding
 * gates the build unless an ACTIVE exception matches its check_id.
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('runSAST: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'SAST'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def policy = SecurityPolicy.load(this, cfg, log)
    if (!policy.isEnabled('sast')) {
        log.stageSkipped('sast', 'policy: SAST disabled for this project')
        return
    }
    String rulesDir = (cfg.get('security.semgrepRulesDir', '/opt/semgrep-rules')) as String

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    String report = "${env.WORKSPACE}/reports/semgrep-${slug}.json"
    sh "mkdir -p '${env.WORKSPACE}/reports'"

    // semgrep exit codes: 0 = clean OR findings (without --error), 1 = findings
    // with --error, >=2 = tool failure. We gate via FindingGate, so no --error;
    // rc >= 2 is a real failure.
    int rc = sh(returnStatus: true, script:
        "semgrep scan --config '${rulesDir}' --metrics=off --timeout 300 " +
        "--json --output '${report}' '${svc.path}'")
    if (rc > 1) {
        error("${STAGE}: semgrep failed to run (rc=${rc}) — check rulesets in ${rulesDir} and the console output")
    }

    def severityMap = (cfg.get('security.severityMapping.semgrep',
                               [ERROR: 'high', WARNING: 'medium', INFO: 'low']) ?: [:]) as Map
    List findings = []
    if (fileExists(report)) {
        def raw = readJSON(file: report)
        for (def r : (raw?.results ?: [])) {
            String semgrepSeverity = (r.extra?.severity ?: 'INFO') as String
            findings << [
                id      : (r.check_id ?: 'unknown-rule') as String,
                severity: (severityMap[semgrepSeverity] ?: 'low') as String,
                detail  : "${r.path ?: '?'}:${r.start?.line ?: '?'} (${semgrepSeverity})".toString()
            ]
        }
        def errs = raw?.errors ?: []
        if (errs) { log.warn(STAGE, "semgrep reported ${errs.size()} file-level error(s) — see JSON report") }
    }

    def verdict = FindingGate.evaluate(this, policy, log, 'sast', STAGE, findings)
    FindingGate.writeVerdict(this, slug, STAGE, [verdict])
    archiveArtifacts artifacts: "reports/semgrep-${slug}.json", allowEmptyArchive: true, fingerprint: false
}
