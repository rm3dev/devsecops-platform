#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-command platform bring-up (Phase 2)
#
#   ./scripts/bootstrap.sh                     # profile: core
#   ./scripts/bootstrap.sh --with-monitoring   # + monitoring profile
#   ./scripts/bootstrap.sh --with-build        # + buildkitd & socket-proxy
#   ./scripts/bootstrap.sh --with-agents       # + warm agent pool (general/python/security)
#   ./scripts/bootstrap.sh --with-backup       # + restic backup runner
#   ./scripts/bootstrap.sh --all               # profile: all
#   ./scripts/bootstrap.sh --prod              # base + docker-compose.prod.yml
#   ./scripts/bootstrap.sh --skip-build        # reuse existing custom images
#   ./scripts/bootstrap.sh --skip-sysctl       # non-root hosts / managed sysctls
#   ./scripts/bootstrap.sh --dry-run           # validate + render, do not start
#
# Idempotent: safe to re-run. Existing secrets/certificates are preserved.
# Steps: prerequisites → .env → kernel params → data dirs (correct uids) →
#        secrets → TLS material (internal CA) → Traefik dynamic config →
#        compose validate → pull → up → post-start instructions.
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

WITH_MONITORING=0; WITH_BUILD=0; WITH_BACKUP=0; WITH_AGENTS=0; USE_ALL=0; PROD=0
SKIP_SYSCTL=0; DRY_RUN=0; SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --with-monitoring) WITH_MONITORING=1 ;;
    --with-build)      WITH_BUILD=1 ;;
    --with-backup)     WITH_BACKUP=1 ;;
    --with-agents)     WITH_AGENTS=1 ;;
    --all)             USE_ALL=1 ;;
    --prod)            PROD=1 ;;
    --skip-sysctl)     SKIP_SYSCTL=1 ;;
    --skip-build)      SKIP_BUILD=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                 die "Unknown argument: $arg (try --help)" ;;
  esac
done

require_cmd docker openssl curl envsubst
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin missing"

