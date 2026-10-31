package org.company.devsecops

/**
 * KubeAccess — ephemeral read-only kubeconfig lifecycle for verifyDeployment /
 * runPostDeploy (Phase 9).
 *
 * The kubeconfig arrives base64'd through env.K8S_VERIFY_KUBECONFIG (JCasC
 * string credential 'k8s-verify-kubeconfig' ← secrets/k8s.env, provisioned by
 * kubernetes/scripts/20-verify-kubeconfig.sh). It embeds a long-lived SA token
 * with get/list/watch ONLY (+ pods/portforward create for smoke-test tunneling,
 * + argoproj.io rollouts read) — a leaked file cannot mutate the cluster.
 *
 * Invariants:
 *   * fail-closed on placeholder/missing env with the exact host-side fix
 *   * file is chmod 600, workspace-private, removed in finally
 *   * callers receive the path and use `kubectl --kubeconfig <path>`
 */
class KubeAccess implements Serializable {

    private static final long serialVersionUID = 1L

    static void withKubeconfig(script, Closure body) {
        String b64 = script.env.K8S_VERIFY_KUBECONFIG
        if (!b64 || b64.trim().isEmpty() || b64.trim() == 'SET_IN_PHASE_8') {
            script.error("KubeAccess: K8S_VERIFY_KUBECONFIG is missing/placeholder on this agent. On the host run: " +
                    "./kubernetes/scripts/20-verify-kubeconfig.sh && docker compose -f docker-compose.yml --profile agents up -d agent-general")
        }
        String path = "${script.env.WORKSPACE}/.kube-verify-${System.currentTimeMillis()}"
        script.writeFile file: path, text: new String(b64.trim().decodeBase64())
        script.sh "chmod 600 '${path}'"
        try {
            body(path)
        } finally {
            script.sh "rm -f '${path}' || true"
        }
    }

    /** kubectl wrapper: returns [rc, combined-output] without failing the step.
     *  rc is smuggled through a tail marker because sh(returnStdout) discards
     *  captured output when the command exits non-zero. */
    static List run(script, String kubeconfig, String args) {
        String raw = script.sh(returnStdout: true, script:
                "kubectl --kubeconfig '${kubeconfig}' ${args} 2>&1; echo \"__RC__\$?\"")
        raw = (raw ?: '').trim()
        int idx = raw.lastIndexOf('__RC__')
        int rc = idx >= 0 ? (raw.substring(idx + 6).trim().toInteger()) : 1
        String out = idx >= 0 ? raw.substring(0, idx).trim() : raw
        return [rc, out]
    }
}
