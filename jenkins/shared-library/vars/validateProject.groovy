import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig

/**
 * Validates discovered services against platform contracts BEFORE any build
 * work starts (fail fast, fail loud).
 *
 * args:
 *   services : List<Map> from detectProject
 *   config   : PlatformConfig (loaded)
 *
 * Checks per service:
 *   - language is supported by the platform (python|java|dotnet|nodejs)
 *   - deploymentType is helm|kustomize
 *   - environments declared in devsecops.yaml ⊆ organization environments
 *   - if a Dockerfile is referenced by devsecops.yaml, it exists
 *   - service names are unique across the repository
 *   - lockfile policy: node projects must have a lockfile (enforced unless
 *     the project explicitly opts out via devsecops.yaml allowNoLockfile)
 */
def call(Map args = [:]) {
    def log = new PipelineLogger(this, env.JOB_NAME ?: 'validate')
    List<Map> services = (args.services ?: []) as List
    PlatformConfig cfg = args.config as PlatformConfig
    if (services.isEmpty()) { error('validateProject: no services to validate — run detectProject first') }

    def supportedLanguages = (cfg?.get('supportedLanguages', ['python', 'java', 'dotnet', 'nodejs'])) as List
    def allowedDeploymentTypes = (cfg?.get('deploymentTypes', ['helm', 'kustomize'])) as List
    def allowedEnvironments = (cfg?.get('environments', ['dev', 'qa', 'uat', 'prod'])) as List

    def problems = []
    def seenNames = [:]

    for (Map svc : services) {
        String name = svc.name as String
        String where = "service '${name}' (${svc.path})"

        if (seenNames.containsKey(name)) {
            problems << "${where}: duplicate serviceName (also at '${seenNames[name]}') — set a unique serviceName in devsecops.yaml"
        }
        seenNames[name] = svc.path

        if (!supportedLanguages.contains(svc.language as String)) {
            problems << "${where}: language '${svc.language}' is not supported by the platform (supported: ${supportedLanguages})"
        }
        if (!allowedDeploymentTypes.contains(svc.deploymentType as String)) {
            problems << "${where}: deploymentType '${svc.deploymentType}' invalid (allowed: ${allowedDeploymentTypes})"
        }

        def svcEnvs = (svc.extra?.environments ?: []) as List
        def illegal = svcEnvs.findAll { !allowedEnvironments.contains(it) }
        if (illegal) {
            problems << "${where}: unknown environments ${illegal} (allowed: ${allowedEnvironments})"
        }

        if (svc.language == 'nodejs' && !(svc.packageManager) && svc.extra?.allowNoLockfile != true) {
            problems << "${where}: Node.js project without a lockfile (package-lock.json / pnpm-lock.yaml / yarn.lock). " +
                        "Commit a lockfile or set 'allowNoLockfile: true' in devsecops.yaml with justification."
        }

        def referencedDockerfile = svc.extra?.dockerfile as String
        if (referencedDockerfile) {
            def dfPath = "${svc.path == '.' ? '' : svc.path + '/'}${referencedDockerfile}"
            if (!fileExists(dfPath)) {
                problems << "${where}: devsecops.yaml references dockerfile '${referencedDockerfile}' which does not exist at '${dfPath}'"
            }
        }
    }

    if (problems) {
        def msg = "validateProject failed with ${problems.size()} problem(s):\n  - " + problems.join('\n  - ')
        log.error('Validate', msg)
        error(msg)
    }
    log.info('Validate', "all ${services.size()} service(s) conform to platform contracts")
    return true
}
