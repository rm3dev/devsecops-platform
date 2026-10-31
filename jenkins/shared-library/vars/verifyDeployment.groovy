import groovy.json.JsonOutput
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig
import org.company.devsecops.GitOpsRepo
import org.company.devsecops.KubeAccess

/**
 * verifyDeployment — in-cluster ground truth AFTER ArgoCD reports healthy
 * (Phase 9). deployApplication trusts the ArgoCD API; this step trusts only
 * the cluster itself, through the READ-ONLY verifier kubeconfig (no mutation
 * possible even with a fully compromised pipeline — D-32):
 *
 *   1. workload convergence   Deployment: kubectl rollout status
 *                             Rollout:    poll .status.phase → Healthy
 *                             (Degraded fails fast; Paused at timeout fails
 *                              unless verify.acceptPaused — bounded pauses!)
 *   2. replica truth          readyReplicas == spec.replicas
 *   3. IDENTITY check         every running pod image == the digest this build
 *                             pushed (IMAGE_DIGEST_<slug>) — deployed == signed;
 *                             without a build digest, at minimum @sha256 format
 *   4. pathology scan         CrashLoopBackOff/ImagePullBackOff/Error/
 *                             CreateContainerConfigError/FailedMount → FAIL
 *   5. warning events         recent app events listed (context, not verdict)
 *   6. ExternalSecrets        all in-namespace ESO secrets Ready (if any)
 *
 * On failure with gitops.autoRollback enabled: rollbackDeployment re-pins the
 * PREVIOUS digest (git-history based) and waits — then this step still fails
 * the build (rollback restores the service; it does not forgive the change).
 *
 * params: service (svc map), env (default GITOPS_ENV_<slug> / config default),
 *         autoRollback (default from config gitops.autoRollback)
 * outputs: env.VERIFY_RESULT_<slug>, reports/verify-<slug>.json
 */
