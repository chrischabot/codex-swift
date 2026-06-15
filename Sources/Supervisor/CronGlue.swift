import Foundation
import Cron
import Push
import ProtocolModel

/// ADDONS #6 cron glue: the runner closure + the automations migration. Lives in
/// Supervisor (the only library that imports SessionSupervisor + Cron + Push) so
/// it is UNIT-TESTABLE (not buried in the codexd executable) while Cron stays
/// dependency-light.
public enum CronGlue {

    /// Build the injected `CronScheduler.Runner`: fire the job's prompt as a
    /// SINGLE unattended turn, then deliver the result via the durable
    /// PushRouter (#7).
    ///
    /// SECURITY (the load-bearing decisions for an UNATTENDED turn):
    /// - `approvalPolicy: .never` — `collectTurn` wires a NO-OP onServerRequest,
    ///   so under the default policy an approval gate would BLOCK until the
    ///   collect timeout. `.never` makes the engine DENY an approval-required
    ///   tool inline instead, so the turn never hangs on an unanswerable prompt.
    /// - `sandboxMode: .readOnly` + `networkAccess: false` — the turn can't write
    ///   or reach the network; a prompt-injected cron prompt can't escalate.
    /// - `ephemeral: job.skipMemory` — skipMemory (default true) short-circuits
    ///   memory consolidation in the engine (no silent rewrite of the user model)
    ///   and avoids persisting a thread row every fire.
    /// The locked-down SessionConfig an unattended cron turn runs under. Pure +
    /// public so a test can assert the security properties directly (without a
    /// full engine): `.never` approval, `.readOnly` sandbox, no network, and
    /// `ephemeral == skipMemory`.
    public static func cronSessionConfig(job: CronJob, defaultCwd: String,
                                         defaultModel: String) -> SessionConfig {
        SessionConfig(
            threadId: .generate(), cwd: defaultCwd, model: defaultModel,
            ephemeral: job.skipMemory,
            approvalPolicy: .never,
            sandboxMode: .readOnly,
            networkAccess: false)
    }

    /// The locked-down SessionConfig for an unattended **wiki research round** (§14.5 —
    /// the design's flagged "real security task"). Unlike a cron turn, a research round
    /// MUST reach the network (to fetch sources) and MUST write (to persist findings into
    /// the wiki vault) — which is exactly why its confinement is the load-bearing part:
    ///
    /// - `sandboxMode: .workspaceWrite` + `writableRoots: [vaultRoot]` — writes are
    ///   confined to the WIKI VAULT ONLY. No project tree, no home, no arbitrary fs; a
    ///   prompt-injected source can't make the round scribble outside the knowledge base.
    /// - `networkAccess: true` — egress is REQUIRED, but it is *screened*: every fetch
    ///   still flows through PinnedFetcher + EgressGuard (HTTPS-only, public-host, IP-pin,
    ///   per-redirect re-vet) at the fetch layer. The sandbox flag only permits the
    ///   syscalls; the EgressGuard chokepoint is the actual screen (NOT re-opened here).
    /// - `approvalPolicy: .never` — unattended, so it can't block on an unanswerable gate
    ///   (the engine denies an approval-required tool inline instead of hanging).
    /// - `ephemeral: skipMemory` — an unattended round must not silently rewrite the user
    ///   model; memory consolidation is off when skipMemory is set.
    ///
    /// Pure + public so a test pins these security properties directly (no full engine).
    public static func researchRoundSessionConfig(vaultRoot: String, defaultModel: String,
                                                  skipMemory: Bool = true) -> SessionConfig {
        SessionConfig(
            threadId: .generate(), cwd: vaultRoot, model: defaultModel,
            ephemeral: skipMemory,
            approvalPolicy: .never,
            sandboxMode: .workspaceWrite,
            writableRoots: [vaultRoot],          // the wiki vault — and nothing else
            networkAccess: true)                 // screened at PinnedFetcher/EgressGuard
    }

    public static func makeCronRunner(supervisor: SessionSupervisor,
                                      defaultCwd: String,
                                      defaultModel: String,
                                      timeout: Duration = .seconds(120)) -> CronScheduler.Runner {
        return { job in
            let cfg = cronSessionConfig(job: job, defaultCwd: defaultCwd, defaultModel: defaultModel)
            let collected = await supervisor.collectTurn(
                cfg, input: [TurnInput(text: job.prompt)], model: defaultModel, timeout: timeout)
            // Deliver (#7) if a target is set + push is configured. Keyless =
            // each fire is a distinct send (no accidental dedup of a legitimate
            // repeated fire); SSRF is contained at the PushRouter/EgressGuard
            // chokepoint, NOT re-opened here.
            if let target = job.deliverTo, !target.isEmpty,
               let router = PushRouterHolder.shared.current() {
                let text = collected.text.isEmpty
                    ? "cron job '\(job.id)' ran (\(collected.status), no output)"
                    : collected.text
                _ = await router.send(target: target, text: text)
            }
            return collected.ok
        }
    }

    /// One-shot migration `automations.json` → `cron_jobs.json`. Idempotent —
    /// no-ops once cron_jobs.json exists. Manual automations are SKIPPED (no
    /// schedule); scheduled ones map to `.every(<seconds>)` via the shared
    /// `automationIntervalSeconds`. Backs up automations.json to `.bak` first.
    /// Returns the number of jobs migrated. `now` is injected for testability.
    @discardableResult
    public static func migrateAutomationsToCron(
        codexHome: String,
        now: () -> Int64 = { Int64(Date().timeIntervalSince1970) }) -> Int {
        let autoPath = codexHome + "/automations.json"
        let cronPath = codexHome + "/cron_jobs.json"
        let fm = FileManager.default
        guard !fm.fileExists(atPath: cronPath) else { return 0 }   // already migrated
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: autoPath)),
              let autos = try? JSONDecoder().decode([Automation].self, from: data) else { return 0 }
        let createdAt = now()
        var jobs: [CronJob] = []
        for a in autos {
            guard let interval = automationIntervalSeconds(a.schedule), interval > 0 else { continue }
            jobs.append(CronJob(
                id: a.id, schedule: .every(interval), prompt: a.prompt,
                enabled: a.enabled, skipMemory: true, deliverTo: nil,
                lastRunAt: a.lastRunAt, createdAt: createdAt))
        }
        guard !jobs.isEmpty else { return 0 }
        try? fm.copyItem(atPath: autoPath, toPath: autoPath + ".bak")   // backup before we take over
        if let out = try? JSONEncoder().encode(jobs) {
            try? out.write(to: URL(fileURLWithPath: cronPath), options: .atomic)
        }
        return jobs.count
    }
}
