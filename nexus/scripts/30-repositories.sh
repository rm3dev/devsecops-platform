#!/usr/bin/env bash
# =============================================================================
# 30-repositories.sh — repository layout (D-06: Nexus is the ONLY registry and
# the ONLY upstream for build agents, D-16). Idempotent: existing repos skipped.
#
#   PROXIES  (upstream caches)          HOSTED (platform artifacts)
#   ─ maven-central                     ─ maven-releases   (ALLOW_ONCE, no cleanup)
#   ─ npm-proxy                         ─ maven-snapshots  (ALLOW)
#   ─ pypi-proxy                        ─ npm-hosted
#   ─ nuget-proxy                       ─ pypi-hosted
#   ─ docker-proxy  (registry-1)        ─ nuget-hosted
#                                       ─ raw-hosted       (SBOMs, k6/Newman reports)
#   GROUPS (single consumer URL)        ─ docker-hosted    (images; NEVER cleaned)
#   ─ maven-public  ─ npm-public
#   ─ pypi-public   ─ nuget-public
#   ─ docker-group  → HTTP connector :8085 = Traefik 'registry.<domain>' router
#
# Cleanup bindings: proxies only (see 20-cleanup-policies.sh safety note).
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nexus-api.sh"
load_env; load_nexus_secrets
require_cmd jq

: "${NEXUS_ADMIN_PASSWORD:?run 10-admin-bootstrap.sh first}"

DOCKER_GROUP_PORT="${NEXUS_DOCKER_GROUP_PORT:-8085}"   # must match dynamic.yml.tmpl tcp service

ensure_repo() { # format, type, name, json-body
  local format="$1" type="$2" name="$3" body="$4" code
  if nx_repo_exists "$name"; then
    log_ok "repository '${name}' exists — skipping"
    return 0
  fi
  code="$(nx_api_rc POST "/repositories/${format}/${type}" "$body" | head -1)"
  if [[ "$code" == "201" || "$code" == "200" ]]; then
    log_ok "repository '${name}' created (${format}/${type})"
  else
    die "repository '${name}' creation failed (HTTP ${code}) — body: ${body}"
  fi
}

storage() { # writePolicy → json fragment (default blob store, strict validation)
  jq -n --arg wp "$1" '{blobStoreName:"default", strictContentTypeValidation:true, writePolicy:$wp}'
}
proxy_block() { # remoteUrl → common proxy sections
  jq -n --arg u "$1" '{
    proxy: {remoteUrl:$u, contentDisposition:"INLINE", metadataPolicy:"PERMISSIVE",
            priority:0, rewritePackageAttributes:false},
    negativeCache: {enabled:true, timeToLive:1440},
    httpClient: {blocked:false, autoBlock:true,
                 connection:{retries:0, timeout:1440, enableCircularRedirects:false,
                             enableCookies:false, useTrustStore:false}}
  }'
}
cleanup_of() { # policy-name-or-empty → json fragment
  if [[ -n "$1" ]]; then jq -n --arg p "$1" '{policyNames:[$p]}'; else jq -n '{policyNames:[]}'; fi
}

log_info "── proxies ──"
ensure_repo maven proxy maven-central "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://repo.maven.apache.org/maven2/')" \
  --argjson c "$(cleanup_of cleanup-maven2)" \
  '{name:"maven-central", online:true, storage:$s, cleanup:$c, maven:{versionPolicy:"MIXED", layoutPolicy:"PERMISSIVE"}} + $p')"
ensure_repo npm proxy npm-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://registry.npmjs.org')" \
  --argjson c "$(cleanup_of cleanup-npm)" \
  '{name:"npm-proxy", online:true, storage:$s, cleanup:$c} + $p')"
ensure_repo pypi proxy pypi-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://pypi.org/')" \
  --argjson c "$(cleanup_of cleanup-pypi)" \
  '{name:"pypi-proxy", online:true, storage:$s, cleanup:$c} + $p')"
ensure_repo nuget proxy nuget-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://api.nuget.org/v3/index.json')" \
  --argjson c "$(cleanup_of cleanup-nuget)" \
  '{name:"nuget-proxy", online:true, storage:$s, cleanup:$c, nugetProxy:{queryCacheItemMaxAge:3600, nugetVersion:"V3"}} + $p')"
ensure_repo docker proxy docker-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://registry-1.docker.io')" \
  --argjson c "$(cleanup_of cleanup-docker)" \
  '{name:"docker-proxy", online:true, storage:$s, cleanup:$c, docker:{forceBasicAuth:true, v1Enabled:false}} + $p')"
# ghcr.io pull-through — Phase 7: trivy vulnerability/java DBs are OCI artifacts
# on ghcr.io; agents fetch them via registry.<domain> (docker-group) so security
# tooling stays inside the D-16 no-internet boundary.
ensure_repo docker proxy ghcr-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://ghcr.io')" \
  --argjson c "$(cleanup_of cleanup-docker)" \
  '{name:"ghcr-proxy", online:true, storage:$s, cleanup:$c, docker:{forceBasicAuth:true, v1Enabled:false}} + $p')"
