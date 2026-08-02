import AppKit
import Darwin
import Foundation

public enum ActionKind: String, Codable, Sendable {
    case suspend
    case resume
    case quit
    case kill

    public var frenchLabel: String {
        switch self {
        case .suspend: return "suspendre"
        case .resume: return "reprendre"
        case .quit: return "quitter"
        case .kill: return "forcer à quitter"
        }
    }
}

public struct ActionResult: Codable, Sendable {
    public let kind: ActionKind
    public let target: String
    public let pids: [pid_t]
    public let succeeded: Bool
    public let message: String
    public let reclaimedBytes: UInt64
}

/// Exécute les actions sur les process, avec les garde-fous.
///
/// Trois refus non négociables, appliqués avant tout envoi de signal :
/// process protégé, process d'un autre utilisateur, PID système (< 100).
public struct Actuator {
    public let config: Config
    /// Mode simulation : décide et journalise, n'envoie aucun signal.
    public let dryRun: Bool

    public init(config: Config, dryRun: Bool = false) {
        self.config = config
        self.dryRun = dryRun
    }

    public func validate(_ group: AppGroup, kind: ActionKind) throws {
        if kind == .resume { return } // reprendre est toujours sûr
        if config.isProtected(group) { throw KlodyMemError.protectedTarget(group.name) }
        guard group.ownedByCurrentUser else {
            throw KlodyMemError.notPermitted("\(group.name) n'appartient pas à cet utilisateur")
        }
        guard group.pids.allSatisfy({ $0 >= 100 }) else {
            throw KlodyMemError.notPermitted("\(group.name) contient un PID système")
        }
        if kind == .kill, !config.actions.allowForceKill {
            throw KlodyMemError.notPermitted(
                "SIGKILL désactivé (actions.allowForceKill = false)"
            )
        }
    }

    @discardableResult
    public func perform(_ kind: ActionKind, on group: AppGroup) -> ActionResult {
        do {
            try validate(group, kind: kind)
        } catch {
            return ActionResult(
                kind: kind, target: group.name, pids: group.pids,
                succeeded: false, message: "\(error)", reclaimedBytes: 0
            )
        }

        if dryRun {
            return ActionResult(
                kind: kind, target: group.name, pids: group.pids, succeeded: true,
                message: "simulation — aucune action envoyée",
                reclaimedBytes: kind == .resume ? 0 : group.footprintBytes
            )
        }

        switch kind {
        case .suspend: return signalAll(SIGSTOP, group, kind: kind)
        case .resume: return signalAll(SIGCONT, group, kind: kind)
        case .kill: return signalAll(SIGKILL, group, kind: kind)
        case .quit: return quit(group)
        }
    }

    private func signalAll(_ sig: Int32, _ group: AppGroup, kind: ActionKind) -> ActionResult {
        var failures: [String] = []
        var touched: [pid_t] = []
        // SIGSTOP en ordre inverse d'empreinte : on gèle les helpers avant le
        // leader, sinon celui-ci peut relancer un enfant pendant l'opération.
        let order = kind == .resume ? group.pids : group.pids.reversed().map { $0 }
        for pid in order {
            if Darwin.kill(pid, sig) == 0 {
                touched.append(pid)
            } else if errno != ESRCH { // ESRCH = déjà mort, ce n'est pas un échec
                failures.append("pid \(pid): \(String(cString: strerror(errno)))")
            }
        }
        let ok = failures.isEmpty && !touched.isEmpty
        return ActionResult(
            kind: kind, target: group.name, pids: touched, succeeded: ok,
            message: failures.isEmpty ? "\(touched.count) process" : failures.joined(separator: "; "),
            reclaimedBytes: kind == .resume ? 0 : (ok ? group.footprintBytes : 0)
        )
    }

