import Foundation

/// Boucle de surveillance.
///
/// Trois protections contre l'emballement, parce qu'un garde qui suspend des
/// apps sur un pic de 200 ms est pire que pas de garde :
///  - **confirmation** : il faut `confirmSamples` échantillons consécutifs au
///    même niveau avant d'agir ;
///  - **escalade unidirectionnelle** : on n'agit qu'en montée de niveau, le
///    retour à l'état sain passe par `deescalate` ;
///  - **cooldown** : une cible touchée n'est pas retouchée avant
///    `cooldownSeconds`.
public final class Guardian {
    private let config: Config
    private let sampler: MemorySampler
    private let notifier: Notifier
    private let history: HistoryLog
    private let actuator: Actuator
    private let dryRun: Bool

    private var streak: (tier: RiskTier, count: Int) = (.ok, 0)
    private var actedTier: RiskTier = .ok
    private var lastActionAt: [String: Date] = [:]
    private var suspendedKeys: Set<String> = []
    private var lastNotifiedTier: RiskTier = .ok
    private var lastAction: String?

    /// Appelé à chaque échantillon — utilisé par `watch` pour l'affichage.
    public var onSample: ((MemorySample, RiskAssessment, [AppGroup]) -> Void)?

    public init(config: Config, dryRun: Bool = false) {
        self.config = config
        self.dryRun = dryRun
        self.sampler = MemorySampler()
        self.notifier = Notifier(enabled: config.actions.notify)
        self.history = HistoryLog()
        self.actuator = Actuator(config: config, dryRun: dryRun)
    }

    /// Un tour de boucle. Séparé de `run()` pour rester testable.
    @discardableResult
    public func tick() -> (MemorySample, RiskAssessment, [AppGroup]) {
        let sample = sampler.sample()
        let assessment = RiskModel.assess(sample, thresholds: config.thresholds)
        let groups = ProcessInventory.currentGroups()

        updateStreak(assessment.tier)
        publish(sample, assessment, groups)
        onSample?(sample, assessment, groups)

        let confirmed = streak.count >= config.actions.confirmSamples
        if confirmed, assessment.tier > actedTier {
            escalate(to: assessment.tier, sample: sample, assessment: assessment, groups: groups)
        } else if confirmed, assessment.tier == .ok, actedTier != .ok {
            deescalate(groups: groups, sample: sample, assessment: assessment)
        }
        return (sample, assessment, groups)
    }

    public func run() -> Never {
        let interval = max(1.0, config.pollSeconds)
        while true {
            tick()
            Thread.sleep(forTimeInterval: interval)
        }
    }

    // MARK: - Machine à états

    private func updateStreak(_ tier: RiskTier) {
        if tier == streak.tier {
            streak.count += 1
        } else {
            streak = (tier, 1)
        }
    }

    private func escalate(
        to tier: RiskTier,
        sample: MemorySample,
        assessment: RiskAssessment,
        groups: [AppGroup]
    ) {
        actedTier = tier
        let offenders = groups.prefix(3).map { "\($0.name) \(Bytes.human($0.footprintBytes))" }

        if tier >= .high, lastNotifiedTier != tier {
            lastNotifiedTier = tier
            notifier.post(
                title: "Mémoire : niveau \(tier.frenchLabel)",
                subtitle: assessment.summary,
                body: "Plus gros consommateurs — " + offenders.joined(separator: ", ")
            )
        }

        var performed: [String] = []
        let targets = groups.filter { config.isManageable($0) && !$0.suspended }

        if tier >= .high, config.actions.suspendAtHigh {
            for group in targets where allowedNow(group.key) {
                let result = actuator.perform(.suspend, on: group)
                if result.succeeded {
                    suspendedKeys.insert(group.key)
                    lastActionAt[group.key] = Date()
                    performed.append("suspend:\(group.name)")
                }
            }
        }
        if tier == .critical, config.actions.quitAtCritical {
            for group in targets where allowedNow(group.key) {
                let result = actuator.perform(.quit, on: group)
                if result.succeeded {
                    lastActionAt[group.key] = Date()
                    performed.append("quit:\(group.name)")
                }
            }
        }

        lastAction = performed.isEmpty ? nil : performed.joined(separator: " ")
        history.append(HistoryEntry(
            sample: sample,
            assessment: assessment,
            topOffenders: Array(offenders),
            action: lastAction ?? "notify"
        ))
    }

    private func deescalate(groups: [AppGroup], sample: MemorySample, assessment: RiskAssessment) {
        actedTier = .ok
        lastNotifiedTier = .ok
        guard config.actions.autoResume, !suspendedKeys.isEmpty else {
            history.append(HistoryEntry(
                sample: sample, assessment: assessment, topOffenders: [], action: "recovered"
            ))
            return
        }
        var resumed: [String] = []
        for group in groups where suspendedKeys.contains(group.key) {
            if actuator.perform(.resume, on: group).succeeded {
                resumed.append(group.name)
            }
        }
        suspendedKeys.removeAll()
        lastAction = resumed.isEmpty ? nil : "resume:" + resumed.joined(separator: ",")
        history.append(HistoryEntry(
            sample: sample, assessment: assessment, topOffenders: [],
            action: lastAction ?? "recovered"
        ))
        if !resumed.isEmpty {
            notifier.post(
                title: "Mémoire revenue à la normale",
                body: "Reprise de " + resumed.joined(separator: ", ")
            )
        }
    }

    private func allowedNow(_ key: String) -> Bool {
        guard let last = lastActionAt[key] else { return true }
        return Date().timeIntervalSince(last) >= config.actions.cooldownSeconds
    }

    private func publish(_ sample: MemorySample, _ assessment: RiskAssessment, _ groups: [AppGroup]) {
        let top = groups
            .filter { $0.footprintBytes >= config.reportFloorBytes }
            .prefix(12)
            .map {
                SharedState.TopEntry(
                    name: $0.name,
                    bytes: $0.footprintBytes,
                    pids: $0.pids,
                    manageable: config.isManageable($0),
                    suspended: $0.suspended
                )
            }
        SharedState(
            date: sample.date,
            tier: assessment.tier,
            score: assessment.score,
            summary: assessment.summary,
            usedBytes: sample.memoryUsedBytes,
            totalBytes: sample.totalBytes,
            headroomBytes: sample.headroomBytes,
            swapUsedBytes: sample.swapUsedBytes,
            swapTotalBytes: sample.swapTotalBytes,
            swapGrowthBytesPerSec: sample.swapGrowthBytesPerSec,
            kernelPressure: sample.kernelPressure,
            top: Array(top),
            suspended: groups.filter(\.suspended).map(\.name),
            guardRunning: !dryRun,
            lastAction: lastAction
        ).write()
    }
}