def call(Map params = [:]) {
    def svc = params.service ?: error('verifyDeployment: "service" map is required')
    def log = new PipelineLogger(this, svc.name as String)
    final String STAGE = 'Verify'

    def cfg = PlatformConfig.load(this, [servicePath: (svc.path ?: '.') as String])
    String slug = GitOpsRepo.slugify(svc.name as String)
    String targetEnv = (params.env ?: env["GITOPS_ENV_${slug}"] ?: cfg.get('gitops.defaultEnvironment', 'dev')) as String
    String ns = "${slug}-${targetEnv}"
    int timeoutSec = (cfg.get('verify.timeoutSec', 300) as Number).intValue()
    boolean acceptPaused = cfg.get('verify.acceptPaused', false) as boolean
    boolean autoRollback = (params.autoRollback != null) ? (params.autoRollback as boolean) :
            (cfg.get('gitops.autoRollback', true) as boolean)

    List problems = []
    List warnings = []
    String workloadKind = 'unknown'
    String detail = ''

    KubeAccess.withKubeconfig(this) { String kc ->
        // --- 0. namespace must exist (ArgoCD CreateNamespace=true) -------------
        def r = KubeAccess.run(this, kc, "get namespace '${ns}' --request-timeout=10s")
        if (r[0] != 0) {
            error("${STAGE}: namespace '${ns}' not found — did deployApplication succeed? (${r[1].take(200)})")
        }

        // --- 1. workload kind detection: Rollout (progressive) vs Deployment ---
        r = KubeAccess.run(this, kc, "get rollouts.argoproj.io '${slug}' -n '${ns}' --request-timeout=10s -o name")
        if (r[0] == 0) {
            workloadKind = 'Rollout'
        } else {
            r = KubeAccess.run(this, kc, "get deployment '${slug}' -n '${ns}' --request-timeout=10s -o name")
            if (r[0] != 0) {
                error("${STAGE}: neither Rollout nor Deployment '${slug}' exists in '${ns}' — GitOps app may not have synced")
            }
            workloadKind = 'Deployment'
        }
        log.info(STAGE, "workload ${workloadKind}/${slug} in ${ns} — waiting up to ${timeoutSec}s for convergence")

        // --- 1a. convergence wait ---------------------------------------------
        long deadline = System.currentTimeMillis() + timeoutSec * 1000L
        boolean converged = false
        String phase = ''
        while (System.currentTimeMillis() < deadline) {
            if (workloadKind == 'Deployment') {
                r = KubeAccess.run(this, kc, "rollout status deployment/'${slug}' -n '${ns}' --timeout=15s")
                converged = (r[0] == 0)
                detail = r[1]
                if (converged) { break }
            } else {
                r = KubeAccess.run(this, kc, "get rollouts.argoproj.io '${slug}' -n '${ns}' -o jsonpath='{.status.phase}'")
                phase = (r[0] == 0) ? r[1].trim() : ''
                detail = "phase=${phase}"
                if (phase == 'Healthy') { converged = true; break }
                if (phase == 'Degraded') {
                    r = KubeAccess.run(this, kc, "get rollouts.argoproj.io '${slug}' -n '${ns}' -o jsonpath='{.status.message}'")
                    problems << "Rollout phase=Degraded: ${(r[1] ?: 'no message').take(300)}"
                    break
                }
                // Paused/Progressing: canary steps advancing — keep polling
            }
            sleep(time: 10, unit: 'SECONDS')
        }
        if (!converged) {
            if (workloadKind == 'Rollout' && phase == 'Paused' && acceptPaused) {
                warnings << "Rollout still Paused at timeout (verify.acceptPaused=true — treated as OK; a human/analysis must promote)"
            } else if (problems.isEmpty()) {
                problems << "${workloadKind} '${slug}' did not converge within ${timeoutSec}s (${detail})"
            }
        } else {
            log.info(STAGE, "${workloadKind} converged (${detail.take(120)})")
        }

        // --- 2. replica truth ---------------------------------------------------
        String rpPath = (workloadKind == 'Rollout') ? 'rollouts.argoproj.io' : 'deployment'
        r = KubeAccess.run(this, kc, "get ${rpPath} '${slug}' -n '${ns}' -o jsonpath='{.spec.replicas} {.status.readyReplicas}'")
        if (r[0] == 0) {
            def parts = r[1].trim().split(/\s+/)
            String desired = parts[0]
            String ready = parts.length > 1 ? parts[1] : '0'
            if (desired != ready) {
                problems << "replicas not ready: desired=${desired} ready=${ready}"
            } else {
                log.info(STAGE, "replicas ready: ${ready}/${desired}")
            }
        } else {
            warnings << "could not read replica counts: ${r[1].take(120)}"
        }

        // --- 3. pod identity: deployed images == built/signed digest ------------
        r = KubeAccess.run(this, kc, "get pods -n '${ns}' -l app='${slug}' -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{end}'")
        List images = (r[0] == 0) ? r[1].readLines().findAll { it.trim() } : []
        if (images.isEmpty()) {
            problems << "no pods found for label app=${slug} in ${ns}"
        } else {
            String expectedDigest = env["IMAGE_DIGEST_${slug}"]
            images.unique().each { String img ->
                if (expectedDigest && !img.endsWith("@${expectedDigest}")) {
                    problems << "pod image ${img} != this build's signed digest ${expectedDigest} — deployed artifact is NOT the verified one"
                } else if (!img.contains('@sha256:')) {
                    problems << "pod image ${img} is not digest-pinned (Kyverno require-digest-pinning should have blocked this)"
                }
            }
            if (problems.isEmpty()) {
                log.info(STAGE, "identity OK: ${images.unique().size()} unique image ref(s), all ${expectedDigest ? '== build digest ' + expectedDigest.take(19) + '…' : 'digest-pinned'}")
            }
        }

        // --- 4. pathology scan ----------------------------------------------------
        r = KubeAccess.run(this, kc, "get pods -n '${ns}' -l app='${slug}' -o json")
        if (r[0] == 0) {
            def fatalReasons = ['CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull', 'CreateContainerConfigError',
                                'InvalidImageName', 'FailedMount', 'RunContainerError', 'Error'] as Set
            try {
                def pods = readJSON(text: r[1])
                pods.items.each { p ->
                    (p.status?.containerStatuses ?: []).each { cs ->
                        String reason = cs.state?.waiting?.reason ?: cs.state?.terminated?.reason ?: ''
                        if (reason && fatalReasons.contains(reason)) {
                            problems << "pod ${p.metadata.name}: container ${cs.name} in ${reason}"
                        }
                    }
                }
            } catch (Exception ignore) {
                warnings << 'pod JSON parse failed — pathology scan skipped'
            }
        }

        // --- 5. recent warning events (context for humans) -------------------------
        r = KubeAccess.run(this, kc, "get events -n '${ns}' --field-selector type=Warning -o jsonpath='{range .items[-10:]}{.reason}: {.message}{\"\\n\"}{end}'")
        if (r[0] == 0 && r[1].trim()) {
            r[1].trim().readLines().each { warnings << "event | ${it.take(200)}" }
        }

        // --- 6. ExternalSecrets readiness (ESO → Vault chain) ----------------------
        r = KubeAccess.run(this, kc, "get externalsecret.external-secrets.io -n '${ns}' -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}'")
        if (r[0] == 0 && r[1].trim()) {
            r[1].trim().readLines().each { String line ->
                def kv = line.split('=', 2)
                if (kv.length == 2 && kv[1].trim() != 'True') {
                    problems << "ExternalSecret ${kv[0].trim()} not Ready (Vault sync failing — check ClusterSecretStore + vault/scripts/30-k8s-auth.sh)"
                } else {
                    log.info(STAGE, "ExternalSecret ${kv[0].trim()} Ready")
                }
            }
        } else if (r[0] != 0) {
            warnings << 'ExternalSecret CRD not readable (ESO not installed?) — skipped'
        }
    }

    // --- verdict -------------------------------------------------------------------
    String result = problems.isEmpty() ? 'HEALTHY' : 'FAILED'
    env["VERIFY_RESULT_${slug}"] = result
    String report = JsonOutput.prettyPrint(JsonOutput.toJson([
            service    : svc.name,
            environment: targetEnv,
            namespace  : ns,
            workload   : workloadKind,
            result     : result,
            problems   : problems,
            warnings   : warnings,
    ]))
    writeFile file: "reports/verify-${slug}.json", text: report + '\n'
    warnings.each { log.warn(STAGE, it as String) }

    if (!problems.isEmpty()) {
        problems.each { log.error(STAGE, it as String) }
        if (autoRollback) {
            log.warn(STAGE, "gitops.autoRollback=true → re-pinning the previous digest for ${slug}@${targetEnv}")
            try {
                rollbackDeployment(service: svc, env: targetEnv,
                        reason: "verify failed: ${problems[0].toString().take(120)}")
            } catch (Exception re) {
                log.error(STAGE, "AUTOMATIC ROLLBACK FAILED: ${re.message} — manual intervention required NOW")
            }
        } else {
            log.warn(STAGE, "autoRollback disabled — service left in failed state (rollback manually: platform/gitops-promotion with an explicit DIGEST)")
        }
        // Phase 10: push the failure to notification channels immediately (the
        // generic build_failed event fires later in post{}; on-call wants the
        // deployment-specific one NOW, with the environment attached)
        notifyResult(serviceName: svc.name as String, event: 'deployment_failed',
                environment: targetEnv, failureStage: STAGE)
        error("${STAGE}: ${problems.size()} problem(s) for ${slug}@${targetEnv} — see reports/verify-${slug}.json")
    }
    log.info(STAGE, "${slug}@${targetEnv} verified HEALTHY (${workloadKind}; warnings: ${warnings.size()})")
}
