package org.company.devsecops

/**
 * Notification dispatch (master spec §16) — Phase 3 foundation.
 *
 * Channels: SMTP (email-ext), Slack + Microsoft Teams (webhook POST via
 * httpRequest using credential IDs configured in platform-config.yaml).
 * Phase 10 wiring: real webhook/SMTP values land via monitoring/scripts/20-
 * configure-notifications.sh → secrets/jenkins-notifications.env → JCasC
 * credentials + mailer; platform-config `enabled` flags flip per configured
 * channel. Sends to unprovisioned ('SET_IN_PHASE*') credentials are skipped
 * with a logged reason — never a build failure (dispatch is fail-safe).
 * The infrastructure-side twin path is Alertmanager (monitoring/alertmanager/),
 * sharing the same Slack/Teams/SMTP endpoints but fed by Prometheus/Loki alerts.
 *
 * Required context fields (all included when available): service, repository,
 * branch, commit, buildNumber, imageDigest, environment, failureStage,
 * buildUrl, argocdApplicationUrl, qualityGate, securitySummary.
 */
class NotificationService implements Serializable {

    private static final long serialVersionUID = 1L

    private final script
    private final PlatformConfig cfg
    private final PipelineLogger log

    NotificationService(script, PlatformConfig cfg, PipelineLogger log) {
        this.script = script
        this.cfg = cfg
        this.log = log
    }

    /** Build the canonical context map from the pipeline environment + args. */
    static Map contextFrom(script, Map args = [:]) {
        return [
            status            : args.status ?: script.currentBuild?.currentResult ?: 'UNKNOWN',
            service           : args.service ?: script.env.SERVICE_NAME ?: script.env.JOB_NAME,
            repository        : args.repository ?: script.env.GIT_URL ?: '',
            branch            : args.branch ?: script.env.GIT_BRANCH ?: script.env.BRANCH_NAME ?: '',
            commit            : args.commit ?: script.env.GIT_COMMIT ?: '',
            buildNumber       : args.buildNumber ?: script.env.BUILD_NUMBER ?: '',
            buildUrl          : script.env.BUILD_URL ?: '',
            imageDigest       : args.imageDigest ?: script.env.IMAGE_DIGEST ?: '',
            environment       : args.environment ?: script.env.DEPLOY_ENVIRONMENT ?: '',
            failureStage      : args.failureStage ?: script.env.FAILURE_STAGE ?: '',
            argocdApplicationUrl: args.argocdApplicationUrl ?: script.env.ARGOCD_APP_URL ?: '',
            qualityGate       : args.qualityGate ?: script.env.QUALITY_GATE_STATUS ?: '',
            securitySummary   : args.securitySummary ?: script.env.SECURITY_SUMMARY ?: '',
        ]
    }

    /** Human/JSON message containing every field required by master spec §16. */
    String buildMessage(Map ctx) {
        def lines = []
        lines << "[${ctx.status}] ${ctx.service} #${ctx.buildNumber}"
        if (ctx.repository)  { lines << "repository : ${ctx.repository}" }
        if (ctx.branch)      { lines << "branch     : ${ctx.branch}" }
        if (ctx.commit)      { lines << "commit     : ${ctx.commit}" }
        if (ctx.imageDigest) { lines << "image      : ${ctx.imageDigest}" }
        if (ctx.environment) { lines << "environment: ${ctx.environment}" }
        if (ctx.qualityGate) { lines << "qualityGate: ${ctx.qualityGate}" }
        if (ctx.securitySummary) { lines << "security   : ${ctx.securitySummary}" }
        if (ctx.failureStage)    { lines << "failedStage: ${ctx.failureStage}" }
        if (ctx.buildUrl)        { lines << "build      : ${ctx.buildUrl}" }
        if (ctx.argocdApplicationUrl) { lines << "argocd     : ${ctx.argocdApplicationUrl}" }
        return lines.join('\n')
    }

    /** Fail-safe dispatch — a notification problem must never fail a build. */
    void send(Map ctx, String event = 'build_completed') {
        def message = buildMessage(ctx)
        try {
            if (cfg?.get('notifications.email.enabled', false)) {
                sendEmail(ctx, message)
            }
            if (cfg?.get('notifications.slack.enabled', false)) {
                sendWebhook('slack', cfg.get('notifications.slack.credentialId', 'slack-webhook-url'), message, event)
            }
            if (cfg?.get('notifications.teams.enabled', false)) {
                sendWebhook('teams', cfg.get('notifications.teams.credentialId', 'teams-webhook-url'), message, event)
            }
        } catch (Exception e) {
            log.warn('Notify', "notification dispatch failed (build result unaffected): ${e.message}")
        }
    }

    private void sendEmail(Map ctx, String message) {
        def to = cfg.get('notifications.email.to', '') as String
        def subject = "[DevSecOps][${ctx.status}] ${ctx.service} #${ctx.buildNumber}" +
                      (ctx.environment ? " → ${ctx.environment}" : '')
        script.emailext(
            to: to,
            subject: subject,
            body: message,
            mimeType: 'text/plain'
        )
        log.info('Notify', "email sent to ${to}")
    }

    private void sendWebhook(String channel, String credentialId, String message, String event) {
        script.withCredentials([script.string(credentialsId: credentialId, variable: 'WEBHOOK_URL')]) {
            def url = script.env.WEBHOOK_URL
            if (!url || url.startsWith('SET_IN_PHASE')) {
                log.warn('Notify', "${channel} webhook credential '${credentialId}' not provisioned yet — skipped")
                return
            }
            def payload = channel == 'slack' \
                ? script.writeJSON(returnText: true, json: [text: message]) \
                : script.writeJSON(returnText: true, json: [text: message])  // Teams Workflows accepts {text:}
            script.httpRequest(
                url: url,
                httpMode: 'POST',
                contentType: 'APPLICATION_JSON',
                requestBody: payload,
                validResponseCodes: '100:599',   // never fail the build on webhook errors
                quiet: true
            )
            log.info('Notify', "${channel} notification dispatched (event=${event})")
        }
    }
}
