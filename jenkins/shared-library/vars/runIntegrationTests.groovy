import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * runIntegrationTests — convention-driven integration tests (Phase 6).
 *
 * Integration tests are OPT-IN by convention; the step detects the marker and
 * only then executes, otherwise it reports an explicit skip (never a silent
 * pass). Conventions per language (documented in the library README):
 *   java/maven   → maven-failsafe-plugin present in pom.xml   → failsafe:integration-test verify
 *   java/gradle  → task named 'integrationTest'                → gradle integrationTest
 *   dotnet       → [Trait("Category","Integration")] in tests  → dotnet test --filter Category=Integration
 *   python       → @pytest.mark.integration in tests           → pytest -m integration
 *   nodejs       → "test:integration" script in package.json   → <pm> run test:integration
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('runIntegrationTests: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Integration Tests'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    def repos = (cfg.get('nexus.repositories', [:]) ?: [:]) as Map
    String language  = svc.language as String
    String buildTool = (svc.buildTool ?: '') as String

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        try {
            dir(svc.path as String) {
                switch (language) {

                    case 'java':
                        if (buildTool.contains('gradle')) {
                            if (sh(returnStatus: true, script: 'gradle -q help --task integrationTest >/dev/null 2>&1 || ./gradlew -q help --task integrationTest >/dev/null 2>&1') != 0) {
                                log.stageSkipped('integrationTests', "no 'integrationTest' gradle task")
                                return
                            }
                            String init = RepoConfig.gradleInit(this, nexusBase, repos)
                            String gw = fileExists('./gradlew') ? './gradlew' : 'gradle'
                            sh "${gw} --no-daemon --init-script ${init} integrationTest"
                            junit testResults: '**/build/test-results/integrationTest/**/*.xml', allowEmptyResults: true
                        } else {
                            if (sh(returnStatus: true, script: "grep -q 'maven-failsafe-plugin' pom.xml */pom.xml 2>/dev/null") != 0) {
                                log.stageSkipped('integrationTests', 'no maven-failsafe-plugin in pom.xml')
                                return
                            }
                            String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
                            String mvn = fileExists('./mvnw') ? './mvnw' : 'mvn'
                            sh "${mvn} -B -e -s ${settings} failsafe:integration-test failsafe:verify"
                            junit testResults: '**/target/failsafe-reports/**/*.xml', allowEmptyResults: true
                        }
                        break

                    case 'dotnet':
                        String nugetCfg = RepoConfig.nugetConfig(this, nexusBase, repos)
                        if (sh(returnStatus: true, script: "grep -rq 'Category=\\\"Integration\\\"\\|Category, \\\"Integration\\\"' --include='*.cs' . 2>/dev/null") != 0) {
                            log.stageSkipped('integrationTests', 'no [Trait("Category","Integration")] tests found')
                            return
                        }
                        sh "cp '${nugetCfg}' ./nuget.config"
                        String target = findFirst(['*.sln', '*.csproj'])
                        sh "dotnet test '${target}' -c Release --filter Category=Integration"
                        sh "rm -f ./nuget.config"
                        break

                    case 'python':
                        if (sh(returnStatus: true, script: "grep -rq 'pytest.mark.integration' --include='*.py' . 2>/dev/null") != 0) {
                            log.stageSkipped('integrationTests', 'no @pytest.mark.integration tests found')
                            return
                        }
                        String indexUrl = RepoConfig.pythonIndexShell(nexusBase, repos)
                        String trustedHost = RepoConfig.hostOf(nexusBase)
                        int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install --quiet --index-url '${indexUrl}' --trusted-host '${trustedHost}' pytest || true
python -m pytest -q -m integration --junitxml=reports/integration-junit.xml || rc=\$?
[ "\${rc:-0}" -eq 5 ] && exit 0
exit "\${rc:-0}"
""")
                        if (rc != 0) { error("${STAGE}: integration pytest failed (rc=${rc})") }
                        junit testResults: 'reports/integration-junit.xml', allowEmptyResults: true
                        break

                    case 'nodejs':
                        String npmrc = RepoConfig.npmrc(this, nexusBase, repos, NEXUS_USER, NEXUS_PASS)
                        String pm = resolveNodePackageManager(svc)
                        if (!hasNpmScript('test:integration')) {
                            log.stageSkipped('integrationTests', "no 'test:integration' script in package.json")
                            return
                        }
                        withEnv(["NPM_CONFIG_USERCONFIG=${npmrc}",
                                 "NPM_CONFIG_REGISTRY=${nexusBase}/repository/${repos.npmPublic ?: 'npm-public'}/",
                                 "CI=true"]) {
                            sh "${pm} run test:integration"
                        }
                        junit testResults: 'reports/**/*.xml', allowEmptyResults: true
                        break

                    default:
                        log.stageSkipped('integrationTests', "no integration-test recipe for language '${language}'")
                }
            }
        } finally {
            RepoConfig.cleanup(this)
        }
    }
}

// ---------------------------------------------------------------------------
// helpers (private to this vars script)
// ---------------------------------------------------------------------------

private String findFirst(List<String> patterns) {
    for (String p : patterns) {
        def found = findFiles(glob: p)
        if (found && found.length > 0) { return found[0].name }
    }
    return ''
}

private String resolveNodePackageManager(Map svc) {
    String declared = (svc.packageManager ?: '') as String
    if (declared in ['npm', 'pnpm', 'yarn']) { return declared }
    if (fileExists('pnpm-lock.yaml')) { return 'pnpm' }
    if (fileExists('yarn.lock'))      { return 'yarn' }
    return 'npm'
}

private boolean hasNpmScript(String name) {
    int rc = sh(returnStatus: true,
        script: "node -e \"process.exit((require('./package.json').scripts||{})['${name}'] ? 0 : 1)\"")
    return rc == 0
}