# ---------------------------------------------------------------- 1. .env ----
if [[ ! -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  chmod 600 "$ROOT_DIR/.env"
  log_info "Created .env from .env.example — review PLATFORM_DOMAIN and DATA_ROOT, then re-run."
fi
load_env

# ------------------------------------------------------- 2. kernel params ----
SYSCTL_FILE=/etc/sysctl.d/99-devsecops.conf
if [[ $SKIP_SYSCTL -eq 0 ]]; then
  if [[ "$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)" -lt 524288 ]] || [[ ! -f "$SYSCTL_FILE" ]]; then
    log_info "Applying kernel parameters ($SYSCTL_FILE)"
    cat <<'EOF' | maybe_sudo tee "$SYSCTL_FILE" >/dev/null
# DevSecOps platform requirements (architecture.md §7.3)
vm.max_map_count = 524288
vm.swappiness = 1
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 4096
net.ipv4.ip_forward = 1
user.max_user_namespaces = 15000
EOF
    maybe_sudo sysctl --system >/dev/null
    log_ok "vm.max_map_count=$(sysctl -n vm.max_map_count)"
  else
    log_ok "Kernel parameters already applied"
  fi
else
  log_warn "--skip-sysctl: ensure vm.max_map_count>=524288 manually (SonarQube will crash-loop otherwise)"
fi

# ---------------------------------------------------------- 3. data dirs ----
log_info "Preparing data directories under $DATA_ROOT"
declare -A DIR_OWNERS=(
  ["gitlab/config"]="root:root"          ["gitlab/logs"]="root:root"
  ["gitlab/data"]="root:root"
  ["jenkins-home"]="1000:1000"           ["agent-workspaces"]="1000:1000"
  ["agent-workspaces/agent-general"]="1000:1000"
  ["agent-workspaces/agent-python"]="1000:1000"
  ["agent-workspaces/agent-security"]="1000:1000"
  ["sonarqube-db"]="999:999"
  ["sonarqube/data"]="1000:1000"         ["sonarqube/extensions"]="1000:1000"
  ["sonarqube/logs"]="1000:1000"
  ["nexus-data"]="200:200"
  ["vault/file"]="100:1000"
  ["prometheus-data"]="65534:65534"      ["alertmanager-data"]="65534:65534"
  ["loki-data"]="10001:10001"            ["alloy-data"]="10001:10001"
  ["grafana-data"]="472:472"
  ["buildkit-cache"]="1000:1000"
  ["security"]="1000:1000"               ["security/dependency-check"]="1000:1000"
  ["backups/staging"]="root:root"        ["backups/repo"]="root:root"
)
for rel in "${!DIR_OWNERS[@]}"; do
  maybe_sudo mkdir -p "$DATA_ROOT/$rel"
  maybe_sudo chown "${DIR_OWNERS[$rel]}" "$DATA_ROOT/$rel"
done
log_ok "Data directories ready"

# ------------------------------------------------------------- 4. secrets ----
SECRETS_DIR="$ROOT_DIR/secrets"
mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
# gen_secret() provided by scripts/lib/common.sh

SONAR_DB_PASSWORD="$( [[ -f "$SECRETS_DIR/sonar-db.env" ]] && grep -oP '(?<=^POSTGRES_PASSWORD=).*' "$SECRETS_DIR/sonar-db.env" || gen_secret )"

write_if_missing() { # file, content
  [[ -f "$1" ]] && { log_ok "secret exists: $(basename "$1")"; return; }
  printf '%s\n' "$2" > "$1"; chmod 600 "$1"; log_info "generated secret: $(basename "$1")"
}

write_if_missing "$SECRETS_DIR/sonar-db.env" "POSTGRES_USER=sonar
POSTGRES_DB=sonar
POSTGRES_PASSWORD=${SONAR_DB_PASSWORD}"
write_if_missing "$SECRETS_DIR/sonar.env" "SONAR_JDBC_USERNAME=sonar
SONAR_JDBC_PASSWORD=${SONAR_DB_PASSWORD}"
write_if_missing "$SECRETS_DIR/gitlab.env" "GITLAB_ROOT_PASSWORD=$(gen_secret)
GITLAB_ROOT_EMAIL=admin@${PLATFORM_DOMAIN}"
write_if_missing "$SECRETS_DIR/grafana.env" "GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=$(gen_secret)"
write_if_missing "$SECRETS_DIR/jenkins.env" "JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=$(gen_secret)
JENKINS_ADMIN_EMAIL=admin@${PLATFORM_DOMAIN}
JENKINS_PLATFORM_ADMIN_PASSWORD=$(gen_secret)
JENKINS_DEVOPS_ADMIN_PASSWORD=$(gen_secret)
JENKINS_DEVELOPER_PASSWORD=$(gen_secret)
JENKINS_SECURITY_ENGINEER_PASSWORD=$(gen_secret)
JENKINS_RELEASE_MANAGER_PASSWORD=$(gen_secret)
JENKINS_APP_OWNER_PASSWORD=$(gen_secret)"
write_if_missing "$SECRETS_DIR/restic_password" "$(openssl rand -hex 32)"
# Placeholders so the jenkins env_file contract exists from day one;
# gitlab/scripts/20-users-groups.sh replaces them with real PATs (Phase 4).
write_if_missing "$SECRETS_DIR/gitlab-jenkins.env" "GITLAB_JENKINS_USER=jenkins-ci
GITLAB_API_TOKEN=SET_IN_PHASE_4
GITOPS_REPO_TOKEN=SET_IN_PHASE_8
GITLAB_WEBHOOK_TOKEN=$(gen_secret)"
# Phase 5 placeholders — replaced with real values by sonarqube/scripts and
# nexus/scripts; the env_file contract for the jenkins service exists from day one.
write_if_missing "$SECRETS_DIR/sonar-jenkins.env" "SONARQUBE_TOKEN=SET_IN_PHASE_5
SONAR_WEBHOOK_TOKEN=$(gen_secret)"
write_if_missing "$SECRETS_DIR/nexus-jenkins.env" "NEXUS_DEPLOY_USER=jenkins-ci
NEXUS_DEPLOY_PASSWORD=SET_IN_PHASE_5"
# Phase 7 placeholder — security/scripts/10-cosign-keys.sh generates the real
# keypair (COSIGN_KEY = base64 of the private PEM) and replaces these values.
# Phase 11 migrates the key material into Vault with rotation.
write_if_missing "$SECRETS_DIR/cosign.env" "COSIGN_KEY=SET_IN_PHASE_7
COSIGN_PASSWORD=SET_IN_PHASE_7"
# Phase 8: rewritten with real values by kubernetes/argocd/install-argocd.sh
# (ARGOCD_SERVER_URL / ARGOCD_AUTH_TOKEN / ARGOCD_OPTS / ARGOCD_ADMIN_*)
write_if_missing "$SECRETS_DIR/argocd.env" "ARGOCD_SERVER_URL=SET_IN_PHASE_8
ARGOCD_AUTH_TOKEN=SET_IN_PHASE_8
ARGOCD_OPTS=--insecure"
# Phase 8: rewritten by kubernetes/scripts/20-verify-kubeconfig.sh
# (K8S_VERIFY_KUBECONFIG base64 — consumed by verifyDeployment, Phase 9)
write_if_missing "$SECRETS_DIR/k8s.env" "K8S_VERIFY_KUBECONFIG=SET_IN_PHASE_8"
# Phase 11: Vault AppRole env for the JCasC 'vault-approle' credential —
# placeholders are fail-closed; vault/scripts/50-jenkins-approle.sh writes real
# role-id/secret-id (then recreate jenkins).
write_if_missing "$SECRETS_DIR/vault-jenkins.env" "VAULT_APPROLE_ID=SET_IN_PHASE_11
VAULT_APPROLE_SECRET_ID=SET_IN_PHASE_11"
# Phase 10: jenkins notification env (JCasC creds slack/teams-webhook-url pick up
# SLACK_WEBHOOK_URL/TEAMS_WEBHOOK_URL; mailer picks up SMTP_*). Placeholders are
# fail-closed: NotificationService skips any "SET_IN_PHASE*" webhook with a warn.
# monitoring/scripts/20-configure-notifications.sh writes the real values.
write_if_missing "$SECRETS_DIR/jenkins-notifications.env" "SLACK_WEBHOOK_URL=SET_IN_PHASE_10
TEAMS_WEBHOOK_URL=SET_IN_PHASE_10
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=devsecops-platform@localhost"
# Phase 10: Alertmanager *_file secrets + Prometheus nexus password_file.
# RAW files (no KEY= prefix), NO trailing newline, chmod 600: Alertmanager and
# Prometheus validate/serve file contents verbatim at config load, so the files
# must exist from day one with parse-safe placeholder VALUES (URL-shaped, host-
# shaped) — delivery fails per-alert until 20-configure-notifications.sh runs.
mkdir -p "$SECRETS_DIR/alertmanager" "$SECRETS_DIR/prometheus"; chmod 700 "$SECRETS_DIR/alertmanager" "$SECRETS_DIR/prometheus"
write_raw_if_missing() { [[ -f "$1" ]] && { log_ok "secret exists: $(basename "$1")"; return; }; printf '%s' "$2" > "$1"; chmod 600 "$1"; log_info "generated secret: $(basename "$1")"; }
write_raw_if_missing "$SECRETS_DIR/alertmanager/slack_webhook_url" "https://hooks.slack.com/services/T00000000/B00000000/SET_IN_PHASE_10"
write_raw_if_missing "$SECRETS_DIR/alertmanager/teams_webhook_url" "https://example.webhook.office.com/webhookb2/SET/IN/PHASE10"
write_raw_if_missing "$SECRETS_DIR/alertmanager/smtp_password" "SET_IN_PHASE_10"
# generated NOW so nexus/scripts + the prometheus scrape agree on one password
# (10-enable-nexus-metrics.sh creates the 'metrics' user with exactly this value)
write_raw_if_missing "$SECRETS_DIR/prometheus/nexus_metrics_password" "$(gen_secret)"

# ------------------------------------------------- 5. TLS (internal CA) ------
CERT_DIR="$ROOT_DIR/reverse-proxy/certificates"
mkdir -p "$CERT_DIR"
if [[ "$TLS_MODE" == "internal-ca" && ! -f "$CERT_DIR/platform-wildcard.crt" ]]; then
  log_info "Generating internal CA + wildcard certificate for *.${PLATFORM_DOMAIN}"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
    -subj "/O=DevSecOps Platform/CN=DevSecOps Internal CA" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$CERT_DIR/platform-wildcard.key" -out "$CERT_DIR/wildcard.csr" \
    -subj "/O=DevSecOps Platform/CN=*.${PLATFORM_DOMAIN}" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:*.%s\n' "$PLATFORM_DOMAIN" "$PLATFORM_DOMAIN" > "$CERT_DIR/san.ext"
  openssl x509 -req -in "$CERT_DIR/wildcard.csr" -days 825 -sha256 \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/platform-wildcard.crt" -extfile "$CERT_DIR/san.ext" 2>/dev/null
  rm -f "$CERT_DIR/wildcard.csr" "$CERT_DIR/san.ext"
  chmod 600 "$CERT_DIR"/*.key
  log_ok "Certificates written to $CERT_DIR (distribute ca.crt to clients)"
  # GitLab trusts the internal CA for outbound TLS (mirroring, integrations):
  # omnibus picks up /etc/gitlab/trusted-certs/*.crt during reconfigure.
  mkdir -p "$DATA_ROOT/gitlab/config/trusted-certs"
  cp "$CERT_DIR/ca.crt" "$DATA_ROOT/gitlab/config/trusted-certs/platform-ca.crt"
  log_ok "Internal CA installed into GitLab trusted-certs"
elif [[ -f "$CERT_DIR/platform-wildcard.crt" ]]; then
  log_ok "Certificates already present"
fi

# ------------------------------------------- 6. Traefik dynamic config -------
DYN_DIR="$ROOT_DIR/reverse-proxy/configuration/dynamic"
mkdir -p "$DYN_DIR"

# ADMIN_IP_ALLOWLIST (csv) → YAML list with 10-space indent
ADMIN_IP_ALLOWLIST_YAML=""
IFS=',' read -ra CIDRS <<< "${ADMIN_IP_ALLOWLIST:-127.0.0.1/32}"
for cidr in "${CIDRS[@]}"; do
  ADMIN_IP_ALLOWLIST_YAML+="          - \"${cidr// /}\""$'\n'
done
ADMIN_IP_ALLOWLIST_YAML="${ADMIN_IP_ALLOWLIST_YAML%$'\n'}"

# htpasswd for prometheus/alertmanager routes (stored in secrets/monitoring.env)
if [[ ! -f "$SECRETS_DIR/monitoring.env" ]]; then
  MON_USER="${MONITORING_BASIC_AUTH_USER:-monitoring}"
  MON_PASS="$(gen_secret)"
  MON_HASH="$(openssl passwd -apr1 "$MON_PASS")"
  printf 'MONITORING_BASIC_AUTH_USER=%s\nMONITORING_BASIC_AUTH_PASSWORD=%s\n' "$MON_USER" "$MON_PASS" \
    > "$SECRETS_DIR/monitoring.env"
  chmod 600 "$SECRETS_DIR/monitoring.env"
  log_info "generated monitoring basic-auth credentials (secrets/monitoring.env)"
fi
# shellcheck disable=SC1091
source "$SECRETS_DIR/monitoring.env"
MONITORING_HTPASSWD="${MONITORING_BASIC_AUTH_USER}:$(openssl passwd -apr1 "$MONITORING_BASIC_AUTH_PASSWORD")"

export PLATFORM_DOMAIN ADMIN_IP_ALLOWLIST_YAML MONITORING_HTPASSWD
envsubst '${PLATFORM_DOMAIN} ${ADMIN_IP_ALLOWLIST_YAML} ${MONITORING_HTPASSWD}' \
  < "$ROOT_DIR/reverse-proxy/configuration/dynamic.yml.tmpl" \
  > "$DYN_DIR/dynamic.yml"
log_ok "Rendered Traefik dynamic config → $DYN_DIR/dynamic.yml"

# ------------------------------------------------------ 7. DNS reminder ------
cat <<EOF

${C_BOLD}DNS / hosts entries required on every client machine:${C_RESET}
  127.0.0.1  gitlab.${PLATFORM_DOMAIN} jenkins.${PLATFORM_DOMAIN} sonar.${PLATFORM_DOMAIN} \\
             nexus.${PLATFORM_DOMAIN} registry.${PLATFORM_DOMAIN} vault.${PLATFORM_DOMAIN} \\
             grafana.${PLATFORM_DOMAIN} prometheus.${PLATFORM_DOMAIN} alertmanager.${PLATFORM_DOMAIN}
  (use the platform host IP instead of 127.0.0.1 for remote clients)

  Docker TLS trust for the registry:
    sudo mkdir -p /etc/docker/certs.d/registry.${PLATFORM_DOMAIN}
    sudo cp reverse-proxy/certificates/ca.crt /etc/docker/certs.d/registry.${PLATFORM_DOMAIN}/ca.crt

EOF

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "--dry-run: validating compose configuration only"
  ( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" --profile all config -q ) \
    && log_ok "compose configuration valid"
  exit 0
fi

# --------------------------------------------------- 8. validate & launch ----
PROFILES=(--profile core)
[[ $WITH_MONITORING -eq 1 || $USE_ALL -eq 1 ]] && PROFILES+=(--profile monitoring)
[[ $WITH_BUILD      -eq 1 || $USE_ALL -eq 1 ]] && PROFILES+=(--profile build)
[[ $WITH_AGENTS     -eq 1 || $USE_ALL -eq 1 ]] && PROFILES+=(--profile agents)
[[ $WITH_BACKUP     -eq 1 || $USE_ALL -eq 1 ]] && PROFILES+=(--profile backup)
[[ $USE_ALL -eq 1 ]] && PROFILES=(--profile all)

COMPOSE_EXTRA=()
[[ $PROD -eq 1 ]] && COMPOSE_EXTRA+=(-f docker-compose.prod.yml)

"$SCRIPTS_DIR/validate.sh" || die "Pre-flight validation failed — fix the items above first"

# Build custom images (Phase 3): controller (when JENKINS_IMAGE_OVERRIDE set)
# and agent images (when the agents profile is requested). --skip-build reuses
# images already present.
NEED_AGENTS_IMAGES=0
[[ $WITH_AGENTS -eq 1 || $USE_ALL -eq 1 ]] && NEED_AGENTS_IMAGES=1
if [[ $SKIP_BUILD -eq 0 && ( -n "${JENKINS_IMAGE_OVERRIDE:-}" || $NEED_AGENTS_IMAGES -eq 1 ) ]]; then
  log_info "Building custom Jenkins/agent images…"
  BUILD_ARGS=()
  [[ -n "${JENKINS_IMAGE_OVERRIDE:-}" ]] && BUILD_ARGS+=(--controller)
  [[ $NEED_AGENTS_IMAGES -eq 1 ]] && BUILD_ARGS+=(--agents)
  [[ ${#BUILD_ARGS[@]} -eq 2 ]] && BUILD_ARGS=()
  "$SCRIPTS_DIR/build-images.sh" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
fi

log_info "Pulling images (pinned versions only; locally built images are skipped)…"
( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" ${COMPOSE_EXTRA[@]+"${COMPOSE_EXTRA[@]}"} "${PROFILES[@]}" pull --ignore-pull-failures )

log_info "Starting platform…"
( cd "$ROOT_DIR" && docker compose "${COMPOSE_BASE[@]}" ${COMPOSE_EXTRA[@]+"${COMPOSE_EXTRA[@]}"} "${PROFILES[@]}" up -d )

# ------------------------------------------------- 9. post-start guidance ----
cat <<EOF
${C_GREEN}${C_BOLD}Platform containers started.${C_RESET} First start takes 5–10 minutes
(GitLab reconfigure + SonarQube DB migration + Nexus bootstrap).

Track progress:   ./scripts/health-check.sh
Container state:  docker compose ps

${C_BOLD}Mandatory one-time initializations:${C_RESET}

1) VAULT — initialize & unseal (store keys OFF-HOST, sealed envelopes):
     docker compose exec vault vault operator init -key-shares=5 -key-threshold=3
     docker compose exec vault vault operator unseal   # x3, different keys
   Then create the Jenkins AppRole + policies (Phase 11) and enable audit:
     vault audit enable file file_path=/vault/file/audit.log

2) GITLAB — first login: user 'root', password in secrets/gitlab.env
     https://gitlab.${PLATFORM_DOMAIN}

3) JENKINS — https://jenkins.${PLATFORM_DOMAIN}
     Login: users 'admin' + role accounts (platform-admin, devops-admin,
     developer, security-engineer, release-manager, app-owner).
     All passwords: secrets/jenkins.env  (setup wizard is DISABLED —
     configuration comes from jenkins/casc/ via JCasC; verify at
     /configuration-as-code and /manage/configuration-as-code/reference)
     Warm agents connect automatically (agent-general/python/security);
     dynamic agents scale via the 'docker-agents' cloud once the build
     profile is running (buildkitd + docker-socket-proxy).

4) SONARQUBE — https://sonar.${PLATFORM_DOMAIN}  (admin / follow forced
     password change on first login; API tokens provisioned in Phase 5)

5) NEXUS — https://nexus.${PLATFORM_DOMAIN}  (admin / see
     ${DATA_ROOT}/nexus-data/admin.password; repositories provisioned Phase 5)

6) GRAFANA — https://grafana.${PLATFORM_DOMAIN}  (credentials in secrets/grafana.env)
EOF
