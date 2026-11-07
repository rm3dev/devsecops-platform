import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger

/**
 * Project discovery engine (master spec §7) — Phase 3 implementation.
 *
 * Inspects the checked-out repository and returns a List<Map> of discovered
 * deployable services. Detection is MANIFEST-DRIVEN (not extension-driven):
 *
 *   python      pyproject.toml | setup.py | requirements*.txt | Pipfile
 *   java        pom.xml | build.gradle | build.gradle.kts   (framework:
 *               'spring-boot' detected from build-file content)
 *   dotnet      *.sln | *.csproj | global.json
 *   nodejs      package.json (+ lockfile → npm|pnpm|yarn; framework from
 *               dependencies: react|angular|vue|next|nuxt|svelte|express|nest)
 *
 * Monorepo aware: every directory containing a manifest is a candidate
 * service; npm-workspace roots and Maven aggregator POMs (<packaging>pom +
 * <modules>) are excluded unless they carry their own Dockerfile. Each
 * service may carry a devsecops.yaml declaring serviceName, dependsOn
 * (shared-library impact analysis) and deploymentType.
 *
 * args:
 *   maxDepth      (default 4)  directory scan depth
 *   changedOnly   (default false) restrict to services touched since
 *                 env.GIT_PREVIOUS_SUCCESSFUL_COMMIT (+ their dependents)
 *   baseRef       diff base for changedOnly
 *   servicePath   scan a subdirectory only
 *
 * Output: returns List<Map> AND writes reports/project-discovery.json.
 */
def call(Map args = [:]) {
    def log = new PipelineLogger(this, args.serviceName ?: env.JOB_NAME ?: 'discovery')
    int maxDepth = (args.maxDepth ?: 4) as int
    String scanRoot = (args.servicePath && args.servicePath != '.') ? args.servicePath : '.'

    def excludes = ['node_modules', '.git', 'target', 'build', 'dist', '.venv', 'venv',
                    '.gradle', '.m2', 'coverage', '__pycache__', '.idea', 'bin', 'obj',
                    'charts', 'helm-charts', '.next', '.nuxt']
    def pruneExpr = excludes.collect { "-name '${it}'" }.join(' -o ')
    def manifests = "-name pyproject.toml -o -name setup.py -o -name requirements.txt -o -name 'requirements-*.txt' -o -name Pipfile -o -name poetry.lock -o -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name '*.sln' -o -name '*.csproj' -o -name global.json -o -name package.json -o -name Dockerfile -o -name 'Dockerfile.*' -o -name devsecops.yaml"

    def findCmd = "find '${scanRoot}' -maxdepth ${maxDepth} \\( ${pruneExpr} \\) -prune -o -type f \\( ${manifests} \\) -print"
    def raw = sh(script: findCmd, returnStdout: true).trim()

    // --- group files by directory -------------------------------------------
    Map<String, List<String>> byDir = [:]
    if (raw) {
        for (String line : raw.split('\n')) {
            line = line.trim()
            if (!line) { continue }
            int idx = line.lastIndexOf('/')
            String dir = idx > 0 ? line.substring(0, idx) : '.'
            String file = idx > 0 ? line.substring(idx + 1) : line
            if (!byDir.containsKey(dir)) { byDir[dir] = [] }
            byDir[dir] << file
        }
    }

    // --- classify each directory --------------------------------------------
    List<Map> services = []
    for (Map.Entry<String, List<String>> entry : byDir.entrySet()) {
        Map svc = classifyDir(entry.key, entry.value)
        if (svc != null) { services << svc }
    }

    // --- changed-only filter (selective monorepo builds) ----------------------
    if (args.changedOnly) {
        services = filterChanged(services, args.baseRef, log)
    }

    if (services.isEmpty()) {
        error("detectProject: no deployable services found under '${scanRoot}' (manifests searched: python/java/dotnet/node). " +
              "Add a manifest or a devsecops.yaml, or check 'maxDepth' (current: ${maxDepth}).")
    }

    // Deterministic order for stable parallel execution
    services = services.sort { it.name as String }

    dir('reports') {
        writeJSON file: 'project-discovery.json', json: services, pretty: 2
    }
    log.info('Discovery', "found ${services.size()} service(s): " +
        services.collect { "${it.name}[${it.language}/${it.buildTool}${it.framework ? '/' + it.framework : ''}]" }.join(', '))
    return services
}

