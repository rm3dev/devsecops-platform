package org.company.devsecops

/**
 * Security policy engine (master spec §10) — Phase 3 foundation.
 *
 * Loads the organization default policy from library resources, applies the
 * validated project override (PlatformConfig.validateOverrides guarantees
 * tighten-only), and enforces the exception register contract:
 * every exception MUST have owner, justification, approvedBy and expires
 * (ISO-8601 date). Expired or malformed exceptions fail the build — they are
 * never silently ignored.
 *
 * Phase 7 extends this class with tool-result parsing (Trivy/Semgrep/Gitleaks
 * JSON → gate decisions). The gate API below is the contract those parsers use.
 */
class SecurityPolicy implements Serializable {

    private static final long serialVersionUID = 1L

    private final script
    Map policy = [:]
    List exceptions = []

    static SecurityPolicy load(script, PlatformConfig cfg, PipelineLogger log) {
        def sp = new SecurityPolicy(script: script)
        sp.policy = script.readYaml(text: script.libraryResource('security-policy-default.yaml'))?.security ?: [:]

        // Validated project override (tighten-only enforced upstream)
        if (cfg.project?.security) {
            sp.policy = deepMerge(sp.policy, cfg.project.security as Map)
        }

        // Exception register: <servicePath>/security-exceptions.yaml (optional)
        def registerPath = (sp.policy?.exceptions?.register_path ?: 'security-exceptions.yaml') as String
        def fullPath = cfg.servicePath == '.' ? registerPath : "${cfg.servicePath}/${registerPath}"
        if (script.fileExists(fullPath)) {
            def loaded = script.readYaml(file: fullPath)
            sp.exceptions = (loaded?.exceptions ?: []) as List
            sp.validateExceptions(fullPath, log)
        }
        return sp
    }

    boolean isEnabled(String tool) {
        return policy?."${tool}"?.enabled != false
    }

    /** Would a finding of this severity block the release for this tool? */
    boolean blocks(String tool, String severity) {
        def section = policy?."${tool}" ?: [:]
        def flag = section["block_on_${severity.toLowerCase()}"]
        if (flag == null && severity.equalsIgnoreCase('detection')) {
            flag = section['block_on_detection']
        }
        return flag == true
    }

    boolean isSbomRequired()  { return policy?.sbom?.required == true }
    boolean isSigningRequired() { return policy?.signing?.required == true }

    /** Active (non-expired) exception IDs for a tool, e.g. CVE allow-list. */
    List<String> activeExceptionIds(String tool) {
        def now = new Date()
        def ids = []
        for (def ex : exceptions) {
            if (!(ex instanceof Map)) { continue }
            if ((ex.tool as String) != tool) { continue }
            def expires = parseDate(ex.expires as String)
            if (expires != null && expires.before(now)) { continue }
            def id = ex.id as String
            if (id) { ids << id }
        }
        return ids
    }

    boolean isExcepted(String tool, String findingId) {
        return activeExceptionIds(tool).contains(findingId)
    }

    /** Fail-closed validation of every exception entry (master spec §10). */
    void validateExceptions(String path, PipelineLogger log) {
        def requireApproval = policy?.exceptions?.require_approval != false
        def requireExpiry   = policy?.exceptions?.require_expiry != false
        int index = 0
        for (def ex : exceptions) {
            index++
            if (!(ex instanceof Map)) {
                throw new IllegalStateException("${path}: exception #${index} is not a mapping")
            }
            def missing = []
            if (!ex.id)            { missing << 'id' }
            if (!ex.tool)          { missing << 'tool' }
            if (!ex.owner)         { missing << 'owner' }
            if (!ex.justification) { missing << 'justification' }
            if (requireApproval && !ex.approvedBy) { missing << 'approvedBy' }
            if (requireExpiry && !ex.expires)      { missing << 'expires' }
            if (missing) {
                throw new IllegalStateException(
                    "${path}: exception #${index} (${ex.id ?: 'no-id'}) missing required field(s): ${missing}. " +
                    "Exceptions must have owner, justification, approval and expiration — see security/policies/.")
            }
            if (requireExpiry) {
                def expires = parseDate(ex.expires as String)
                if (expires == null) {
                    throw new IllegalStateException("${path}: exception '${ex.id}' has unparseable expires '${ex.expires}' (expected ISO-8601, e.g. 2026-12-31)")
                }
                if (expires.before(new Date())) {
                    log.warn('Policy', "exception '${ex.id}' EXPIRED on ${ex.expires} — it is being IGNORED and findings will gate again")
                }
            }
        }
        log.info('Policy', "loaded ${exceptions.size()} exception(s) from ${path}")
    }

    private static Date parseDate(String s) {
        if (!s) { return null }
        try { return Date.parse('yyyy-MM-dd', s) } catch (ignored) { return null }
    }

    @SuppressWarnings('unchecked')
    static Map deepMerge(Map base, Map overlay) {
        Map out = new LinkedHashMap(base)
        for (Map.Entry e : overlay.entrySet()) {
            if (e.value instanceof Map && out[e.key] instanceof Map) {
                out[e.key] = deepMerge(out[e.key] as Map, e.value as Map)
            } else {
                out[e.key] = e.value
            }
        }
        return out
    }
}
