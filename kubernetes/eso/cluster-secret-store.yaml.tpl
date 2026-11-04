# TEMPLATED — applied by kubernetes/eso/install-eso.sh (envsubst for
# ${PLATFORM_DOMAIN}/${K8S_CLUSTER_NAME}; caBundle set from the platform CA in
# internal-ca mode, removed for letsencrypt). Do not apply directly.
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-cluster-store
  labels:
    app.kubernetes.io/part-of: devsecops-platform
spec:
  provider:
    vault:
      server: https://vault.${PLATFORM_DOMAIN}
      path: secret            # KV v2 mount created by vault/scripts/30-k8s-auth.sh
      version: v2
      auth:
        kubernetes:
          mountPath: kubernetes-${K8S_CLUSTER_NAME}   # one auth mount per cluster (multi-cluster)
          role: eso-reader
          serviceAccountRef:
            name: eso-vault-auth
            namespace: external-secrets
      caBundle: ""
