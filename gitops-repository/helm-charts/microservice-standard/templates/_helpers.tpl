{{/*
Release name IS the service slug (rendered as `helm template <slug> …` by CI).
*/}}
{{- define "microservice-standard.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "microservice-standard.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "microservice-standard.name" .) -}}
{{- else -}}
{{- "default" -}}
{{- end -}}
{{- end -}}

{{/* Common metadata labels (immutable selector subset lives in selectorLabels) */}}
{{- define "microservice-standard.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "microservice-standard.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Release.Name }}
{{- end -}}

{{/* Selector labels — NEVER change these on a live app (selector is immutable) */}}
{{- define "microservice-standard.selectorLabels" -}}
app: {{ .Release.Name }}
app.kubernetes.io/name: {{ include "microservice-standard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image reference: mutable placeholder tag on purpose — the environment
     overlay pins `digest:` via the kustomize images transformer (D-26). */}}
{{- define "microservice-standard.image" -}}
{{- required "image.repository is required (registry.<domain>/<team>/<service>)" .Values.image.repository -}}
:managed-by-gitops
{{- end -}}

{{/* Vault application path: apps/<release> unless overridden */}}
{{- define "microservice-standard.vaultAppPath" -}}
{{- .Values.vaultAppPath | default (printf "apps/%s" .Release.Name) -}}
{{- end -}}

{{/* ConfigMap name */}}
{{- define "microservice-standard.configMapName" -}}
{{- printf "%s-config" (include "microservice-standard.name" .) -}}
{{- end -}}

{{/* Workload kind rendered by this chart (Deployment or Argo Rollouts Rollout).
     Used by the HPA scaleTargetRef and referenced in overlay docs. */}}
{{- define "microservice-standard.workloadKind" -}}
{{- if .Values.rollout.enabled -}}Rollout{{- else -}}Deployment{{- end -}}
{{- end -}}

{{/*
Shared pod template for Deployment AND Rollout (Phase 9: progressive delivery
renders a Rollout instead of a Deployment — the pod spec stays identical, so
security context, probes, ESO envFrom and the digest-pinned image apply to
both workload kinds without drift.
*/}}
{{- define "microservice-standard.podTemplate" -}}
metadata:
  labels:
    {{- include "microservice-standard.labels" . | nindent 4 }}
  annotations:
    {{- if .Values.config }}
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    {{- end }}
    {{- if .Values.metrics.enabled }}
    prometheus.io/scrape: "true"
    prometheus.io/path: {{ .Values.metrics.path | quote }}
    prometheus.io/port: {{ (.Values.metrics.port | toString) | quote }}
    {{- end }}
spec:
  serviceAccountName: {{ include "microservice-standard.serviceAccountName" . }}
  terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds }}
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: {{ include "microservice-standard.name" . }}
      image: "{{ include "microservice-standard.image" . }}"
      imagePullPolicy: IfNotPresent
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      ports:
        {{- toYaml .Values.ports | nindent 8 }}
      {{- if or .Values.config .Values.envFrom }}
      envFrom:
        {{- if .Values.config }}
        - configMapRef:
            name: {{ include "microservice-standard.configMapName" . }}
        {{- end }}
        {{- with .Values.envFrom }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
      {{- with .Values.env }}
      env:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.probes.liveness }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.probes.readiness }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.probes.startup }}
      startupProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      resources:
        {{- toYaml .Values.resources | nindent 8 }}
      {{- with .Values.emptyDirMounts }}
      volumeMounts:
        {{- range . }}
        - name: {{ .name }}
          mountPath: {{ .mountPath }}
          {{- with .subPath }}
          subPath: {{ . }}
          {{- end }}
        {{- end }}
      {{- end }}
  {{- with .Values.emptyDirMounts }}
  volumes:
    {{- range . }}
    - name: {{ .name }}
      emptyDir: {}
    {{- end }}
  {{- end }}
  {{- with .Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}
