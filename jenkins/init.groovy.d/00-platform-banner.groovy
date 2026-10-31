// =============================================================================
// Runs at controller startup — operational banner + config-drift warning.
// =============================================================================
import jenkins.model.Jenkins

println '''
========================================================================
 DevSecOps Platform — Jenkins LTS Controller
 Configuration: JCasC (CASC_JENKINS_CONFIG=/var/jenkins_home/casc)
 Builds: warm pool [general python security] + dynamic Docker agents
 Policy: controller executes NO builds; no Docker socket is mounted here.
========================================================================
'''

def executors = Jenkins.get().numExecutors
if (executors > 0) {
    println "[WARN] Controller numExecutors=${executors} — expected 0 (JCasC 00-jenkins.yaml)."
}
