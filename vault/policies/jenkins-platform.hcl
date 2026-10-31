# =============================================================================
# jenkins-platform — AppRole policy for the Jenkins controller (Phase 11, D-36).
#
# Least privilege: Jenkins may read PLATFORM operational secrets only —
#   secret/platform/notifications  (Slack/Teams webhooks, SMTP, mailboxes)
#   secret/platform/cosign         (image-signing key + passphrase, D-25)
# Application secrets (secret/apps/*) belong to the cluster side and are
# reachable ONLY through the eso-app-secrets policy (Phase 8) — Jenkins never
# reads them; it deploys references, not values.
#
# Bound to auth/approle/role/jenkins-platform: token_ttl=1h, token_max_ttl=4h
# (vault/scripts/50-jenkins-approle.sh). NO write, NO sudo, NO sys/ paths
# except what token renewal requires implicitly (auth/token/renew-self is
# allowed for all tokens by the default policy).
# =============================================================================

# KV v2 data reads
path "secret/data/platform/notifications" {
  capabilities = ["read"]
}

path "secret/data/platform/cosign" {
  capabilities = ["read"]
}

# KV v2 metadata (needed by `vault kv get` clients to resolve versions)
path "secret/metadata/platform/notifications" {
  capabilities = ["read", "list"]
}

path "secret/metadata/platform/cosign" {
  capabilities = ["read", "list"]
}
