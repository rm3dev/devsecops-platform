#!/usr/bin/env bash
# =============================================================================
# 20-configure-notifications.sh — one-shot wiring of ALL notification paths
# (Phase 10, D-34). Reads .env (SMTP_*, SLACK_WEBHOOK_URL, TEAMS_WEBHOOK_URL,
# NOTIFICATION_EMAIL_TO, ONCALL_EMAIL_TO); prompts for SMTP_PASSWORD if SMTP is
# configured but no password is exported. Then, idempotently:
#
#   1. secrets/alertmanager/{slack_webhook_url,teams_webhook_url,smtp_password}                    → Alertmanager *_file receivers
#   2. monitoring/alertmanager/alertmanager.yml
#      global.smtp_smarthost/smtp_from + receiver email `to:` addresses (yq)
#   3. secrets/jenkins-notifications.env → JCasC creds slack/teams-webhook-url
#      + mailer SMTP_* (needs jenkins recreate to take effect)
#   4. jenkins/shared-library/config/platform-config.yaml
#      notifications.<channel>.enabled flipped ONLY for channels with real
#      values; notifications.email.to set (consumed by NotificationService)
#   5. SIGHUP to a running Alertmanager (live config reload, no restart)
#
# Channels left empty stay on parse-safe placeholders (bootstrap.sh) — config
# loads, nothing is sent. Phase 11 replaces this script's inputs with Vault
# dynamic secrets; the file layout stays identical.
# Requires: yq (v4), docker compose (only for the SIGHUP step).
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
load_env
require_cmd yq

SEC="$ROOT/secrets/alertmanager"
mkdir -p "$SEC"; chmod 700 "$SEC"
write_raw() { printf '%s' "$2" > "$1"; chmod 600 "$1"; }   # no trailing newline: *_file values are used verbatim

# --- gather inputs -------------------------------------------------------------
SMTP_HOST="${SMTP_HOST:-}"; SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"; SMTP_FROM="${SMTP_FROM:-devsecops-platform@${PLATFORM_DOMAIN:-localhost}}"
NOTIFICATION_EMAIL_TO="${NOTIFICATION_EMAIL_TO:-}"
ONCALL_EMAIL_TO="${ONCALL_EMAIL_TO:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
TEAMS_WEBHOOK_URL="${TEAMS_WEBHOOK_URL:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
if [[ -n "$SMTP_HOST" && -z "$SMTP_PASSWORD" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "SMTP password for ${SMTP_USER:-<no user>}@${SMTP_HOST}: " SMTP_PASSWORD; echo
  else
    log_warn "SMTP_HOST set but SMTP_PASSWORD not exported and stdin is not a TTY — writing placeholder (email will fail until rerun)"
    SMTP_PASSWORD="SET_IN_PHASE_10"
  fi
fi

# --- 1. alertmanager secret files ----------------------------------------------
write_raw "$SEC/slack_webhook_url" "${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/T00000000/B00000000/SET_IN_PHASE_10}"
write_raw "$SEC/teams_webhook_url" "${TEAMS_WEBHOOK_URL:-https://example.webhook.office.com/webhookb2/SET/IN/PHASE10}"
write_raw "$SEC/smtp_password" "${SMTP_PASSWORD:-SET_IN_PHASE_10}"
log_ok "secrets/alertmanager/* written"

# --- 2. alertmanager.yml inline values (smarthost/from/to) ----------------------
# (yq strenv injection — envsubst corrupts Go templates; parse-safe defaults
#  keep the config loadable even when a channel is not configured)
AM_YML="$ROOT/monitoring/alertmanager/alertmanager.yml"
export SMTP_HOST_PORT="${SMTP_HOST:-smtp.invalid}:${SMTP_PORT}"
export NOTIFICATION_EMAIL_TO="${NOTIFICATION_EMAIL_TO:-devsecops-team@invalid}"
export ONCALL_EMAIL_TO="${ONCALL_EMAIL_TO:-devsecops-oncall@invalid}" SMTP_FROM
export SMTP_USER_V="${SMTP_USER:-SET_IN_PHASE_10}"   # inline auth_username (not a secret)
yq -i '
  .global.smtp_smarthost = strenv(SMTP_HOST_PORT) |
  .global.smtp_from = strenv(SMTP_FROM) |
  (.receivers[] | select(.name == "platform-default") | .email_configs[0].to) = strenv(NOTIFICATION_EMAIL_TO) |
  (.receivers[] | select(.name == "platform-default") | .email_configs[0].auth_username) = strenv(SMTP_USER_V) |
  (.receivers[] | select(.name == "oncall-critical") | .email_configs[0].to) = strenv(ONCALL_EMAIL_TO) |
  (.receivers[] | select(.name == "oncall-critical") | .email_configs[0].auth_username) = strenv(SMTP_USER_V)
' "$AM_YML"
log_ok "alertmanager.yml smarthost/from/to updated"

# --- 3. jenkins notification env ------------------------------------------------
J_ENV="$ROOT/secrets/jenkins-notifications.env"
umask 077
cat > "$J_ENV" <<EOF
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-SET_IN_PHASE_10}
TEAMS_WEBHOOK_URL=${TEAMS_WEBHOOK_URL:-SET_IN_PHASE_10}
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
SMTP_FROM=${SMTP_FROM}
EOF
chmod 600 "$J_ENV"; umask 022
log_ok "secrets/jenkins-notifications.env written (jenkins recreate required: docker compose up -d jenkins)"

# --- 4. platform-config notification flags (only configured channels) -----------
PC="$ROOT/jenkins/shared-library/config/platform-config.yaml"
NOTIF_EMAIL_ENABLED=false; [[ -n "$SMTP_HOST" ]] && NOTIF_EMAIL_ENABLED=true
NOTIF_SLACK_ENABLED=false; [[ -n "$SLACK_WEBHOOK_URL" ]] && NOTIF_SLACK_ENABLED=true
NOTIF_TEAMS_ENABLED=false; [[ -n "$TEAMS_WEBHOOK_URL" ]] && NOTIF_TEAMS_ENABLED=true
export NOTIF_EMAIL_ENABLED NOTIF_SLACK_ENABLED NOTIF_TEAMS_ENABLED NOTIFICATION_EMAIL_TO
yq -i '
  .notifications.email.enabled = (strenv(NOTIF_EMAIL_ENABLED) == "true") |
  .notifications.email.to = strenv(NOTIFICATION_EMAIL_TO) |
  .notifications.slack.enabled = (strenv(NOTIF_SLACK_ENABLED) == "true") |
  .notifications.teams.enabled = (strenv(NOTIF_TEAMS_ENABLED) == "true")
' "$PC"
log_ok "platform-config notifications: email=$NOTIF_EMAIL_ENABLED slack=$NOTIF_SLACK_ENABLED teams=$NOTIF_TEAMS_ENABLED"

# --- 5. live reload (Alertmanager) ------------------------------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '(^|-)alertmanager(-|$|[0-9])'; then
  compose exec -T alertmanager kill -HUP 1 && log_ok "Alertmanager reloaded (SIGHUP)"
else
  log_warn "Alertmanager not running — config will load on next start"
fi

cat <<EOF

Done. Remaining manual step:
  docker compose up -d jenkins     # picks up new SMTP/webhook env (JCasC creds)
Test paths:
  Alertmanager → send test:  curl -s localhost:9093/-/healthy
  Jenkins      → any build's post{always{}} notifyResult (check build log for 'Notify')
  Prometheus   → SLO/alert rules: https://prometheus.<domain>/alerts (Watchdog must be firing)
EOF
