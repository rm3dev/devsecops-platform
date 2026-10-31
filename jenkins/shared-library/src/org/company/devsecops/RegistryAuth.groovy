package org.company.devsecops

/**
 * RegistryAuth — ephemeral Docker config for registry.<domain> operations
 * (trivy image scans, syft SBOM, cosign sign). Must be called INSIDE
 * withCredentials([usernamePassword(credentialsId:'nexus-deploy',
 * usernameVariable:'NEXUS_USER', passwordVariable:'NEXUS_PASS')]).
 *
 * The config.json lives in a per-step directory under the workspace and MUST
 * be removed via cleanup() in a finally block (it contains registry auth).
 */
class RegistryAuth implements Serializable {

    private static final long serialVersionUID = 1L

    static String registryHost(script) {
        String domain = script.env.PLATFORM_DOMAIN
        if (!domain) { throw new IllegalStateException('PLATFORM_DOMAIN is not set in the controller environment') }
        return "registry.${domain}"
    }

    /** Writes ${WORKSPACE}/.docker-<suffix>/config.json; returns the dir (use as DOCKER_CONFIG). */
    static String writeDockerConfig(script, String suffix) {
        String registry = registryHost(script)
        String dir = "${script.env.WORKSPACE}/.docker-${suffix}"
        String auth = "${script.env.NEXUS_USER}:${script.env.NEXUS_PASS}"
                        .getBytes('UTF-8').encodeBase64().toString()
        script.writeFile file: "${dir}/config.json",
                         text: groovy.json.JsonOutput.toJson([auths: [(registry): [auth: auth]]])
        return dir
    }

    static void cleanup(script, String dir) {
        script.sh script: "rm -rf '${dir}'", returnStatus: true
    }

    /** trivy DB env lines: pull vulnerability DBs through the Nexus ghcr-proxy. */
    static String trivyDbEnv(script) {
        String registry = registryHost(script)
        return "export TRIVY_DB_REPOSITORY='${registry}/aquasecurity/trivy-db'\n" +
               "export TRIVY_JAVA_DB_REPOSITORY='${registry}/aquasecurity/trivy-java-db'"
    }
}
