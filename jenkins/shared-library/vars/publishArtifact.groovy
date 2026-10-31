import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.RepoConfig

/**
 * publishArtifact — deploy language artifacts to Nexus HOSTED repositories
 * (Phase 6). Consumes the manifest written by packageApplication.
 *
 * Publication policy (master spec: no junk in release repos):
 *   • release publish  → only on 'main'/'master', 'rel-*' branches or tags
 *   • maven/gradle     → SNAPSHOT versions may publish from ANY branch
 *                        (into maven-snapshots only)
 *   • everything else on feature branches → explicit, logged skip
 *
 * Targets: maven-releases/maven-snapshots, npm-hosted, pypi-hosted,
 * nuget-hosted — the jenkins-deploy role grants add/edit on hosted repos only.
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('publishArtifact: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Publish'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String nexusBase = (cfg.get('nexus.baseUrl', 'http://nexus:8081')) as String
    def repos = (cfg.get('nexus.repositories', [:]) ?: [:]) as Map
    String language  = svc.language as String
    String buildTool = (svc.buildTool ?: '') as String

    String branch = (env.GIT_BRANCH_NAME ?: 'main') as String
    boolean isTag = (env.TAG_NAME ?: '') != ''
    boolean releaseContext = isTag || branch in ['main', 'master'] || branch.startsWith('rel-')

    if (!releaseContext && !(language == 'java')) {
        log.stageSkipped('publish', "branch '${branch}' is not a release context (main/master/rel-*/tag) — " +
            "artifacts stay in the build; images are still pushed for dev/qa by digest (D-23)")
        return
    }
    if (!releaseContext && language == 'java') {
        log.info(STAGE, "non-release branch '${branch}' — Java publishes only if the version is a SNAPSHOT")
    }

    String slug = (svc.name as String).replaceAll('[^A-Za-z0-9._-]', '_')
    Map result = [service: svc.name, language: language, branch: branch, published: [], skipped: []]

    withCredentials([usernamePassword(credentialsId: 'nexus-deploy',
                                      usernameVariable: 'NEXUS_USER',
                                      passwordVariable: 'NEXUS_PASS')]) {
        try {
            dir(svc.path as String) {
                switch (language) {

                    case 'java':
                        if (buildTool.contains('gradle')) { publishGradle(log, STAGE, nexusBase, repos, releaseContext, result) }
                        else { publishMaven(log, STAGE, nexusBase, repos, releaseContext, result) }
                        break

                    case 'dotnet':
                        def nupkgs = findFiles(glob: 'artifacts/*.nupkg')
                        if (!nupkgs || nupkgs.length == 0) {
                            log.stageSkipped('publish', 'no .nupkg produced (project is not a packable library) — deployment goes via image digest')
                            result.skipped << 'nuget (no nupkg)'
                            break
                        }
                        if (!releaseContext) { log.stageSkipped('publish', "nuget publish requires release context (branch '${branch}')"); break }
                        String hostedUrl = "${nexusBase.replaceFirst('^(https?://)', '$1$NEXUS_USER:$NEXUS_PASS@')}/repository/${repos.nugetHosted ?: 'nuget-hosted'}/index.json"
                        sh "dotnet nuget push 'artifacts/*.nupkg' --source '${hostedUrl}' --api-key nexus --skip-duplicate"
                        nupkgs.each { result.published << "nuget-hosted:${it.name}" }
                        break

                    case 'python':
                        if (!releaseContext) { break }   // guarded above, defensive
                        def wheels = findFiles(glob: 'dist/*')
                        if (!wheels || wheels.length == 0) {
                            error("${STAGE}: nothing in dist/ — enable the 'package' stage flag so packageApplication runs first")
                        }
                        String indexUrl = RepoConfig.pythonIndexShell(nexusBase, repos)
                        String trustedHost = RepoConfig.hostOf(nexusBase)
                        if (fileExists('poetry.lock') && fileExists('pyproject.toml')) {
                            String hosted = "${nexusBase}/repository/${repos.pypiHosted ?: 'pypi-hosted'}/"
                            sh "poetry config repositories.nexus '${hosted}' && poetry publish --no-interaction --repository nexus -u \"\$NEXUS_USER\" -p \"\$NEXUS_PASS\""
                        } else {
                            sh """#!/usr/bin/env bash
set -euo pipefail
[ -d .venv ] || python3 -m venv .venv
. .venv/bin/activate
pip install --quiet --index-url '${indexUrl}' --trusted-host '${trustedHost}' twine
TWINE_USERNAME="\$NEXUS_USER" TWINE_PASSWORD="\$NEXUS_PASS" \
  twine upload --non-interactive --disable-progress-bar \
  --repository-url '${nexusBase}/repository/${repos.pypiHosted ?: 'pypi-hosted'}/' dist/*
"""
                        }
                        wheels.each { result.published << "pypi-hosted:${it.name}" }
                        break

                    case 'nodejs':
                        if (!releaseContext) { break }
                        String npmrc = RepoConfig.npmrc(this, nexusBase, repos, NEXUS_USER, NEXUS_PASS)
                        withEnv(["NPM_CONFIG_USERCONFIG=${npmrc}"]) {
                            sh "npm publish --registry ${nexusBase}/repository/${repos.npmHosted ?: 'npm-hosted'}/"
                        }
                        String nameVer = sh(returnStdout: true, script:
                            "node -e \"const p=require('./package.json');console.log(p.name+'@'+p.version)\"").trim()
                        result.published << "npm-hosted:${nameVer}"
                        break

                    default:
                        log.stageSkipped('publish', "no publish recipe for language '${language}'")
                }
            }

            writeFile file: "${env.WORKSPACE}/reports/publish-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson(result))
            archiveArtifacts artifacts: 'reports/publish-*.json', allowEmptyArchive: true, fingerprint: false
            log.info(STAGE, "published=[${result.published.join(', ')}] skipped=[${result.skipped.join(', ')}]")
        } finally {
            RepoConfig.cleanup(this)
        }
    }
}

