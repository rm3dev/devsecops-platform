package org.company.devsecops

/**
 * FindingGate — Phase 7 wiring between scanner output and SecurityPolicy.
 *
 * Every security step normalizes its tool's JSON findings into
 *     [id: <CVE / rule id / fingerprint>, severity: <critical|high|medium|low|detection>, detail: <log-safe string>]
 * and hands them here. This class applies the policy engine contract:
 *
 *   1. tool disabled by policy            → explicit skip (never silent)
 *   2. finding id matches an ACTIVE exception (owner/justification/approvedBy/
 *      expires validated at load time)     → allowed, logged with its expiry
 *   3. severity whose block_on_* flag is
 *      set (org default or tightened
 *      project override)                  → BUILD BLOCKED (never downgraded)
 *   4. everything else                    → reported, counted, archived
 *
 * 'detail' must be LOG-SAFE: never secret material, never code excerpts —
 * file:line and identifiers only (gitleaks findings especially).
 */
class FindingGate implements Serializable {

    private static final long serialVersionUID = 1L

    static final List SEVERITIES = ['critical', 'high', 'medium', 'low', 'detection']

    /** CVSS v2/v3 score → severity band (used by parsers without a label). */
    static String severityFromScore(Number score) {
        double s = (score ?: 0) as double
        if (s >= 9.0) { return 'critical' }
        if (s >= 7.0) { return 'high' }
        if (s >= 4.0) { return 'medium' }
        return 'low'
    }

    /**
     * Evaluate findings for one tool. Returns a summary map:
     *   [tool:, total:, counts:<sev→n>, excepted:<n>, blocked:<bool>]
     * When blocked, logs the verdict and throws (script.error) — the caller's
     * stage fails with the reason visible in the console + notifications.
     */
    static Map evaluate(script, SecurityPolicy policy, PipelineLogger log,
                        String tool, String stage, List<Map> findings) {

        if (!policy.isEnabled(tool)) {
            log.stageSkipped(stage, "policy: '${tool}' scanning is disabled for this project")
            return [tool: tool, total: 0, counts: [:], excepted: 0, blocked: false, skipped: true]
        }

        Map counts = [:]
        SEVERITIES.each { counts[it] = 0 }
        List excepted = []
        List blocking = []

        for (Map f : findings) {
            String id = (f.id ?: 'unknown') as String
            String severity = ((f.severity ?: 'low') as String).toLowerCase()
            if (!counts.containsKey(severity)) { severity = 'low' }
            counts[severity] = (counts[severity] as int) + 1
            // A finding is excepted when the register matches its primary id OR
            // its alternate id (e.g. gitleaks: RuleID or Fingerprint).
            boolean isExcepted = policy.isExcepted(tool, id) ||
                (f.altId && policy.isExcepted(tool, f.altId as String))
            if (isExcepted) {
                excepted << f
                continue
            }
            if (policy.blocks(tool, severity)) {
                blocking << f
            }
        }

        String summary = "tool=${tool} findings=${findings.size()} " +
            SEVERITIES.findAll { counts[it] > 0 }.collect { "${it}=${counts[it]}" }.join(' ') +
            " excepted=${excepted.size()} blocking=${blocking.size()}"
        log.info(stage, summary)

        for (Map e : excepted) {
            log.warn(stage, "ALLOWED by exception register: ${e.id} (${e.detail ?: ''}) — expires per security-exceptions.yaml")
        }

        if (!blocking.isEmpty()) {
            // Log-safe enumeration: ids + detail only, capped for readability.
            blocking.take(15).each { Map b ->
                log.error(stage, "BLOCKING ${b.severity?.toString()?.toUpperCase()}: ${b.id}${b.detail ? ' — ' + b.detail : ''}")
            }
            if (blocking.size() > 15) {
                log.error(stage, "… and ${blocking.size() - 15} more blocking finding(s) — see archived JSON report")
            }
            log.blocked(stage, "policy violation: ${blocking.size()} finding(s) at or above the block threshold for '${tool}' " +
                               "(exceptions require owner/justification/approval/expiry in security-exceptions.yaml)")
            script.error("${stage}: BLOCKED by security policy — ${blocking.size()} gating finding(s) for '${tool}'")
        }

        return [tool: tool, total: findings.size(), counts: counts,
                excepted: excepted.size(), blocking: 0, blocked: false, skipped: false]
    }

    /** Write + archive the machine-readable verdict alongside the raw report. */
    static void writeVerdict(script, String slug, String stage, List<Map> verdicts) {
        script.writeFile file: "${script.env.WORKSPACE}/reports/security-verdict-${slug}.json",
            text: groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson([
                build  : script.env.BUILD_NUMBER,
                job    : script.env.JOB_NAME,
                commit : script.env.GIT_COMMIT_HASH ?: '',
                verdicts: verdicts
            ]))
        script.archiveArtifacts artifacts: "reports/security-verdict-${slug}.json", allowEmptyArchive: true, fingerprint: false
    }
}
