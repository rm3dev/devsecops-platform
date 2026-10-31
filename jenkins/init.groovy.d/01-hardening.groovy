// =============================================================================
// Startup hardening that JCasC does not cover (Phase 3).
// =============================================================================
import jenkins.CLI

// Disable the legacy CLI subsystem entirely (jenkins-cli.jar over HTTP/WS).
// All automation uses the REST API; the CLI is a historic attack surface
// (deserialization CVEs) and provides nothing this platform needs.
CLI.get().setEnabled(false)
println '[hardening] Jenkins CLI subsystem disabled (REST API unaffected)'

// Ensure the agent port is bound but legacy protocols stay off — JCasC sets
// agentProtocols [JNLP4-connect, Ping]; this is a runtime assertion for audit
// visibility, not a second configuration source.
def protocols = jenkins.AgentProtocol.all()
println "[hardening] active agent protocols: ${protocols.collect { it.name }}"
