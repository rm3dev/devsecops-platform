// =============================================================================
// Startup audit that JCasC does not cover (Phase 3).
//
// HISTORY (version drift, verified against core tag jenkins-2.568.3):
//   This script used to disable the legacy CLI subsystem via `jenkins.CLI`
//   (CLI.get().setEnabled(false)) — the historic jenkins-cli.jar-over-HTTP/WS
//   deserialization attack surface. That class AND the whole legacy CLI
//   subsystem were REMOVED from Jenkins core: there is nothing left to
//   disable, and the dead import failed Groovy compilation at every boot
//   (non-fatal WARNING). SSH-CLI is governed by the built-in sshd daemon,
//   which is disabled by default and not enabled by any JCasC file.
//   jenkins/CLI.java → 404 at tag; jenkins/AgentProtocol.java → present.
// =============================================================================

// Audit line: which inbound-agent protocols are actually active. JCasC no
// longer sets agentProtocols explicitly (key removed in current core — see
// 00-jenkins.yaml); core defaults apply (JNLP4-connect + Ping). Printed for
// audit visibility only — this is not a second configuration source.
def protocols = jenkins.AgentProtocol.all()
println "[hardening] active agent protocols: ${protocols.collect { it.name }}"
println "[hardening] legacy CLI subsystem: absent from core (nothing to disable)"
