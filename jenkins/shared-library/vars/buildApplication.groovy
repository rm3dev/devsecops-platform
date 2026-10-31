import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * buildApplication — compile/resolve dependencies per language (Phase 6).
 * Runs on the service's language agent (dispatcher-allocated); all dependency
 * traffic goes through Nexus via RepoConfig (D-16). Tests are NOT run here —
 * see runUnitTests / runIntegrationTests.
 */
def call(Map params = [:]) {
    def svc  = params.service ?: error('buildApplication: "service" map is required')
    def log  = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Build'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    def repos = (cfg.get('nexus.repositories', [:]) ?: [:]) as Map
    String language  = svc.language as String
    String buildTool = (svc.buildTool ?: '') as String
    log.info(STAGE, "language=${language} buildTool=${buildTool ?: '-'} path=${svc.path}")

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        try {
            dir(svc.path as String) {
                switch (language) {

                    case 'java':
                        if (buildTool.contains('gradle')) {
                            String init = RepoConfig.gradleInit(this, nexusBase, repos)
                            String gw = (buildTool.contains('wrapper') && fileExists('./gradlew')) ? './gradlew' : 'gradle'
                            sh "${gw} --no-daemon --init-script ${init} build -x test"
                        } else {
                            String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
                            String mvn = (buildTool.contains('wrapper') && fileExists('./mvnw')) ? './mvnw' : 'mvn'
                            sh "${mvn} -B -e -s ${settings} -DskipTests clean install"
                        }
                        break

                    case 'dotnet':
                        String nugetCfg = RepoConfig.nugetConfig(this, nexusBase, repos)
                        String target = findFirst(['*.sln', '*.csproj'])
                        if (!target) { error("${STAGE}: no .sln/.csproj found in ${svc.path}") }
                        sh "dotnet restore '${target}' --configfile '${nugetCfg}'"
                        sh "dotnet build '${target}' -c Release --no-restore"
                        break

                    case 'nodejs':
                        String npmrc = RepoConfig.npmrc(this, nexusBase, repos, NEXUS_USER, NEXUS_PASS)
                        String pm = resolveNodePackageManager(svc)
                        withEnv(["NPM_CONFIG_USERCONFIG=${npmrc}",
                                 "NPM_CONFIG_REGISTRY=${nexusBase}/repository/${repos.npmPublic ?: 'npm-public'}/",
                                 "YARN_REGISTRY=${nexusBase}/repository/${repos.npmPublic ?: 'npm-public'}/"]) {
                            log.info(STAGE, "package manager: ${pm}")
                            if (pm == 'pnpm')      { sh 'pnpm install --frozen-lockfile' }
                            else if (pm == 'yarn') { sh 'yarn install --frozen-lockfile' }
                            else                   { sh 'npm ci --no-audit --no-fund' }
                            if (hasNpmScript('build')) {
                                sh "${pm} run build"
                            } else {
                                log.info(STAGE, "no 'build' script in package.json — dependency install only")
                            }
                        }
                        break

                    case 'python':
                        String indexUrl = RepoConfig.pythonIndexShell(nexusBase, repos)
                        String trustedHost = RepoConfig.hostOf(nexusBase)
                        sh returnStatus: false, script: """#!/usr/bin/env bash
set -euo pipefail
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
python -m pip install --quiet --upgrade pip --index-url '${indexUrl}' --trusted-host '${trustedHost}'
if [ -f requirements.txt ]; then
  pip install --quiet -r requirements.txt --index-url '${indexUrl}' --trusted-host '${trustedHost}'
fi
if [ -f pyproject.toml ] || [ -f setup.py ]; then
  pip install --quiet --no-deps . --index-url '${indexUrl}' --trusted-host '${trustedHost}'
fi
python -c 'import sys; print("python build OK:", sys.version.split()[0], "venv at .venv")'
"""
                        break

                    default:
                        log.warn(STAGE, "no build recipe for language '${language}' — treating as no-op build")
                }
            }
            log.info(STAGE, "build succeeded for '${svc.name}'")
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
    // Called INSIDE dir(svc.path) — lockfile checks are relative to the service dir.
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
