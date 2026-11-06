# orders-api

The DevSecOps platform's **sample microservice** (GETTING-STARTED §14): a
dependency-free Python HTTP service that exercises the full pipeline —
gitleaks → build → unit tests → Sonar quality gate → semgrep + trivy-fs →
BuildKit container build → image scan → SBOM → **cosign sign** → publish to
the platform registry → GitOps digest pin → ArgoCD sync → Kyverno admission →
canary rollout → verify → notify.

## Endpoints

| Path       | Purpose                           |
|------------|-----------------------------------|
| `/healthz` | liveness + startup probe target   |
| `/readyz`  | readiness probe target            |
| `/orders`  | sample JSON payload (smoke tests) |

## Run locally

```bash
python3 app.py           # listens on :8080 (HTTP_PORT), LOG_LEVEL=info
python3 -m pytest -q     # unit tests (or: python3 -m unittest)
```

## Pipeline

`Jenkinsfile` delegates everything to `microservicePipeline()` from
`platform/devsecops-shared-library`. Policy knobs (scan thresholds, rollout
behavior) belong in an optional `.devsecops.yaml` — see
`jenkins/shared-library/examples/`.