/** Classify one directory based on its manifest files. Returns null if it is
 *  not a deployable service (workspace root / aggregator without Dockerfile). */
private Map classifyDir(String dirPath, List<String> files) {
    boolean hasDockerfile = files.any { it == 'Dockerfile' || it.startsWith('Dockerfile.') }

    // Per-service metadata wins over inference
    Map meta = [:]
    if (files.contains('devsecops.yaml')) {
        meta = readYaml(file: "${dirPath}/devsecops.yaml") ?: [:]
    }

    String language = meta.language ?: inferLanguage(files)
    if (language == null && !hasDockerfile) { return null }

    // Workspace-root / aggregator exclusion unless self-deployable
    boolean isAggregator = false
    if (dirPath == '.' || dirPath.isEmpty()) {
        if (files.contains('package.json') && fileContains("${dirPath}/package.json", '"workspaces"')) { isAggregator = true }
        if (files.contains('pom.xml') && fileContains("${dirPath}/pom.xml", '<modules>')) { isAggregator = true }
    }
    if (isAggregator && !hasDockerfile && !meta.language) { return null }
    if (language == null) { return null }   // dockerfile-only dirs without language metadata

    String name = (meta.serviceName ?: defaultServiceName(dirPath)) as String
    String buildTool = meta.buildTool ?: inferBuildTool(language, files)
    String framework = meta.framework ?: inferFramework(language, dirPath, files)
    String packageManager = meta.packageManager ?: inferPackageManager(files)

    return [
        name           : name,
        path           : dirPath == '.' ? '.' : dirPath,
        language       : language,
        buildTool      : buildTool,
        framework      : framework,
        packageManager : packageManager,
        dockerfiles    : files.findAll { it == 'Dockerfile' || it.startsWith('Dockerfile.') },
        hasDockerfile  : hasDockerfile,
        dependsOn      : (meta.dependsOn ?: []) as List,
        deploymentType : meta.deploymentType ?: 'helm',
        extra          : meta.extra ?: [:],
    ]
}

private String defaultServiceName(String dirPath) {
    if (dirPath == '.' || dirPath.isEmpty()) {
        // single-app repository → derive from git remote or job name
        def url = env.GIT_URL ?: ''
        def m = (url =~ /.*\/([^\/]+?)(\.git)?$/)
        return m.matches() ? m[0][1] : (env.JOB_NAME ?: 'application').replaceAll('[^A-Za-z0-9_.-]', '-')
    }
    return dirPath.replaceFirst('^\\./', '').replaceAll('[/\\\\]', '_')
}

private String inferLanguage(List<String> files) {
    if (files.any { it == 'pom.xml' || it == 'build.gradle' || it == 'build.gradle.kts' }) { return 'java' }
    if (files.any { it == 'package.json' }) { return 'nodejs' }
    if (files.any { it.endsWith('.csproj') || it.endsWith('.sln') || it == 'global.json' }) { return 'dotnet' }
    if (files.any { it == 'pyproject.toml' || it == 'setup.py' || it == 'Pipfile' || it ==~ /requirements.*\.txt/ }) { return 'python' }
    return null
}

private String inferBuildTool(String language, List<String> files) {
    switch (language) {
        case 'java':
            if (files.contains('pom.xml')) { return files.contains('mvnw') ? 'maven-wrapper' : 'maven' }
            return files.contains('gradlew') ? 'gradle-wrapper' : 'gradle'
        case 'python':
            if (files.contains('poetry.lock') || files.contains('pyproject.toml')) {
                return fileContainsSafe('pyproject.toml', '[tool.poetry]') ? 'poetry' : (files.contains('poetry.lock') ? 'poetry' : 'pip')
            }
            return files.contains('Pipfile') ? 'pipenv' : 'pip'
        case 'dotnet':  return 'msbuild'
        case 'nodejs':  return inferPackageManager(files) ?: 'npm'
        default:        return 'unknown'
    }
}

