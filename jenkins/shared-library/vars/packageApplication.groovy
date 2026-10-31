import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * packageApplication — produce the distributable artifact per language
 * (Phase 6). Records what was produced in reports/package-<slug>.json so
 * publishArtifact (and Phase 7 SBOM generation) consume a stable manifest.
 *
 *   java/maven  → mvn package (jar/war in target/)
 *   java/gradle → gradle assemble (build/libs/)
 *   dotnet      → dotnet publish -o publish/ (+ dotnet pack → artifacts/ when packable)
 *   python      → poetry build OR pip wheel → dist/
 *   nodejs      → npm pack → *.tgz
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('packageApplication: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Package'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    def repos = (cfg.get('nexus.repositories', [:]) ?: [:]) as Map
    String language  = svc.language as String
    String buildTool = (svc.buildTool ?: '') as String
    List<String> artifacts = []

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
                            sh "${gw} --no-daemon --init-script ${init} assemble"
                            artifacts = findFiles(glob: 'build/libs/*.jar').collect { it.path as String }
                                .findAll { !(it.endsWith('-sources.jar') || it.endsWith('-javadoc.jar')) }
                        } else {
                            String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
                            String mvn = fileExists('./mvnw') ? './mvnw' : 'mvn'
                            sh "${mvn} -B -e -s ${settings} -DskipTests package"
                            artifacts = findFiles(glob: 'target/*.jar').collect { it.path as String } +
                                        findFiles(glob: 'target/*.war').collect { it.path as String }
                            artifacts = artifacts.findAll {
                                !(it.contains('.original') || it.endsWith('-sources.jar') || it.endsWith('-javadoc.jar'))
                            }
                        }
                        break

                    case 'dotnet':
                        String target = findFirst(['*.sln', '*.csproj'])
                        sh "dotnet publish '${target}' -c Release -o publish/"
                        artifacts = ['publish/']
                        // Library projects (packable) also produce a nupkg for nuget-hosted
                        int packRc = sh(returnStatus: true, script:
                            "grep -q '<IsPackable>true</IsPackable>' \$(find . -maxdepth 2 -name '*.csproj') 2>/dev/null")
                        if (packRc == 0) {
                            sh "dotnet pack '${target}' -c Release --no-build -o artifacts/"
                            artifacts += findFiles(glob: 'artifacts/*.nupkg').collect { it.path as String }
                        }
                        break

                    case 'python':
                        if (fileExists('poetry.lock') && fileExists('pyproject.toml')) {
                            sh 'poetry build --no-interaction'
                        } else {
                            String indexUrl = RepoConfig.pythonIndexShell(nexusBase, repos)
                            String trustedHost = RepoConfig.hostOf(nexusBase)
                            sh """#!/usr/bin/env bash
set -euo pipefail
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install --quiet --index-url '${indexUrl}' --trusted-host '${trustedHost}' build
python -m build --wheel --outdir dist/ .
"""
                        }
                        artifacts = findFiles(glob: 'dist/*.whl').collect { it.path as String } +
                                    findFiles(glob: 'dist/*.tar.gz').collect { it.path as String }
                        break

                    case 'nodejs':
                        String npmrc = RepoConfig.npmrc(this, nexusBase, repos, NEXUS_USER, NEXUS_PASS)
                        String pm = resolveNodePackageManager(svc)
                        withEnv(["NPM_CONFIG_USERCONFIG=${npmrc}",
                                 "NPM_CONFIG_REGISTRY=${nexusBase}/repository/${repos.npmPublic ?: 'npm-public'}/"]) {
                            sh 'npm pack --pack-destination .'
                        }
                        artifacts = findFiles(glob: '*.tgz').collect { it.path as String }
                        log.info(STAGE, "npm pack produced: ${artifacts.join(', ')} (pm=${pm})")
                        break

                    default:
                        log.stageSkipped('package', "no packaging recipe for language '${language}'")
                        return
                }
            }

            if (artifacts.isEmpty()) {
                log.warn(STAGE, "packaging produced no artifacts for '${svc.name}' — publish will skip")
            } else {
                log.info(STAGE, "packaged ${artifacts.size()} artifact(s): ${artifacts.join(', ')}")
            }
            String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
            writeFile file: "${env.WORKSPACE}/reports/package-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                service  : svc.name,
                language : language,
                buildTool: buildTool,
                path     : svc.path,
                artifacts: artifacts
            ]))
            archiveArtifacts artifacts: 'reports/package-*.json', allowEmptyArchive: true, fingerprint: false
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
