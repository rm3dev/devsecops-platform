import org.company.devsecops.NotificationService
import org.company.devsecops.PipelineLogger
import org.company.devsecops.PlatformConfig

/**
 * Final-reporting notification step (master spec §9 Stage 20, §16).
 * Safe to call from post{always{}} — swallows and logs its own failures.
 *
 * args (all optional; falls back to pipeline environment):
 *   config, serviceName, event ('build_started'|'build_completed'|
 *   'deployment_started'|'deployment_completed'|'deployment_failed'|
 *   'rollback_executed'|'release_approved'|'quality_gate_failed'|
 *   'critical_vulnerability'|'container_published')
 *   plus any NotificationService.contextFrom field (imageDigest, environment…)
 */
def call(Map args = [:]) {
    def log = new PipelineLogger(this, args.serviceName ?: env.SERVICE_NAME ?: env.JOB_NAME)
    try {
        PlatformConfig cfg = (args.config instanceof PlatformConfig) ? args.config : PlatformConfig.load(this)
        def svc = new NotificationService(this, cfg, log)
        def ctx = NotificationService.contextFrom(this, args)
        ctx.service = args.serviceName ?: env.SERVICE_NAME ?: ctx.service
        svc.send(ctx, (args.event ?: 'build_completed') as String)
    } catch (Exception e) {
        log.warn('Notify', "notifyResult could not run (build result unaffected): ${e.message}")
    }
}