    /// Arrêt propre : `NSRunningApplication.terminate()` pour les bundles
    /// (l'app peut sauvegarder et refuser), SIGTERM sinon.
    ///
    /// La demande d'arrêt n'est **pas** l'arrêt. `terminate()` poste un Apple
    /// Event et rend la main aussitôt ; l'application peut l'ignorer, ouvrir un
    /// dialogue, ou traîner. Constaté en production : le garde comptait un
    /// succès, respectait son cooldown, et la mémoire n'était jamais rendue.
    /// On attend donc la disparition effective des process avant de conclure.
    private func quit(_ group: AppGroup) -> ActionResult {
        let grace = config.actions.quitGraceSeconds

        guard let app = NSRunningApplication(processIdentifier: group.leaderPID) else {
            let sent = signalAll(SIGTERM, group, kind: .quit)
            guard sent.succeeded else { return sent }
            return verdict(for: group, grace: grace)
        }

        guard app.terminate() else {
            return ActionResult(
                kind: .quit, target: group.name, pids: group.pids, succeeded: false,
                message: "l'application a refusé la demande d'arrêt", reclaimedBytes: 0
            )
        }
        return verdict(for: group, grace: grace)
    }

    private func verdict(for group: AppGroup, grace: TimeInterval) -> ActionResult {
        let survivors = Actuator.waitForExit(group.pids, timeout: grace)
        guard survivors.isEmpty else {
            return ActionResult(
                kind: .quit, target: group.name, pids: survivors, succeeded: false,
                message: "toujours en vie après \(Int(grace)) s — arrêt refusé ou différé",
                reclaimedBytes: 0
            )
        }
        return ActionResult(
            kind: .quit, target: group.name, pids: group.pids, succeeded: true,
            message: "arrêté", reclaimedBytes: group.footprintBytes
        )
    }

    /// Attend la disparition des PID, et renvoie ceux qui ont survécu.
    /// `kill(pid, 0)` ne signale rien : il teste seulement l'existence.
    static func waitForExit(_ pids: [pid_t], timeout: TimeInterval) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = pids
        while !remaining.isEmpty, Date() < deadline {
            remaining = remaining.filter { Darwin.kill($0, 0) == 0 || errno == EPERM }
            if remaining.isEmpty { break }
            usleep(150_000)
        }
        return remaining
    }
}

/// Libère de la mémoire jusqu'à atteindre une marge cible, en escaladant du
/// moins destructif au plus destructif et en s'arrêtant dès que la cible est
/// atteinte.
public struct Reclaimer {
    public let config: Config
    public let actuator: Actuator

    public init(config: Config, dryRun: Bool = false) {
        self.config = config
        self.actuator = Actuator(config: config, dryRun: dryRun)
    }

    public struct Plan: Sendable {
        public let targetBytes: UInt64
        public let startingHeadroom: UInt64
        public let steps: [(group: AppGroup, kind: ActionKind)]
        public let projectedHeadroom: UInt64
        public var sufficient: Bool { projectedHeadroom >= targetBytes }
    }

    /// Construit le plan sans rien exécuter. Les candidats sont les apps
    /// `manageable`, les plus grosses d'abord ; on suspend d'abord, on ne
    /// quitte que si suspendre ne suffit pas.
    public func plan(target: UInt64, sample: MemorySample, groups: [AppGroup]) -> Plan {
        let candidates = groups
            .filter { config.isManageable($0) && !$0.suspended }
            .sorted { $0.footprintBytes > $1.footprintBytes }

        var headroom = sample.headroomBytes
        var steps: [(AppGroup, ActionKind)] = []

        // Passe 1 : suspendre. Réversible, la mémoire part au compresseur/swap.
        for group in candidates where headroom < target {
            steps.append((group, .suspend))
            headroom &+= group.footprintBytes / 2 // suspendre ne libère pas tout
        }
        // Passe 2 : quitter, si suspendre n'a pas suffi.
        if headroom < target, config.actions.quitAtCritical {
            for group in candidates where headroom < target {
                steps.removeAll { $0.0.key == group.key }
                steps.append((group, .quit))
                headroom &+= group.footprintBytes
            }
        }

        return Plan(
            targetBytes: target,
            startingHeadroom: sample.headroomBytes,
            steps: steps.map { (group: $0.0, kind: $0.1) },
            projectedHeadroom: headroom
        )
    }

    /// Exécute le plan, en réévaluant la marge réelle après chaque étape pour
    /// s'arrêter au plus tôt.
    public func execute(_ plan: Plan, sampler: MemorySampler) -> [ActionResult] {
        var results: [ActionResult] = []
        for step in plan.steps {
            results.append(actuator.perform(step.kind, on: step.group))
            usleep(400_000) // laisser le pager réagir avant de remesurer
            if sampler.sample().headroomBytes >= plan.targetBytes { break }
        }
        return results
    }
}
