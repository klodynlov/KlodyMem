import Foundation

/// Une dimension du risque, notée de 0 à 1. Les composantes sont exposées
/// telles quelles pour que le diagnostic soit lisible : on veut savoir *quoi*
/// est en train de saturer, pas juste « ça va mal ».
public struct RiskComponent: Codable, Sendable {
    public let name: String
    public let score: Double
    public let detail: String
}

public struct RiskAssessment: Codable, Sendable {
    public let tier: RiskTier
    public let score: Double
    public let components: [RiskComponent]

    /// Composantes qui portent réellement le score, les plus fortes d'abord.
    public var drivers: [RiskComponent] {
        components.filter { $0.score >= 0.35 }.sorted { $0.score > $1.score }
    }

    public var summary: String {
        drivers.isEmpty ? "rien à signaler" : drivers.map(\.detail).joined(separator: " · ")
    }
}

public enum RiskModel {

    /// Rampe linéaire bornée : 0 sous `low`, 1 au-dessus de `high`.
    static func ramp(_ value: Double, low: Double, high: Double) -> Double {
        guard high > low else { return value >= high ? 1 : 0 }
        return min(1, max(0, (value - low) / (high - low)))
    }

    /// Le score global est le **maximum** des composantes, pas leur moyenne :
    /// une seule dimension saturée suffit à faire tomber la machine, et une
    /// moyenne la diluerait.
    public static func assess(_ sample: MemorySample, thresholds t: Thresholds) -> RiskAssessment {
        var components: [RiskComponent] = []

        // 1. Verdict du noyau — autoritaire, c'est lui qui déclenche l'alerte.
        let pressureScore: Double
        switch sample.kernelPressure {
        case .normal: pressureScore = 0
        case .warning: pressureScore = 0.65
        case .critical: pressureScore = 1.0
        }
        components.append(RiskComponent(
            name: "pression noyau",
            score: pressureScore,
            detail: "pression noyau \(sample.kernelPressure.label)"
        ))

        // 2. Mémoire utilisée.
        let used = ramp(sample.usedRatio, low: t.watchUsedRatio, high: t.criticalUsedRatio)
        components.append(RiskComponent(
            name: "mémoire utilisée",
            score: used,
            detail: "mémoire utilisée \(Bytes.percent(sample.usedRatio))"
        ))

        // 3. Marge allouable restante — inversée : moins il en reste, pire c'est.
        let headroom: Double
        if sample.headroomBytes <= t.criticalHeadroomBytes {
            headroom = 1
        } else if sample.headroomBytes >= t.highHeadroomBytes {
            headroom = ramp(
                Double(t.highHeadroomBytes) / Double(max(sample.headroomBytes, 1)),
                low: 0.5, high: 1.0
            ) * 0.6
        } else {
            let span = Double(t.highHeadroomBytes - t.criticalHeadroomBytes)
            let over = Double(sample.headroomBytes - t.criticalHeadroomBytes)
            headroom = 0.6 + 0.4 * (1 - over / max(span, 1))
        }
        components.append(RiskComponent(
            name: "marge",
            score: min(1, headroom),
            detail: "marge \(Bytes.human(sample.headroomBytes))"
        ))

        // 4. Occupation du swap, pondérée par la capacité du pager à s'agrandir.
        //
        // Mesuré sur machine saine : le ratio utilisé/total reste à ~96 % en
        // permanence, parce que le pager dimensionne le jeu de swapfiles sur
        // le besoin courant (observé : 64 Gio, puis 32, puis 20 en dix minutes).
        // Le ratio seul ne dit donc rien. Il ne devient un signal que quand le
        // volume VM n'a plus la place d'accueillir un swapfile de plus.
        let swapRaw = ramp(sample.swapRatio, low: t.watchSwapRatio, high: t.criticalSwapRatio)
        let growthRoom = min(1, Double(sample.vmVolumeFreeBytes) / Double(max(t.minVMVolumeFreeBytes, 1)))
        let swap = swapRaw * (1 - 0.75 * growthRoom)
        var swapDetail = "swap \(Bytes.human(sample.swapUsedBytes))/\(Bytes.human(sample.swapTotalBytes))"
        if swapRaw > 0.5, growthRoom > 0.9 { swapDetail += " (extensible, ignoré)" }
        components.append(RiskComponent(name: "swap", score: swap, detail: swapDetail))

        // 5. Croissance du swap, pondérée par la marge restante.
        //
        // La dérivée prédit l'alerte mieux que le niveau absolu, mais seulement
        // quand la marge est déjà mince. Charger un modèle de 35 milliards de
        // paramètres, ou sortir de veille, fait grimper le swap de plusieurs
        // centaines de Mio/s sans que la machine soit en danger : sans cette
        // pondération l'outil crierait au loup à chaque fois.
        if let growth = sample.swapGrowthBytesPerSec, growth > 0 {
            let raw = ramp(
                growth,
                low: t.watchSwapGrowthBytesPerSec,
                high: t.criticalSwapGrowthBytesPerSec
            )
            let scarcity = 1 - min(1, sample.headroomRatio / t.trendHeadroomRatio)
            let trend = raw * scarcity
            var detail = "swap +\(Bytes.rate(growth))"
            if raw > 0.35, scarcity < 0.35 {
                detail += " (marge confortable, ignoré)"
            }
            components.append(RiskComponent(name: "tendance swap", score: trend, detail: detail))
        }

        // 6. Le pager est-il acculé ? Plus de disque = plus de swap possible.
        if sample.vmVolumeFreeBytes > 0, sample.vmVolumeFreeBytes < t.minVMVolumeFreeBytes {
            components.append(RiskComponent(
                name: "disque VM",
                score: 1,
                detail: "volume VM plein (\(Bytes.human(sample.vmVolumeFreeBytes)) libres)"
            ))
        }

        let score = components.map(\.score).max() ?? 0
        var tier: RiskTier
        switch score {
        case ..<0.35: tier = .ok
        case ..<0.62: tier = .watch
        case ..<0.85: tier = .high
        default: tier = .critical
        }

        // Le noyau a le dernier mot : s'il crie « critical », on ne minimise pas.
        if sample.kernelPressure == .critical { tier = .critical }
        else if sample.kernelPressure == .warning, tier < .high { tier = .high }

        return RiskAssessment(tier: tier, score: score, components: components)
    }
}
