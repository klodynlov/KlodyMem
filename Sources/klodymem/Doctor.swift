import Darwin
import Foundation
import KlodyMemCore

/// Auto-diagnostic. Vérifie que chaque brique dont dépend le garde répond
/// réellement, plutôt que de supposer qu'elle marche. Sortie : 0 sain,
/// 1 alertes, 2 panne.
func runDoctor(config: Config, sampler: MemorySampler) -> Int32 {
    enum Level { case pass, warn, fail }
    var results: [(Level, String, String)] = []

    func check(_ label: String, _ body: () -> (Level, String)) {
        let (level, detail) = body()
        results.append((level, label, detail))
    }

    check("config") {
        let path = Config.configURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return (.warn, "absente — défauts appliqués (`klodymem config init` pour la créer)")
        }
        do {
            _ = try Config.load()
            return (.pass, path)
        } catch {
            return (.fail, "\(error)")
        }
    }

    check("répertoire d'état") {
        let dir = Config.stateDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".doctor-probe")
            try Data("ok".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
            return (.pass, dir.path + " (inscriptible)")
        } catch {
            return (.fail, "non inscriptible : \(error.localizedDescription)")
        }
    }

    var sample: MemorySample?
    check("échantillonnage RAM") {
        let s = sampler.sample()
        sample = s
        guard s.totalBytes > 0 else { return (.fail, "hw.memsize renvoie 0") }
        guard s.memoryUsedBytes > 0, s.memoryUsedBytes <= s.totalBytes else {
            return (.fail, "décomposition incohérente : utilisée=\(Bytes.human(s.memoryUsedBytes)) "
                + "total=\(Bytes.human(s.totalBytes))")
        }
        return (.pass, "\(Bytes.human(s.totalBytes)) installés · "
            + "\(Bytes.human(s.memoryUsedBytes)) utilisés · marge \(Bytes.human(s.headroomBytes))")
    }

    check("dérivées temporelles") {
        Thread.sleep(forTimeInterval: 0.5)
        let s = sampler.sample()
        guard s.swapGrowthBytesPerSec != nil, s.compressionsPerSec != nil else {
            return (.fail, "les débits restent nil après deux échantillons")
        }
        return (.pass, "swap \(Bytes.rate(s.swapGrowthBytesPerSec)) · "
            + String(format: "%.0f compressions/s", s.compressionsPerSec ?? 0))
    }

    check("swap") {
        guard let s = sample else { return (.fail, "pas d'échantillon") }
        guard s.swapTotalBytes > 0 else {
            return (.warn, "vm.swapusage renvoie 0 — swap désactivé ?")
        }
        let line = "\(Bytes.human(s.swapUsedBytes)) / \(Bytes.human(s.swapTotalBytes)) "
            + "(\(Bytes.percent(s.swapRatio)))"
        return (s.swapRatio > 0.95 && !s.swapCanGrow) ? (.warn, line + " — saturé") : (.pass, line)
    }

    check("volume VM") {
        guard let s = sample else { return (.fail, "pas d'échantillon") }
        guard s.vmVolumeFreeBytes > 0 else {
            return (.warn, "/System/Volumes/VM illisible")
        }
        return s.swapCanGrow
            ? (.pass, "\(Bytes.human(s.vmVolumeFreeBytes)) libres — le pager peut grandir")
            : (.fail, "\(Bytes.human(s.vmVolumeFreeBytes)) libres — le swap ne peut plus grandir")
    }

    var groups: [AppGroup] = []
    check("inventaire process") {
        groups = ProcessInventory.currentGroups()
        guard !groups.isEmpty else { return (.fail, "aucun process lisible") }
        guard let top = groups.first, top.footprintBytes > 0 else {
            return (.fail, "empreintes toutes nulles — proc_pid_rusage refusé ?")
        }
        let mine = groups.filter(\.ownedByCurrentUser).count
        return (.pass, "\(groups.count) groupes · \(mine) à cet utilisateur · "
            + "plus gros : \(top.name) \(Bytes.human(top.footprintBytes))")
    }

    // Mode de panne constaté : écraser le binaire installé avec `cp` invalide
    // sa signature ad-hoc, et macOS tue alors le process au démarrage (137)
    // sans le moindre message. Silencieux et déroutant — donc vérifié ici.
    check("signature du binaire") {
        let path = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-v", "--strict", path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
                ? (.pass, path)
                : (.fail, "signature invalide sur \(path) — resigner : codesign -f -s - \(path)")
        } catch {
            return (.warn, "codesign injoignable : \(error.localizedDescription)")
        }
    }

    check("notifications") {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")
            ? (.pass, "/usr/bin/osascript disponible")
            : (.fail, "osascript introuvable — les notifications ne partiront pas")
    }

    check("liste manageable") {
        guard !config.manageable.isEmpty else {
            return (.warn, "vide — le garde se contentera de notifier")
        }
        let unresolved = config.manageable.filter { entry in
            !groups.contains { $0.name.lowercased() == entry.lowercased() }
        }
        return unresolved.isEmpty
            ? (.pass, config.manageable.joined(separator: ", "))
            : (.warn, "non lancées actuellement : " + unresolved.joined(separator: ", "))
    }

    check("liste protected") {
        let overlap = config.manageable.filter { entry in
            config.protected.contains { $0.lowercased() == entry.lowercased() }
                || Config.hardProtected.contains(where: { $0.lowercased() == entry.lowercased() })
        }
        return overlap.isEmpty
            ? (.pass, "\(Config.hardProtected.count) protections dures + \(config.protected.count) locales")
            : (.fail, "présentes dans les deux listes, protection l'emporte : "
                + overlap.joined(separator: ", "))
    }

    check("agent launchd") {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/com.klody.mem"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                return (.warn, "non installé (deploy/install.sh pour l'activer)")
            }
            let text = String(decoding: data, as: UTF8.self)
            let running = text.contains("state = running")
            return running ? (.pass, "chargé et actif")
                           : (.warn, "chargé mais pas en cours d'exécution")
        } catch {
            return (.warn, "launchctl injoignable : \(error.localizedDescription)")
        }
    }

    check("état publié") {
        guard let state = SharedState.read() else {
            return (.warn, "aucun state.json — le garde n'a jamais tourné")
        }
        return state.isStale
            ? (.warn, "périmé (\(Int(Date().timeIntervalSince(state.date))) s) — garde arrêté ?")
            : (.pass, "frais · niveau \(state.tier.frenchLabel)")
    }

    // Rendu
    print("")
    var failures = 0
    var warnings = 0
    for (level, label, detail) in results {
        let mark: String
        switch level {
        case .pass: mark = Ansi.green("✓")
        case .warn: mark = Ansi.yellow("!"); warnings += 1
        case .fail: mark = Ansi.red("✗"); failures += 1
        }
        print("  \(mark) " + label.padding(toLength: 22, withPad: " ", startingAt: 0)
            + Ansi.dim(detail))
    }
    print("")
    if failures > 0 {
        print("  " + Ansi.red("\(failures) panne(s)") + ", \(warnings) alerte(s)")
    } else if warnings > 0 {
        print("  " + Ansi.yellow("\(warnings) alerte(s)") + ", aucune panne")
    } else {
        print("  " + Ansi.green("tout est sain"))
    }
    print("")
    return failures > 0 ? 2 : (warnings > 0 ? 1 : 0)
}
