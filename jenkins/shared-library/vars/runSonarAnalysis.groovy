import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * runSonarAnalysis — Quality Gate stage implementation (Phase 5, D-20).
 *
 * Called by microservicePipeline's dispatcher as:
 *     runSonarAnalysis(service: svc, config: args)
 *
 * Gate enforcement strategy (decision D-20):
 *   Every scanner invocation carries sonar.qualitygate.wait=true, so the
 *   scanner itself blocks until the Compute Engine finishes, then EXITS
 *   NON-ZERO when the gate is ERROR. This works on ALL SonarQube editions,
 *   including Community Build (webhooks — configured best-effort by
 *   sonarqube/scripts/10-admin-bootstrap.sh — are therefore a notification
 *   bonus, never the enforcement path).
 *
 * Community Build has no branch/MR analysis (single branch per project):
 *   non-main branches are isolated into their own project keys
 *   ("<repo>--<service>--<branch>") so feature builds never pollute the
 *   main-line gate history. With Developer Edition+, drop the branch suffix
 *   and enable sonar.branch.name instead (documented in security.md).
 *
 * dotnet specifics: the C# analyzer requires begin/end around build+test, so
 * this step is self-contained for dotnet (build + test + analysis).
 *
 * Execution context: the dispatcher already placed us on the correct
 * per-language agent; the source arrives via the 'source' stash. NO nested
 * node() allocation here (would contend with warm-pool executors).
 */
def call(Map params = [:]) {
    def svc  = params.service ?: error('runSonarAnalysis: "service" map is required')
    def log  = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Quality Gate'

    // --------------------------------------------------------- config ------
    // Layered: platform-config.yaml 'sonar' section, overridable per project
    // via devsecops.yaml (sonar.qualityGateTimeoutSec, sonar.serverName …).
    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    def sonarCfg = (cfg.get('sonar', [:]) ?: [:]) as Map
    int gateTimeout = (sonarCfg.qualityGateTimeoutSec ?: 600) as int
    String serverName = (sonarCfg.serverName ?: 'SonarQube') as String
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    def repos = (cfg.get('nexus.repositories', [:]) ?: [:]) as Map

    // --------------------------------------------------------- project key --
    String repoSlug = slugify(repoIdentifier())
    String projectKey = (svc.extra?.sonarProjectKey ?: "${repoSlug}--${slugify(svc.name as String)}") as String
    String branch = (env.GIT_BRANCH_NAME ?: 'main') as String
    if (!(branch in ['main', 'develop'])) {
        projectKey = "${projectKey}--${slugify(branch)}".take(400)
        log.info(STAGE, "Community Build branch isolation: analysing as project '${projectKey}'")
    }
    log.info(STAGE, "projectKey=${projectKey} gate=platform-default (server default) waitTimeout=${gateTimeout}s")

    // ------------------------------------------------------------ analysis --
    unstash 'source'
    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        try {
            withSonarQubeEnv(serverName) {          // injects SONAR_HOST_URL + SONAR_AUTH_TOKEN
                dir(svc.path as String) {
                    String waitProps = "-Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=${gateTimeout}"
                    switch ((svc.language as String)) {
                        case 'java':
                            if ((svc.buildTool as String)?.contains('gradle')) {
                                String init = RepoConfig.gradleInit(this, nexusBase, repos)
                                String gw = fileExists('./gradlew') ? './gradlew' : 'gradle'
                                sh "${gw} --no-daemon --init-script ${init} sonar " +
                                   "-Dsonar.projectKey=${projectKey} -Dsonar.token=\$SONAR_AUTH_TOKEN " +
                                   "-Dsonar.host.url=\$SONAR_HOST_URL -Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=${gateTimeout}"
                            } else {
                                String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
                                String mvn = fileExists('./mvnw') ? './mvnw' : 'mvn'
                                sh "${mvn} -B -e -s ${settings} sonar:sonar " +
                                   "-Dsonar.projectKey=${projectKey} ${waitProps}"
                            }
                            break
                        case 'dotnet':
                            // NuGet.config in cwd → automatic discovery for every dotnet command
                            String nugetCfg = RepoConfig.nugetConfig(this, nexusBase, repos)
                            sh "cp '${nugetCfg}' ./nuget.config"
                            String target = findFirst(['*.sln', '*.csproj'])
                            String beginArgs = "/k:${projectKey} /d:sonar.host.url=\$SONAR_HOST_URL /d:sonar.token=\$SONAR_AUTH_TOKEN " +
                                               "/d:sonar.qualitygate.wait=true /d:sonar.qualitygate.timeout=${gateTimeout} " +
                                               '/d:sonar.cs.opencover.reportsPaths="**/coverage.opencover.xml"'
                            sh "dotnet-sonarscanner begin ${beginArgs}"
                            sh "dotnet build ${target} -c Release --no-incremental"
                            sh "dotnet test ${target} -c Release --no-build --collect:'XPlat Code Coverage' --results-directory TestResults || true"
                            sh "dotnet-sonarscanner end /d:sonar.token=\$SONAR_AUTH_TOKEN"
                            sh "rm -f ./nuget.config"
                            break
                        case 'python':
                        case 'nodejs':
                        default:
                            // sonar-scanner CLI (baked into python/node/general agents, Phase 3)
                            String sources = (svc.language == 'python') ? 'src,app,.' : '.'
                            sh "sonar-scanner " +
                               "-Dsonar.projectKey=${projectKey} " +
                               "-Dsonar.projectName=${svc.name} " +
                               "-Dsonar.sources=${sources} " +
                               "-Dsonar.exclusions=**/node_modules/**,**/venv/**,**/.venv/**,**/dist/**,**/build/**,**/*.min.js " +
                               "-Dsonar.qualitygate.wait=true -Dsonar.qualitygate.timeout=${gateTimeout}"
                    }
                }
            }
            reportGateStatus(projectKey, serverName, log, STAGE)
        } catch (Exception e) {
            // Scanner exits non-zero on gate ERROR when qualitygate.wait=true.
            reportGateStatus(projectKey, serverName, log, STAGE)
            log.blocked(STAGE, "quality gate FAILED or analysis errored for '${svc.name}': ${e.message?.take(200)}")
            throw e
        } finally {
            RepoConfig.cleanup(this)
        }
    }
}