// ---------------------------------------------------------------------------
// java helpers
// ---------------------------------------------------------------------------

private void publishMaven(log, String STAGE, String nexusBase, Map repos, boolean releaseContext, Map result) {
    String settings = RepoConfig.mavenSettings(this, nexusBase, repos)
    String mvn = fileExists('./mvnw') ? './mvnw' : 'mvn'
    String version = sh(returnStdout: true, script:
        "${mvn} -B -q -s ${settings} help:evaluate -Dexpression=project.version -DforceStdout").trim()
    boolean isSnapshot = version.endsWith('-SNAPSHOT')
    if (!releaseContext && !isSnapshot) {
        log.stageSkipped('publish', "version ${version} is a release version on a feature branch — not published")
        result.skipped << "maven (${version} on non-release branch)"
        return
    }
    int rc = sh(returnStatus: true, script: "${mvn} -B -e -s ${settings} -DskipTests deploy")
    if (rc == 0) {
        result.published << "maven:${version} (project distributionManagement)"
        return
    }
    // Fallback for projects without distributionManagement: deploy-file the
    // packaged artifact straight into the matching Nexus hosted repo.
    log.warn(STAGE, 'mvn deploy failed — falling back to deploy:deploy-file into Nexus hosted repo')
    String repo = isSnapshot ? (repos.mavenSnapshots ?: 'maven-snapshots') : (repos.mavenReleases ?: 'maven-releases')
    String serverId = isSnapshot ? 'nexus-snapshots' : 'nexus-releases'
    sh """#!/usr/bin/env bash
set -euo pipefail
G=\$(${mvn} -B -q -s ${settings} help:evaluate -Dexpression=project.groupId -DforceStdout)
A=\$(${mvn} -B -q -s ${settings} help:evaluate -Dexpression=project.artifactId -DforceStdout)
P=\$(${mvn} -B -q -s ${settings} help:evaluate -Dexpression=project.packaging -DforceStdout)
if [ "\$P" = "pom" ]; then
  FILE=pom.xml
else
  FILE=\$(ls target/\$A-$version.\$P 2>/dev/null | head -1 || true)
  if [ -z "\$FILE" ]; then FILE=\$(ls target/*.jar target/*.war 2>/dev/null | grep -v -- '-sources\\|-javadoc\\|\\.original' | head -1 || true); fi
fi
[ -n "\$FILE" ] || { echo "no artifact found in target/ — run the 'package' stage first"; exit 1; }
${mvn} -B -e -s ${settings} deploy:deploy-file \\
  -DgroupId="\$G" -DartifactId="\$A" -Dversion="$version" -Dpackaging="\$P" \\
  -Dfile="\$FILE" -DpomFile=pom.xml \\
  -DrepositoryId=${serverId} -Durl=${nexusBase}/repository/${repo}/
"""
    result.published << "maven:${version} (deploy-file → ${repo})"
}

private void publishGradle(log, String STAGE, String nexusBase, Map repos, boolean releaseContext, Map result) {
    int hasPublish = sh(returnStatus: true, script:
        "grep -rq 'maven-publish' build.gradle build.gradle.kts settings.gradle settings.gradle.kts */build.gradle */build.gradle.kts 2>/dev/null")
    if (hasPublish != 0) {
        log.stageSkipped('publish', 'no maven-publish plugin configured — deployment goes via image digest')
        result.skipped << 'gradle (no maven-publish)'
        return
    }
    String init = RepoConfig.gradleInit(this, nexusBase, repos)
    String gw = fileExists('./gradlew') ? './gradlew' : 'gradle'
    // The init script injects the 'nexus' repository (snapshots vs releases by version).
    sh "${gw} --no-daemon --init-script ${init} publishAllPublicationsToNexusRepository -x test"
    result.published << 'gradle:maven-publish → nexus (repo chosen by version suffix)'
}
