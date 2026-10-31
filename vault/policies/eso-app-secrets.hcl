# =============================================================================
# eso-app-secrets — External Secrets Operator read policy (Phase 8).
#
# KV v2 at 'secret/'. ESO may read APPLICATION secrets only
# (secret/apps/<service>/<name>); platform credentials (secret/platform/…)
# and identity paths stay out of reach. Least privilege for the
# 'eso-reader' role bound to SA external-secrets:eso-vault-auth.
# =============================================================================

# KV v2: data path reads
path "secret/data/apps/*" {
  capabilities = ["read"]
}

# KV v2: metadata (ESO lists/inspects during sync + resync reconciliation)
path "secret/metadata/apps/*" {
  capabilities = ["read", "list"]
}