private String inferPackageManager(List<String> files) {
    if (files.contains('pnpm-lock.yaml')) { return 'pnpm' }
    if (files.contains('yarn.lock'))      { return 'yarn' }
    if (files.contains('package-lock.json')) { return 'npm' }
    return null
}

private String inferFramework(String language, String dirPath, List<String> files) {
    if (language == 'java') {
        def buildFile = files.contains('pom.xml') ? "${dirPath}/pom.xml" :
                        files.contains('build.gradle.kts') ? "${dirPath}/build.gradle.kts" :
                        files.contains('build.gradle') ? "${dirPath}/build.gradle" : null
        if (buildFile && fileContains(buildFile, 'spring-boot')) { return 'spring-boot' }
        return null
    }
    if (language == 'nodejs') {
        def pkg = "${dirPath}/package.json"
        for (String fw : ['next', 'nuxt', 'react', 'angular', 'vue', 'svelte', 'express', 'nest', '@nestjs/core']) {
            if (fileContains(pkg, fw)) { return fw.replace('@nestjs/core', 'nestjs').replace('@', '') }
        }
        return null
    }
    if (language == 'python') {
        for (String fw : ['fastapi', 'django', 'flask']) {
            def manifest = files.contains('pyproject.toml') ? "${dirPath}/pyproject.toml" :
                           files.contains('requirements.txt') ? "${dirPath}/requirements.txt" : null
            if (manifest && fileContains(manifest, fw)) { return fw }
        }
        return null
    }
    return null
}

private boolean fileContains(String path, String needle) {
    def count = sh(script: "grep -c -- '${needle}' '${path}' 2>/dev/null || true", returnStdout: true).trim()
    return count.isInteger() && (count as int) > 0
}

private boolean fileContainsSafe(String fileName, String needle) {
    return fileExists(fileName) && fileContains(fileName, needle)
}

/** changedOnly: keep services whose paths appear in the diff, plus services
 *  that declare dependsOn a changed shared directory. */
private List<Map> filterChanged(List<Map> services, String baseRef, PipelineLogger log) {
    String base = baseRef ?: env.GIT_PREVIOUS_SUCCESSFUL_COMMIT ?: env.GIT_PREVIOUS_COMMIT ?: ''
    if (!base) {
        log.info('Discovery', 'changedOnly requested but no previous commit recorded (first build) — building everything')
        return services
    }
    def changed = sh(script: "git diff --name-only '${base}' HEAD 2>/dev/null || true", returnStdout: true).trim()
    if (!changed) {
        log.info('Discovery', "no file changes between ${base} and HEAD — building everything")
        return services
    }
    List<String> changedPaths = []
    for (String path : changed.split('\n')) {
        String normalizedPath = path.trim()
        if (normalizedPath) { changedPaths.add(normalizedPath) }
    }
    log.info('Discovery', "${changedPaths.size()} changed path(s) since ${base.take(8)}")

    List<Map> selected = []
    List<String> changedServiceNames = []
    for (Map svc : services) {
        String prefix = (svc.path == '.' ? '' : (svc.path as String) + '/')
        boolean touched = changedPaths.any { prefix ? it.startsWith(prefix) : it.contains('/') == false }
        if (touched) { selected << svc; changedServiceNames << (svc.name as String) }
    }
    // Dependent rebuilds: shared library changed → rebuild consumers
    for (Map svc : services) {
        if (selected.contains(svc)) { continue }
        def deps = (svc.dependsOn ?: []) as List
        if (deps.any { changedServiceNames.contains(it) }) {
            log.info('Discovery', "including '${svc.name}' — depends on changed ${deps.intersect(changedServiceNames)}")
            selected << svc
        }
    }
    if (selected.isEmpty()) {
        log.info('Discovery', 'changed paths match no service (docs/CI-only change) — nothing to build')
    }
    return selected
}
