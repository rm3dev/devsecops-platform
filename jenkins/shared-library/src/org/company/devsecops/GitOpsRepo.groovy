package org.company.devsecops

/**
 * GitOpsRepo — shared gitops-repository mechanics for updateGitOps /
 * promoteDigest (Phase 8, decision D-26 "render & commit").
 *
 * Design invariants:
 *   * The token NEVER appears in the remote URL, .git/config or logs: auth goes
 *     through a GIT_ASKPASS helper script fed from the credential-bound env
 *     variable (Jenkins masks the value in all output).
 *   * Digest pinning happens in the environment overlay's `images:` transformer
 *     via yq (the pinned yq v4 on agent-general) — the single mechanism both
 *     CI pushes and promotions use, so git diffs show exactly one changed line.
 *   * Pushes rebase-retry (3×): monorepo fan-out and concurrent services can
 *     race on main; commits are per-service files, so rebases are trivial.
 *
 * Callers MUST wrap withClone in:
 *   withCredentials([string(credentialsId: 'gitops-commit-token', variable: 'GITOPS_TOKEN')])
 */
class GitOpsRepo implements Serializable {

    private static final long serialVersionUID = 1L

    static String slugify(String name) {
        return (name ?: '').replaceAll('[^A-Za-z0-9._-]', '_')
    }

    /** Team folder = second segment of the job full name (teams/<team>/<repo>/<branch>)
     *  — same derivation as buildContainer (D-23), so image paths and gitops
     *  app paths can never disagree. */
    static String teamFromJob(script) {
        String jobName = (script.env.JOB_NAME ?: '') as String
        String[] parts = jobName.split('/')
        return (parts.length >= 2 && parts[0] == 'teams') ? parts[1] : 'platform'
    }

    /** Jenkins-side clone URL: GitLab service DNS on the agents-network (no TLS
     *  needed inside the platform boundary; ArgoCD's cluster-side URL is the
     *  public https one — see gitops-repository/clusters/*). */
    static String repoUrl(script, cfg) {
        return (cfg.get('gitops.repoUrlInternal', 'http://gitlab/platform/gitops-repository.git')) as String
    }

    static boolean isDigest(String d) {
        return (d ?: '') ==~ /^sha256:[0-9a-f]{64}$/
    }

    /**
     * Clone the gitops repository and run body(dir) inside the workspace.
     * Clone dir and askpass helper are ALWAYS removed (finally).
     */
    static void withClone(script, Map o, Closure body) {
        String url     = o.url as String
        String branch  = (o.branch ?: 'main') as String
        String dir     = (o.dir ?: '.gitops-repo') as String
        String user    = (o.username ?: 'jenkins-ci') as String
        String askpass = "${script.env.WORKSPACE}/${dir}-askpass.sh"

        script.writeFile file: askpass, text: '''#!/bin/sh
case "$1" in
  *sername*) printf '%s' "$GITOPS_GIT_USER" ;;
  *assword*) printf '%s' "$GITOPS_TOKEN" ;;
esac
'''
        script.sh "chmod +x '${askpass}'"
        try {
            script.withEnv(["GITOPS_GIT_USER=${user}", "GITOPS_ASKPASS=${askpass}"]) {
                script.dir(script.env.WORKSPACE) {
                    script.sh "rm -rf '${dir}'"
                    script.sh "GIT_ASKPASS=\"\${GITOPS_ASKPASS}\" git clone --quiet --depth 20 --branch '${branch}' '${url}' '${dir}'"
                    body(dir)
                }
            }
        } finally {
            script.sh "rm -rf '${script.env.WORKSPACE}/${dir}' '${askpass}' || true"
        }
    }

    /**
     * Pin `digest` for `imageName` in an overlay kustomization.yaml (images:
     * transformer). Fails loudly when the image entry is missing — a pin that
     * silently matched nothing would deploy the previous digest.
     */
    static void pinDigest(script, String overlayPath, String imageName, String digest) {
        if (!isDigest(digest)) {
            script.error("GitOpsRepo.pinDigest: invalid digest '${digest}' (expected sha256:<64 hex>)")
        }
        script.withEnv(["PIN_NAME=${imageName}", "PIN_DIGEST=${digest}", "PIN_FILE=${overlayPath}"]) {
            script.sh '''#!/usr/bin/env bash
set -euo pipefail
yq -i '(.images[] | select(.name == strenv(PIN_NAME))).digest = strenv(PIN_DIGEST)' "$PIN_FILE"
GOT="$(yq '.images[] | select(.name == strenv(PIN_NAME)) | .digest' "$PIN_FILE")"
if [ "$GOT" != "$PIN_DIGEST" ]; then
  echo "digest pin FAILED for '$PIN_NAME' in $PIN_FILE (images[] entry missing? got: '$GOT')" >&2
  exit 1
fi
'''
        }
    }

    /** Read the currently pinned digest from an overlay (promotion source).
     *  Rejects the all-zeros seed placeholder — promoting it would deploy nothing. */
    static String readDigest(script, String overlayPath) {
        String d = script.sh(returnStdout: true,
                script: "yq '.images[0].digest // \"\"' '${overlayPath}'").trim()
        if (!isDigest(d)) {
            script.error("GitOpsRepo.readDigest: ${overlayPath} carries no valid digest ('${d}')")
        }
        if (d == "sha256:${'0' * 64}") {
            script.error("GitOpsRepo.readDigest: ${overlayPath} still holds the seed placeholder digest — no build has deployed here yet")
        }
        return d
    }

    /** Read images[0].name from an overlay (promotion pins the SAME image entry). */
    static String readImageName(script, String overlayPath) {
        return script.sh(returnStdout: true,
                script: "yq '.images[0].name // \"\"' '${overlayPath}'").trim()
    }

    /**
     * Commit everything + push with rebase-retry. Returns the pushed commit
     * sha, or '' when the tree was already identical (idempotent re-runs).
     * MUST be called inside withClone (uses GITOPS_ASKPASS).
     */
    static String commitAndPush(script, String dir, String message) {
        String out = script.dir(dir) {
            script.sh(returnStdout: true, script: """#!/usr/bin/env bash
set -euo pipefail
git config user.name  'jenkins-ci (DevSecOps platform)'
git config user.email 'jenkins-ci@devsecops.local'
git add -A
if git diff --cached --quiet; then
  echo '__NO_CHANGE__'
  exit 0
fi
git commit --quiet -m '${message}'
for attempt in 1 2 3; do
  if GIT_ASKPASS="\${GITOPS_ASKPASS}" git push --quiet origin HEAD; then
    git rev-parse HEAD
    exit 0
  fi
  echo "push rejected (concurrent gitops update?) — rebase retry \${attempt}/3" >&2
  GIT_ASKPASS="\${GITOPS_ASKPASS}" git pull --rebase --quiet origin main || { git rebase --abort || true; exit 1; }
  sleep 2
done
echo 'push failed after 3 rebase attempts' >&2
exit 1
""")
        }
        out = (out ?: '').trim()
        if (out.contains('__NO_CHANGE__')) { return '' }
        def m = (out =~ /(?m)^([0-9a-f]{40})$/)
        return m.find() ? m.group(1) : out.readLines().last()
    }
}
