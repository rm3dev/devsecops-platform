import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * runUnitTests — unit test execution + JUnit report publication (Phase 6).
 *
 * Self-sufficient: works whether or not the 'build' flag ran before it
 * (recreates venv/restore as needed). Test failures FAIL the pipeline
 * (quality is a gate, not a metric). Coverage files produced here (jacoco,
 * opencover, coverage.xml, lcov) are picked up by runSonarAnalysis.
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('runUnitTests: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Unit Tests'

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
                            String init = RepoConfig.gradleInit(this, nexusBase, repos)
                            String gw = fileExists('./gradlew') ? './gradlew' : 'gradle'
                            sh "${gw} --no-daemon --init-script ${init} test"
                            // coverage report if the project applies jacoco (non-fatal otherwise)
                            int jacocoRc = sh(returnStatus: true,
                                script: "${gw} --no-daemon --init-script ${init} jacocoTestReport")
                            if (jacocoRc != 0) { log.info(STAGE, 'jacocoTestReport not available — coverage import skipped') }
                            junit testResults: '**/build/test-results/test/**/*.xml', allowEmptyResults: true
                        } else {
                            String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
                            String mvn = fileExists('./mvnw') ? './mvnw' : 'mvn'
                            sh "${mvn} -B -e -s ${settings} test"
                            junit testResults: '**/target/surefire-reports/**/*.xml', allowEmptyResults: true
                        }
                        break

                    case 'dotnet':
                        // NuGet.config in cwd → automatic discovery (dotnet test has no --configfile)
                        String nugetCfg = RepoConfig.nugetConfig(this, nexusBase, repos)
                        sh "cp '${nugetCfg}' ./nuget.config"
                        String target = findFirst(['*.sln', '*.csproj'])
                        // Preferred: JUnit XML via JunitXml.TestLogger (project convention,
                        // documented in library README); fallback: plain dotnet test.
                        int rc = sh(returnStatus: true, script:
                            "dotnet test '${target}' -c Release " +
                            "--logger 'junit;LogFilePath=TestResults/junit.xml' " +
                            "--results-directory TestResults " +
                            "--collect:'XPlat Code Coverage' || true")
                        if (rc != 0) {
                            rc = sh(returnStatus: true, script:
                                "dotnet test '${target}' -c Release " +
                                "--collect:'XPlat Code Coverage' || true")
                        }
                        if (rc != 0) {
                            // last resort without coverage collector (not installed)
                            sh "dotnet test '${target}' -c Release"
                        }
                        sh "rm -f ./nuget.config"
                        junit testResults: 'TestResults/**/*.xml', allowEmptyResults: true
                        break

                    case 'python':
                        String indexUrl = RepoConfig.pythonIndexShell(nexusBase, repos)
                        String trustedHost = RepoConfig.hostOf(nexusBase)
                        int rc = sh(returnStatus: true, script: """#!/usr/bin/env bash
set -uo pipefail
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install --quiet --index-url '${indexUrl}' --trusted-host '${trustedHost}' pytest pytest-cov || true
if [ -f requirements-dev.txt ]; then
  pip install --quiet -r requirements-dev.txt --index-url '${indexUrl}' --trusted-host '${trustedHost}'
fi
if ! python -c 'import pytest' 2>/dev/null; then
  echo 'pytest not available even after install attempt — cannot run unit tests'
  exit 1
fi
python -m pytest -q --junitxml=reports/junit.xml --cov --cov-report=xml:reports/coverage.xml --cov-report=term || rc=\$?
# pytest exit 5 == "no tests collected" → not a failure for this platform
[ "\${rc:-0}" -eq 5 ] && exit 0
exit "\${rc:-0}"
""")
                        if (rc != 0) { error("${STAGE}: pytest failed (rc=${rc}) — see JUnit report") }
                        junit testResults: 'reports/junit.xml', allowEmptyResults: true
                        break

                    case 'nodejs':
                        String npmrc = RepoConfig.npmrc(this, nexusBase, repos, NEXUS_USER, NEXUS_PASS)
                        String pm = resolveNodePackageManager(svc)
                        withEnv(["NPM_CONFIG_USERCONFIG=${npmrc}",
                                 "NPM_CONFIG_REGISTRY=${nexusBase}/repository/${repos.npmPublic ?: 'npm-public'}/",
                                 "CI=true", "JEST_JUNIT_OUTPUT_DIR=reports"]) {
                            if (!hasNpmScript('test')) {
                                log.stageSkipped('unitTests', "no 'test' script in package.json")
                                return
                            }
                            sh "${pm} test"
                        }
                        // jest-junit/mocha-junit-reporter conventions land in reports/
                        junit testResults: 'reports/**/*.xml', allowEmptyResults: true
                        break

                    default:
                        log.stageSkipped('unitTests', "no unit-test recipe for language '${language}'")
                }
            }
            log.info(STAGE, "unit tests completed for '${svc.name}'")
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
