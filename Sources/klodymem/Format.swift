import Foundation
import KlodyMemCore

/// Sortie terminal. Les couleurs sont désactivées si la sortie n'est pas un
/// TTY (redirection, launchd) ou si `NO_COLOR` est défini.
enum Ansi {
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(STDOUT_FILENO) == 1
    }()

    static func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }

    static func dim(_ t: String) -> String { wrap(t, "2") }
    static func bold(_ t: String) -> String { wrap(t, "1") }
    static func green(_ t: String) -> String { wrap(t, "32") }
    static func yellow(_ t: String) -> String { wrap(t, "33") }
    static func orange(_ t: String) -> String { wrap(t, "38;5;208") }
    static func red(_ t: String) -> String { wrap(t, "31") }

    static func tier(_ t: RiskTier) -> String {
        switch t {
        case .ok: return green("sain")
        case .watch: return yellow("surveillance")
        case .high: return orange("ÉLEVÉ")
        case .critical: return red("CRITIQUE")
        }
    }
}

enum Format {
    static func bar(_ ratio: Double, width: Int = 20) -> String {
        let clamped = min(1, max(0, ratio))
        let filled = Int((Double(width) * clamped).rounded())
        return String(repeating: "█", count: filled)
            + Ansi.dim(String(repeating: "░", count: width - filled))
    }

    static func row(_ label: String, _ value: String, indent: Int = 4) -> String {
        let pad = String(repeating: " ", count: indent)
        return pad + label.padding(toLength: 14, withPad: " ", startingAt: 0) + value
    }

    static func status(_ sample: MemorySample, _ assessment: RiskAssessment) -> String {
        var out: [String] = []
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        out.append("")
        out.append("  " + Ansi.bold("KlodyMem") + Ansi.dim("  ·  " + stamp.string(from: sample.date)))
        out.append("")
        out.append(row("Niveau", Ansi.tier(assessment.tier)
            + Ansi.dim(String(format: "   score %.2f", assessment.score))))
        out.append(row("Cause", assessment.summary))
        out.append("")
        out.append(row("RAM", Bytes.human(sample.totalBytes) + Ansi.dim(" installés")))
        out.append(row("  Apps", pad(Bytes.human(sample.appMemoryBytes))
            + "  " + bar(Double(sample.appMemoryBytes) / Double(max(sample.totalBytes, 1)))
            + Ansi.dim("  « mémoire allouée aux applications »")))
        out.append(row("  Wired", pad(Bytes.human(sample.wiredBytes))))
        out.append(row("  Compressée", pad(Bytes.human(sample.compressedBytes))))
        out.append(row("  Caches", pad(Bytes.human(sample.cachedFilesBytes))
            + Ansi.dim("  récupérables")))
        out.append(row("  Libre", pad(Bytes.human(sample.freeBytes))))
        out.append(row("  Utilisée", pad(Bytes.human(sample.memoryUsedBytes))
            + "  " + bar(sample.usedRatio)
            + Ansi.dim("  " + Bytes.percent(sample.usedRatio))))
        out.append(row("  Marge", Ansi.bold(pad(Bytes.human(sample.headroomBytes)))
            + Ansi.dim("  allouable sans swapper")))
        out.append("")

        var swapLine = pad(Bytes.human(sample.swapUsedBytes)) + " / "
            + Bytes.human(sample.swapTotalBytes)
            + Ansi.dim("  " + Bytes.percent(sample.swapRatio))
        if let growth = sample.swapGrowthBytesPerSec, abs(growth) > 1024 * 1024 {
            let arrow = growth > 0 ? "+" : ""
            swapLine += "   " + (growth > 0 ? Ansi.orange(arrow + Bytes.rate(growth))
                                            : Ansi.green(Bytes.rate(growth)))
        }
        out.append(row("Swap", swapLine))
        let vmNote = sample.swapCanGrow
            ? "volume VM : \(Bytes.human(sample.vmVolumeFreeBytes)) libres — le pager peut encore grandir"
            : Ansi.red("volume VM saturé (\(Bytes.human(sample.vmVolumeFreeBytes))) — le swap ne peut plus grandir")
        out.append(row("", Ansi.dim(vmNote)))
        out.append("")
        out.append(row("Noyau", "pression " + sample.kernelPressure.label))
        if let c = sample.compressionsPerSec, let d = sample.decompressionsPerSec, c + d > 0 {
            out.append(row("Compresseur", Ansi.dim(
                String(format: "%.0f compressions/s · %.0f décompressions/s", c, d))))
        }
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func pad(_ s: String) -> String {
        String(repeating: " ", count: max(0, 10 - s.count)) + s
    }

    static func top(_ groups: [AppGroup], config: Config, limit: Int) -> String {
        var out: [String] = []
        out.append("")
        out.append("  " + Ansi.dim("  #    MÉMOIRE   PROC  ÉTAT        APPLICATION"))
        for (i, g) in groups.prefix(limit).enumerated() {
            let flag: String
            if config.isProtected(g) {
                flag = Ansi.dim("protégé")
            } else if g.suspended {
                flag = Ansi.yellow("suspendu")
            } else if config.isManageable(g) {
                flag = Ansi.green("gérable")
            } else {
                flag = Ansi.dim("—")
            }
            let rank = String(i + 1).leftPadded(to: 3)
            let mem = pad(Bytes.human(g.footprintBytes))
            let procs = String(g.pids.count).leftPadded(to: 5)
            let flagPad = String(repeating: " ", count: max(1, 12 - visibleLength(flag)))
            out.append("  " + rank + "  " + mem + procs + "   " + flag + flagPad + g.name)
        }
        out.append("")
        let total = groups.reduce(UInt64(0)) { $0 &+ $1.footprintBytes }
        out.append("  " + Ansi.dim("\(groups.count) groupes · \(Bytes.human(total)) au total"))
        out.append("")
        return out.joined(separator: "\n")
    }

    /// Longueur affichée, séquences ANSI exclues — sinon l'alignement saute
    /// dès qu'une couleur est active.
    static func visibleLength(_ s: String) -> Int {
        var count = 0
        var inEscape = false
        for ch in s {
            if ch == "\u{001B}" { inEscape = true; continue }
            if inEscape { if ch == "m" { inEscape = false }; continue }
            count += 1
        }
        return count
    }
}


extension String {
    /// Alignement à droite sur une largeur fixe.
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
