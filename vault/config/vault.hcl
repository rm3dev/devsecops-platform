# =============================================================================
# HashiCorp Vault configuration (Phase 2) — NEVER dev-mode (architecture D-09)
#
# Single-node integrated storage (raft). TLS terminates at Traefik; the
# listener is plain HTTP confined to internal Docker networks.
#
# Initialization (run once after first start — bootstrap.sh prints this):
#   docker compose exec vault vault operator init -key-shares=5 -key-threshold=3
# Store the 5 unseal keys + initial root token OFF-HOST (sealed envelopes),
# then immediately: enable audit, create the Jenkins AppRole + policies
# (Phase 11 deliverables in vault/policies/), rotate away the root token.
# =============================================================================

ui = true

disable_mlock = true          # mlock requires IPC_LOCK; cap is granted in compose,
                              # but mlock disabled avoids swap-related startup
                              # failures on container hosts (swap is off anyway,
                              # vm.swappiness=1 — architecture §7.3)

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_disable   = "1"         # TLS is terminated by Traefik (architecture §4.3)
  cluster_address = "0.0.0.0:8201"

  telemetry {
    unauthenticated_metrics_access = "true"   # Prometheus scrapes /v1/sys/metrics
  }
}

storage "raft" {
  path = "/vault/file"
}

api_addr     = "http://vault:8200"
cluster_addr = "http://vault:8201"
cluster_name = "devsecops-vault"

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}

# Audit device is enabled AFTER init (requires an unsealed server):
#   vault audit enable file file_path=/vault/file/audit.log   (Phase 11 also
#   forwards it to Loki via Alloy file tail)