// ---------------------------------------------------------------------------
// helpers (private to this vars script)
// ---------------------------------------------------------------------------

private String repoIdentifier() {
    // stable per-repo identifier independent of branch: GitLab project path if
    // available, else the job's top folder chain, else git remote name.
    if (env.GITLAB_PROJECT_PATH) { return env.GITLAB_PROJECT_PATH }
    def url = env.GIT_URL ?: ''
    if (url) {
        def m = (url =~ /[:\/]([^\/]+\/[^\/]+?)(\.git)?$/)
        if (m) { return m[0][1] }
    }
    def jobParts = (env.JOB_NAME ?: 'unknown').split('/')
    return jobParts.length > 1 ? jobParts[0..-2].join('/') : jobParts[0]
}

private String slugify(String s) {
    return (s ?: 'x').replaceAll('[^A-Za-z0-9._-]', '_')
}

private String findFirst(List<String> patterns) {
    for (String p : patterns) {
        def found = findFiles(glob: p)
        if (found && found.length > 0) { return found[0].name }
    }
    return ''
}

/** Best-effort: fetch + log the gate verdict and dashboard link. */
private void reportGateStatus(String projectKey, String serverName, PipelineLogger log, String stage) {
    try {
        withSonarQubeEnv(serverName) {
            def json = sh(returnStdout: true, script:
                "curl -sS -m 20 -u \$SONAR_AUTH_TOKEN: \"\$SONAR_HOST_URL/api/qualitygates/project_status?projectKey=${projectKey}\" || true").trim()
            if (json) {
                def parsed = readJSON(text: json)
                def status = parsed?.projectStatus?.status ?: 'UNKNOWN'
                def url = parsed?.projectStatus?.dashboardUrl ?: ''
                log.info(stage, "quality gate status: ${status}${url ? " — ${url}" : ''}")
                def failed = parsed?.projectStatus?.conditions?.findAll { it.status == 'ERROR' } ?: []
                failed.each { c -> log.warn(stage, "condition FAILED: ${c.metricKey} ${c.comparator} ${c.errorThreshold} (actual: ${c.actualValue ?: 'n/a'})") }
            }
        }
    } catch (Exception ignored) {
        echo 'runSonarAnalysis: gate status report failed (non-fatal)'
    }
}