# Phase 8 (D-27): the Kubernetes cluster mirrors docker.io/quay.io/ghcr.io
# through docker-group (k3s registries.yaml) — ArgoCD lives on quay.io, so the
# group needs a quay pull-through as well (Kyverno=ghcr, ESO=ghcr already covered).
ensure_repo docker proxy quay-proxy "$(jq -n --argjson s "$(storage PERMISSIVE)" --argjson p "$(proxy_block 'https://quay.io')" \
  --argjson c "$(cleanup_of cleanup-docker)" \
  '{name:"quay-proxy", online:true, storage:$s, cleanup:$c, docker:{forceBasicAuth:true, v1Enabled:false}} + $p')"

log_info "── hosted ──"
ensure_repo maven hosted maven-releases "$(jq -n --argjson s "$(storage ALLOW_ONCE)" --argjson c "$(cleanup_of '')" \
  '{name:"maven-releases", online:true, storage:$s, cleanup:$c, maven:{versionPolicy:"RELEASE", layoutPolicy:"STRICT"}}')"
ensure_repo maven hosted maven-snapshots "$(jq -n --argjson s "$(storage ALLOW)" --argjson c "$(cleanup_of '')" \
  '{name:"maven-snapshots", online:true, storage:$s, cleanup:$c, maven:{versionPolicy:"SNAPSHOT", layoutPolicy:"STRICT"}}')"
ensure_repo npm hosted npm-hosted "$(jq -n --argjson s "$(storage ALLOW_ONCE)" --argjson c "$(cleanup_of '')" \
  '{name:"npm-hosted", online:true, storage:$s, cleanup:$c, npm:{strictContentTypeValidation:true}}')"
ensure_repo pypi hosted pypi-hosted "$(jq -n --argjson s "$(storage ALLOW_ONCE)" --argjson c "$(cleanup_of '')" \
  '{name:"pypi-hosted", online:true, storage:$s, cleanup:$c, pypi:{}}')"
ensure_repo nuget hosted nuget-hosted "$(jq -n --argjson s "$(storage ALLOW_ONCE)" --argjson c "$(cleanup_of '')" \
  '{name:"nuget-hosted", online:true, storage:$s, cleanup:$c, nuget:{}}')"
ensure_repo raw hosted raw-hosted "$(jq -n --argjson s "$(storage ALLOW)" --argjson c "$(cleanup_of '')" \
  '{name:"raw-hosted", online:true, storage:$s, cleanup:$c, raw:{}}')"
ensure_repo docker hosted docker-hosted "$(jq -n --argjson s "$(storage ALLOW)" --argjson c "$(cleanup_of '')" \
  '{name:"docker-hosted", online:true, storage:$s, cleanup:$c, docker:{forceBasicAuth:true, v1Enabled:false}}')"

log_info "── groups ──"
group_body() { # name, members-csv, extra-json(may be empty)
  local members; members="$(jq -n --arg m "$2" '$m | split(",")')"
  local base; base="$(jq -n --arg n "$1" --argjson m "$members" \
    '{name:$n, online:true, storage:{blobStoreName:"default", strictContentTypeValidation:false}, group:{memberNames:$m}}')"
  if [[ -n "$3" ]]; then jq -n --argjson b "$base" --argjson e "$3" '$b + $e'; else echo "$base"; fi
}
ensure_repo maven group maven-public "$(group_body maven-public 'maven-releases,maven-snapshots,maven-central' \
  '{"maven":{"versionPolicy":"MIXED","layoutPolicy":"PERMISSIVE"}}')}"
ensure_repo npm group npm-public "$(group_body npm-public 'npm-hosted,npm-proxy' '')"
ensure_repo pypi group pypi-public "$(group_body pypi-public 'pypi-hosted,pypi-proxy' '')"
ensure_repo nuget group nuget-public "$(group_body nuget-public 'nuget-hosted,nuget-proxy' '')"
ensure_repo docker group docker-group "$(group_body docker-group 'docker-hosted,ghcr-proxy,quay-proxy,docker-proxy' \
  "$(jq -n --argjson port "$DOCKER_GROUP_PORT" '{docker:{forceBasicAuth:true, httpPort:$port, v1Enabled:false}}')")"

# Member sync for PRE-EXISTING docker-group installs (ensure_repo skips those):
# Phase 7 added ghcr-proxy, Phase 8 adds quay-proxy — apply the canonical
# member order idempotently.
CANONICAL_MEMBERS='["docker-hosted","ghcr-proxy","quay-proxy","docker-proxy"]'
CURRENT_MEMBERS="$(nx_api GET "/repositories/docker/group/docker-group" | jq -c '.group.memberNames // []' 2>/dev/null || echo '[]')"
if [[ "$CURRENT_MEMBERS" != "$CANONICAL_MEMBERS" ]]; then
  GROUP_UPDATE="$(jq -n --argjson m "$CANONICAL_MEMBERS" --argjson port "$DOCKER_GROUP_PORT" '{
    name:"docker-group", online:true,
    storage:{blobStoreName:"default", strictContentTypeValidation:false},
    group:{memberNames:$m},
    docker:{forceBasicAuth:true, httpPort:$port, v1Enabled:false}
  }')"
  CODE="$(nx_api_rc PUT "/repositories/docker/group/docker-group" "$GROUP_UPDATE" | head -1)"
  if [[ "$CODE" == "204" || "$CODE" == "200" ]]; then
    log_ok "docker-group members synced → ${CANONICAL_MEMBERS}"
  else
    log_warn "docker-group member sync failed (HTTP ${CODE}) — current: ${CURRENT_MEMBERS}"
  fi
fi

log_ok "repository layout complete (docker-group connector :${DOCKER_GROUP_PORT} → Traefik registry router)"
