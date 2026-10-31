import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.GitOpsRepo
import org.company.devsecops.KubeAccess

/**
 * runPostDeploy — smoke tests against the LIVE deployment (Phase 9, D-31).
 *
 * Discovery convention (service repository, stashed source):
 *   tests/postman/*.postman_collection.json  → newman  (pinned on agent-general)
 *       optional sibling environment.json    → passed via --environment
 *   tests/k6/*.js                            → k6      (thresholds in the script
 *                                                        decide pass/fail)
 * Every test receives BASE_URL. Resolution order:
 *   1. params.baseUrl / env POSTDEPLOY_BASE_URL_<slug> / config postDeploy.baseUrl
 *   2. otherwise: kubectl port-forward svc/<slug> through the READ-ONLY
 *      verifier kubeconfig (pods/portforward create is its only "active" verb;
 *      local port derived from the slug hash so parallel services don't clash)
 *
 * No tests discovered → LOUD skip (report + warn), never a silent pass and
 * never a failure (D-19): teams add tests at their own pace.
 * Failure with gitops.autoRollback → rollbackDeployment, then the build fails.
 *
 * params: service (svc map), env, baseUrl, autoRollback
 * outputs: reports/postdeploy-<slug>.json (+ newman/k6 native reports)
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('runPostDeploy: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Post-Deploy'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String slug = GitOpsRepo.slugify(svc.name as String)
    String targetEnv = (params.env ?: env["GITOPS_ENV_${slug}"] ?: cfg.get('gitops.defaultEnvironment', 'dev')) as String
    String ns = "${slug}-${targetEnv}"
    int smokeTimeout = (cfg.get('postDeploy.smokeTimeoutSec', 600) as Number).intValue()
    boolean autoRollback = (params.autoRollback != null) ? (params.autoRollback as boolean) :
            (cfg.get('gitops.autoRollback', true) as boolean)

    // --- discover smoke tests in the stashed service source -------------------
    String srcPath = (svc.path ?: '.') as String
    List postman = sh(returnStdout: true, script:
            "find '${srcPath}' -type f -path '*tests/postman/*' -name '*.postman_collection.json' 2>/dev/null || true"
    ).trim().readLines().findAll { it.trim() }
    List k6 = sh(returnStdout: true, script:
            "find '${srcPath}' -type f -path '*tests/k6/*' -name '*.js' 2>/dev/null || true"
    ).trim().readLines().findAll { it.trim() }

    List results = []
    if (postman.isEmpty() && k6.isEmpty()) {
        log.warn(STAGE, "no smoke tests discovered (looked for ${srcPath}/tests/postman/*.postman_collection.json and ${srcPath}/tests/k6/*.js) — postDeploy passes trivially; ADD TESTS to enforce runtime behavior")
        writeFile file: "reports/postdeploy-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                service: svc.name, environment: targetEnv, result: 'SKIPPED-NO-TESTS',
                smoke: [], note: 'no newman collections or k6 scripts in tests/ conventions'])) + '\n'
        return
    }
    log.info(STAGE, "discovered ${postman.size()} newman collection(s), ${k6.size()} k6 script(s)")

    // closure: run everything against a resolved BASE_URL
    def runTests = { String baseUrl, String baseUrlSource ->
        timeout(time: smokeTimeout, unit: 'SECONDS') {
            postman.eachWithIndex { String coll, int i ->
                String envFile = "${coll.replaceFirst(/\.postman_collection\.json$/, '')}.env.json"
                String envFlag = fileExists(envFile) ? " --environment '${envFile}'" : ''
                int rc = sh(returnStatus: true, script:
                        "newman run '${coll}'${envFlag} --env-var \"BASE_URL=${baseUrl}\" " +
                        "--reporters cli,json --reporter-json-export 'reports/newman-${slug}-${i}.json' " +
                        "--color off --timeout-request 30000")
                results << [tool: 'newman', file: coll, rc: rc, result: rc == 0 ? 'PASS' : 'FAIL']
                log.info(STAGE, "newman ${coll.split('/').last()}: ${rc == 0 ? 'PASS' : 'FAIL (rc=' + rc + ')'}")
            }
            k6.eachWithIndex { String script_, int i ->
                int rc = sh(returnStatus: true, script:
                        "k6 run --quiet --env BASE_URL='${baseUrl}' --out json='reports/k6-${slug}-${i}.json' '${script_}'")
                String note = rc == 99 ? ' (thresholds breached)' : ''
                results << [tool: 'k6', file: script_, rc: rc, result: rc == 0 ? 'PASS' : 'FAIL']
                log.info(STAGE, "k6 ${script_.split('/').last()}: ${rc == 0 ? 'PASS' : 'FAIL (rc=' + rc + ')' + note}")
            }
        }
        String verdict = results.every { it.result == 'PASS' } ? 'PASS' : 'FAIL'
        writeFile file: "reports/postdeploy-${slug}.json", text: JsonOutput.prettyPrint(JsonOutput.toJson([
                service: svc.name, environment: targetEnv, namespace: ns,
                baseUrlSource: baseUrlSource, result: verdict, smoke: results])) + '\n'
        if (verdict != 'PASS') {
            int failed = results.count { it.result != 'PASS' }
            if (autoRollback) {
                log.warn(STAGE, "smoke tests failed (${failed}/${results.size()}) — gitops.autoRollback=true → rolling back ${slug}@${targetEnv}")
                try {
                    rollbackDeployment(service: svc, env: targetEnv,
                            reason: "postDeploy smoke failed: ${failed}/${results.size()} test(s)")
                } catch (Exception re) {
                    log.error(STAGE, "AUTOMATIC ROLLBACK FAILED: ${re.message} — manual intervention required NOW")
                }
            }
            // Phase 10: deployment-specific failure event (fail-safe dispatch)
            notifyResult(serviceName: svc.name as String, event: 'deployment_failed',
                    environment: targetEnv, failureStage: STAGE)
            error("${STAGE}: ${failed}/${results.size()} smoke test(s) failed for ${slug}@${targetEnv} — see reports/postdeploy-${slug}.json")
        }
        log.info(STAGE, "all ${results.size()} smoke test(s) passed against ${baseUrl}")
    }

    // --- resolve BASE_URL: explicit wins, else port-forward through the cluster
    String explicit = (params.baseUrl ?: env["POSTDEPLOY_BASE_URL_${slug}"] ?: cfg.get('postDeploy.baseUrl', '')) as String
    if (explicit?.trim()) {
        runTests(explicit.trim(), 'explicit')
        return
    }

    KubeAccess.withKubeconfig(this) { String kc ->
        def r = KubeAccess.run(this, kc, "get svc '${slug}' -n '${ns}' -o jsonpath='{.spec.ports[0].port}'")
        if (r[0] != 0 || !(r[1] ==~ /\d+/)) {
            error("${STAGE}: cannot resolve service port for svc/${slug} in ${ns} (${r[1].take(150)}) — set postDeploy.baseUrl or POSTDEPLOY_BASE_URL_${slug} for non-standard exposure")
        }
        String svcPort = r[1].trim()
        int portBase = (cfg.get('postDeploy.localPortBase', 18000) as Number).intValue()
        int localPort = portBase + (Math.abs(slug.hashCode()) % 2000)
        String pidFile = ".pf-${slug}.pid"
        try {
            sh "nohup kubectl --kubeconfig '${kc}' port-forward -n '${ns}' svc/'${slug}' ${localPort}:${svcPort} --address 127.0.0.1 > '.pf-${slug}.log' 2>&1 & echo \$! > '${pidFile}'"
            int waited = 0
            int up = sh(returnStatus: true, script: "timeout 2 bash -c '</dev/tcp/127.0.0.1/${localPort}' 2>/dev/null")
            while (up != 0 && waited < 30) {
                sleep(time: 2, unit: 'SECONDS'); waited += 2
                up = sh(returnStatus: true, script: "timeout 2 bash -c '</dev/tcp/127.0.0.1/${localPort}' 2>/dev/null")
            }
            if (up != 0) {
                String pfLog = sh(returnStdout: true, script: "cat '.pf-${slug}.log' 2>/dev/null || true").trim()
                error("${STAGE}: port-forward to svc/${slug} never came up: ${pfLog.take(300)}")
            }
            log.info(STAGE, "port-forward 127.0.0.1:${localPort} → svc/${slug}.${ns}:${svcPort} (read-only kubeconfig)")
            runTests("http://127.0.0.1:${localPort}", "port-forward svc/${slug}:${svcPort}")
        } finally {
            sh "if [ -f '${pidFile}' ]; then kill \$(cat '${pidFile}') 2>/dev/null || true; rm -f '${pidFile}' '.pf-${slug}.log'; fi"
        }
    }
}
