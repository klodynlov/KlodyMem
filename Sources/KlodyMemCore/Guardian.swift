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
    private var config: Config
    private let sampler: MemorySampler
    private var notifier: Notifier
    private let history: HistoryLog
    private var actuator: Actuator
    private let dryRun: Bool
    private var configStamp: Date?

    private var streak: (tier: RiskTier, count: Int) = (.ok, 0)
    private var actedTier: RiskTier = .ok
    /// Clé « cible|action » : le cooldown d'un `suspend` ne doit pas bloquer
    /// l'escalade vers un `quit`, qui est une action différente et plus grave.
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
        self.configStamp = Guardian.configModified()
    }

    /// Relit la config quand son fichier change.
    ///
    /// Sans ça, éditer `config.json` ne produit rien tant que l'agent n'a pas
    /// été redémarré — et rien ne le signale. Le seuil de confirmation est
    /// remis à zéro : la nouvelle politique ne doit pas hériter d'une série
    /// d'échantillons décidée sous l'ancienne.
    private func reloadConfigIfChanged() {
        let stamp = Guardian.configModified()
        guard stamp != configStamp else { return }
        configStamp = stamp
        guard let fresh = try? Config.load() else {
            // Config cassée : on garde la précédente plutôt que de retomber
            // silencieusement sur des défauts que l'utilisateur n'a pas voulus.
            print("config illisible, l'ancienne reste active")
            fflush(stdout)
            return
        }
        config = fresh
        notifier = Notifier(enabled: fresh.actions.notify)
        actuator = Actuator(config: fresh, dryRun: dryRun)
        streak = (streak.tier, 0)
        print("config rechargée — manageable: "
            + (fresh.manageable.isEmpty ? "(vide)"
               : fresh.manageable.map { "\($0.name)→\($0.maxAction.rawValue)" }
                   .joined(separator: ", ")))
        fflush(stdout)
    }

    private static func configModified() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: Config.configURL.path)[.modificationDate] as? Date
    }

    /// Un tour de boucle. Séparé de `run()` pour rester testable.
    @discardableResult
    public func tick() -> (MemorySample, RiskAssessment, [AppGroup]) {
        reloadConfigIfChanged()
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

    // MARK: - Décision

    /// Ce que la politique commande à un niveau donné. Pure et sans effet de
    /// bord, pour être testable — c'est le chemin le plus dangereux du code.
    ///
    /// L'échelle est **exclusive** : au niveau critique on quitte, on ne
    /// suspend pas d'abord. Faire les deux dans le même tour gèlerait la cible
    /// avant de lui demander de s'arrêter, et la demande serait perdue.
    static func plannedActions(
        tier: RiskTier,
        groups: [AppGroup],
        config: Config,
        suspendedKeys: Set<String>
    ) -> [(group: AppGroup, kind: ActionKind)] {
        return groups.compactMap { group in
            guard let cap = config.maxAction(for: group) else { return nil }

            // Quitter, si la politique l'arme et que la cible l'autorise. Y
            // compris une cible déjà gelée : suspendre n'a rendu aucune
            // mémoire, seulement laissé le pager la récupérer.
            if tier == .critical, config.actions.quitAtCritical, cap == .quit {
                return (group: group, kind: ActionKind.quit)
            }
            // Sinon geler — y compris au niveau critique pour une cible
            // plafonnée à `suspend`, qui reste la meilleure chose à en faire.
            if tier >= .high, config.actions.suspendAtHigh,
               !group.suspended, !suspendedKeys.contains(group.key) {
                return (group: group, kind: ActionKind.suspend)
            }
            return nil
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

        // Les plus gros d'abord, et on s'arrête dès que la pression retombe.
        //
        // Geler d'un bloc toutes les cibles éligibles fige toute la pile locale
        // pour un pic que la première aurait absorbé. L'action doit être
        // proportionnée : une cible, on remesure, on continue seulement si
        // c'est encore nécessaire.
        let planned = Guardian.plannedActions(
            tier: tier, groups: groups, config: config, suspendedKeys: suspendedKeys
        ).sorted { $0.group.footprintBytes > $1.group.footprintBytes }

        for (index, step) in planned.enumerated() {
            let (group, kind) = (step.group, step.kind)
            guard allowedNow(group.key, kind) else { continue }
            if index > 0, !stillNeedsAction(atLeast: tier) {
                log("  pression retombée — \(planned.count - index) cible(s) épargnée(s)")
                break
            }
            // Un process gelé n'exécute plus rien : il ne traitera jamais une
            // demande d'arrêt. Le réveiller d'abord, sinon `quit` reste sans
            // effet et la mémoire n'est jamais rendue.
            if kind == .quit, group.suspended || suspendedKeys.contains(group.key) {
                _ = actuator.perform(.resume, on: group)
                suspendedKeys.remove(group.key)
            }
            let result = actuator.perform(kind, on: group)
            guard result.succeeded else {
                log("  ✗ \(kind.rawValue):\(group.name) — \(result.message)")
                continue
            }
            if kind == .suspend { suspendedKeys.insert(group.key) }
            markActed(group.key, kind)
            performed.append("\(kind.rawValue):\(group.name)")
        }

        lastAction = performed.isEmpty ? nil : performed.joined(separator: " ")
        log("niveau \(tier.frenchLabel) — \(assessment.summary)")
        for entry in performed { log("  → \(entry)\(dryRun ? "  (simulation)" : "")") }
        if performed.isEmpty, tier >= .high { log("  → aucune cible applicable") }
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
        // Tracer la sortie avant tout retour anticipé : sans ça l'opérateur
        // voit l'escalade dans guard.log et jamais le retour à la normale.
        log("retour au niveau sain")
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
        if !resumed.isEmpty { log("  → reprise de " + resumed.joined(separator: ", ")) }
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

    /// Trace horodatée sur stdout — c'est ce que launchd capte dans
    /// `guard.log`, et ce qui rend `guard --dry-run` observable.
    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("[\(stamp)] \(message)")
        fflush(stdout)
    }

    /// La pression justifie-t-elle encore d'agir ? Remesurée après chaque
    /// action, avec un court délai pour laisser le pager récupérer les pages
    /// de la cible qu'on vient de geler.
    private func stillNeedsAction(atLeast tier: RiskTier) -> Bool {
        usleep(400_000)
        let fresh = sampler.sample()
        return RiskModel.assess(fresh, thresholds: config.thresholds).tier >= tier
    }

    private func allowedNow(_ key: String, _ kind: ActionKind) -> Bool {
        guard let last = lastActionAt["\(key)|\(kind.rawValue)"] else { return true }
        return Date().timeIntervalSince(last) >= config.actions.cooldownSeconds
    }

    private func markActed(_ key: String, _ kind: ActionKind) {
        lastActionAt["\(key)|\(kind.rawValue)"] = Date()
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
