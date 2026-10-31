package org.company.devsecops

/**
 * Structured console logger for all library steps.
 * Every line is prefixed so Loki/Grafana can filter by service and stage:
 *   [devsecops][payment-service][Image Scan] CRITICAL count=2 → blocking
 */
class PipelineLogger implements Serializable {

    private static final long serialVersionUID = 1L

    private final script
    private final String service

    PipelineLogger(script, String service = 'platform') {
        this.script = script
        this.service = service ?: 'platform'
    }

    void info(String stage, String message) {
        script.echo "[devsecops][${service}][${stage}] ${message}"
    }

    void warn(String stage, String message) {
        script.echo "[devsecops][${service}][${stage}] WARN: ${message}"
    }

    void error(String stage, String message) {
        script.echo "[devsecops][${service}][${stage}] ERROR: ${message}"
    }

    /** A stage gated off by platform config — recorded loudly, never silently. */
    void stageSkipped(String stage, String reason) {
        script.echo "[devsecops][${service}][${stage}] SKIPPED — ${reason}"
    }

    /** A security gate that BLOCKS the pipeline. */
    void blocked(String stage, String reason) {
        script.echo "[devsecops][${service}][${stage}] BLOCKED — ${reason}"
    }
}
