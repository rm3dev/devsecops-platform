package org.company.devsecops

/**
 * Layered pipeline configuration (master spec §8: "Project configuration must
 * be externalized and validated").
 *
 * Layer 1 (platform): config/platform-config.yaml from this library — the
 *         organization default. Stage flags, environments, agent labels,
 *         notification routing, concurrency.
 * Layer 2 (project):  devsecops.yaml at the repository root (or per-service
 *         directory) — OPTIONAL overrides. Overrides may only *tighten*
 *         security policy; attempts to disable mandatory sections fail the
 *         build (validateOverrides).
 *
 * Requires pipeline steps (readYaml/fileExists) → constructed with the
 * calling script (vars step or pipeline `script` block).
 */
class PlatformConfig implements Serializable {

    private static final long serialVersionUID = 1L

    /** Sections a project may never disable or weaken (mirrors security-policy). */
    static final List MANDATORY_SECTIONS = ['secrets', 'sbom', 'signing']

    private final script
    Map platform = [:]
    Map project = [:]
    String servicePath

    PlatformConfig(script, String servicePath = '.') {
        this.script = script
        this.servicePath = servicePath
    }

    static PlatformConfig load(script, Map args = [:]) {
        def cfg = new PlatformConfig(script, args.servicePath ?: '.')
        cfg.platform = script.readYaml(text: script.libraryResource('config/platform-config.yaml'))

        def overrideFile = args.configFile ?: "${cfg.servicePath == '.' ? '' : cfg.servicePath + '/'}devsecops.yaml"
        if (script.fileExists(overrideFile)) {
            cfg.project = script.readYaml(file: overrideFile) ?: [:]
        }
        cfg.validateOverrides()
        return cfg
    }

    /** Dotted-path lookup: project layer first, then platform layer. */
    def get(String dottedPath, defaultValue = null) {
        def v = resolve(project, dottedPath)
        if (v != null) { return v }
        v = resolve(platform, dottedPath)
        return v != null ? v : defaultValue
    }

    private static def resolve(Map map, String dottedPath) {
        def node = map
        for (String part : dottedPath.split('\\.')) {
            if (!(node instanceof Map) || !node.containsKey(part)) { return null }
            node = node[part]
        }
        return node
    }

    /** Is a pipeline stage currently enabled? (flags flip as phases land) */
    boolean isStageEnabled(String stageKey) {
        def stage = get("stages.${stageKey}", null)
        if (stage instanceof Map) { return stage.enabled as boolean }
        return false
    }

    /** Human-readable reason for a disabled stage (e.g. "wired in Phase 7"). */
    String stageSkipReason(String stageKey) {
        def stage = get("stages.${stageKey}", [:])
        def phase = (stage instanceof Map) ? stage.enabledInPhase : null
        return phase ? "stage implementation lands in Phase ${phase}; flag 'stages.${stageKey}.enabled' then flips in platform-config.yaml" \
                     : "stage '${stageKey}' is disabled in platform configuration"
    }

    String agentLabelFor(String language) {
        return get("agentLabels.${language}", language) as String
    }

    /**
     * Fail-closed validation of project overrides:
     *  - security sections listed in MANDATORY_SECTIONS cannot be disabled
     *  - any security block_on_* flag may only be turned ON, never OFF
     *  - environments must be a subset of the organization list
     */
    void validateOverrides() {
        def sec = project?.security
        if (sec instanceof Map) {
            for (String section : MANDATORY_SECTIONS) {
                if (sec.containsKey(section)) {
                    def entry = sec[section]
                    if (entry instanceof Map && (entry.enabled == false || entry.required == false)) {
                        throw new IllegalStateException(
                            "devsecops.yaml attempts to disable mandatory security section '${section}'. " +
                            "This is not permitted; request a time-boxed exception via security/policies/exceptions instead.")
                    }
                }
            }
            def platformSec = platform?.securityPolicyDefaults ?: [:]
            for (Map.Entry e : flatten(sec).entrySet()) {
                if (e.key.startsWith('block_on_') || e.key == 'block_on_detection') {
                    def platformValue = flatten(platformSec)[e.key as String]
                    if (platformValue == true && e.value == false) {
                        throw new IllegalStateException(
                            "devsecops.yaml weakens security flag '${e.key}' (platform=true, project=false). Only tightening is allowed.")
                    }
                }
            }
        }
        def envs = project?.environments
        if (envs instanceof List) {
            def allowed = (platform?.environments ?: []) as List
            def illegal = envs.findAll { !allowed.contains(it) }
            if (illegal) {
                throw new IllegalStateException("devsecops.yaml declares unknown environments ${illegal}; allowed: ${allowed}")
            }
        }
    }

    /** Flatten nested maps to dotted keys (used for flag comparison). */
    static Map<String, Object> flatten(Map map, String prefix = '') {
        Map<String, Object> out = [:]
        for (Map.Entry e : map.entrySet()) {
            String key = prefix ? "${prefix}.${e.key}" : e.key as String
            if (e.value instanceof Map) {
                out.putAll(flatten(e.value as Map, key))
            } else {
                out[key] = e.value
            }
        }
        return out
    }
}
