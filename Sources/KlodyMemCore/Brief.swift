import Foundation

/// Résumé d'une ligne, destiné à être injecté au démarrage d'une session
/// (hook `SessionStart`, bannière de shell, barre de statut).
///
/// Contrainte de conception : ne jamais coûter d'attention quand tout va bien,
/// et devenir explicite dès que ça se tend. Une ligne au niveau `sain`, une
/// ligne de plus dès `surveillance` avec les responsables et l'action à mener.
public enum Brief {

    public static func lines(
        sample: MemorySample,
        assessment: RiskAssessment,
        groups: [AppGroup],
        state: SharedState?,
        config: Config
    ) -> [String] {
        var head = "klodymem: "
        head += assessment.tier == .ok ? "sain" : assessment.tier.frenchLabel.uppercased()
        head += " · marge \(Bytes.human(sample.headroomBytes))"
        head += " / \(Bytes.human(sample.totalBytes))"

        if let growth = sample.swapGrowthBytesPerSec, growth > 8 * 1024 * 1024 {
            head += " · swap +\(Bytes.rate(growth))"
        }
        head += " · " + guardSummary(state: state, config: config)

        guard assessment.tier > .ok else { return [head] }

        var out = [head]
        out.append("  cause: \(assessment.summary)")

        let top = groups
            .filter { $0.footprintBytes >= config.reportFloorBytes }
            .prefix(3)
            .map { "\($0.name) \(Bytes.human($0.footprintBytes))" }
        if !top.isEmpty {
            out.append("  plus gros: " + top.joined(separator: ", "))
        }
        // Proposer une cible atteignable plutôt qu'un chiffre rond arbitraire :
        // la moitié de la RAM est une marge confortable pour un gros job.
        let suggestion = max(sample.totalBytes / 2, sample.headroomBytes + (8 << 30))
        // Jeton compact, pas la forme affichée : la commande doit se coller
        // telle quelle dans un terminal.
        let target = "\(max(1, suggestion / (1 << 30)))G"
        out.append("  libérer: klodymem reserve \(target)   ·   détail: klodymem top")
        return out
    }

    static func guardSummary(state: SharedState?, config: Config) -> String {
        guard let state, !state.isStale else { return "garde inactif" }
        guard !config.manageable.isEmpty else { return "garde actif (notification seule)" }
        var s = "garde actif (" + config.manageable.joined(separator: ", ")
        var armed: [String] = []
        if config.actions.suspendAtHigh { armed.append("suspend") }
        if config.actions.quitAtCritical { armed.append("quit") }
        s += armed.isEmpty ? " en liste, aucune action armée" : " → " + armed.joined(separator: "+")
        return s + ")"
    }
}
