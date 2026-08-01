import Darwin
import Foundation
import KlodyMemCore

// MARK: - Analyse des arguments

var argv = Array(CommandLine.arguments.dropFirst())

func takeFlag(_ names: String...) -> Bool {
    for n in names where argv.contains(n) {
        argv.removeAll { $0 == n }
        return true
    }
    return false
}

func takeOption(_ names: String...) -> String? {
    for n in names {
        guard let i = argv.firstIndex(of: n), i + 1 < argv.count else { continue }
        let value = argv[i + 1]
        argv.removeSubrange(i...(i + 1))
        return value
    }
    return nil
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("klodymem: " + message + "\n").utf8))
    exit(2)
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value) else { fail("échec de l'encodage JSON") }
    FileHandle.standardOutput.write(data)
    print()
}

// Doivent être posés avant le premier accès à `Config.configURL`.
if let path = takeOption("--config") { setenv("KLODYMEM_CONFIG", path, 1) }
if let path = takeOption("--state") { setenv("KLODYMEM_STATE", path, 1) }

let asJSON = takeFlag("--json")
let dryRun = takeFlag("--dry-run", "-n")
let assumeYes = takeFlag("--yes", "-y")
let command = argv.first ?? "status"
if !argv.isEmpty { argv.removeFirst() }

let config: Config
do {
    config = try Config.load()
} catch {
    fail("\(error)")
}

let sampler = MemorySampler()

/// Deux échantillons espacés : le premier amorce les compteurs, le second
/// porte les débits. Sans ça, `swapGrowth` est toujours nil au premier appel.
func sampleWithRates(delay: TimeInterval = 0.6) -> MemorySample {
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: delay)
    return sampler.sample()
}

/// Résout un nom d'application vers son groupe. Correspondance exacte d'abord,
/// puis préfixe — pour ne jamais viser la mauvaise app sur une saisie partielle
/// ambiguë.
func resolveGroup(_ needle: String, in groups: [AppGroup]) throws -> AppGroup {
    let lower = needle.lowercased()
    if let exact = groups.first(where: { $0.name.lowercased() == lower }) { return exact }
    if let pid = pid_t(needle), let byPID = groups.first(where: { $0.pids.contains(pid) }) {
        return byPID
    }
    let matches = groups.filter { $0.name.lowercased().hasPrefix(lower) }
    if matches.count == 1 { return matches[0] }
    if matches.count > 1 {
        throw KlodyMemError.usage(
            "« \(needle) » est ambigu : " + matches.map(\.name).joined(separator: ", ")
        )
    }
    // Les apps système ne sont pas dans l'inventaire : `proc_pid_rusage` les
    // refuse sans privilèges. Dire « introuvable » serait trompeur — elles
    // tournent, elles sont simplement hors de portée, et protégées.
    if Config.hardProtected.contains(where: { $0.lowercased() == lower }) {
        throw KlodyMemError.protectedTarget(needle)
    }
    throw KlodyMemError.notFound(needle)
}

/// Confirmation avant une action manuelle sur une cible qui n'est pas dans
/// `manageable`. Sans ce garde-fou, une faute de frappe gèle l'IDE de
/// l'utilisateur — constaté en test.
func confirmUnlisted(_ group: AppGroup, kind: ActionKind) -> Bool {
    if assumeYes || kind == .resume { return true }
    if config.isManageable(group) { return true }

    let detail = "\(group.name) — \(Bytes.human(group.footprintBytes)), "
        + "\(group.pids.count) process"
    guard isatty(STDIN_FILENO) == 1 else {
        FileHandle.standardError.write(Data((
            "klodymem: \(group.name) n'est pas dans `manageable`. "
            + "Ajouter --yes pour agir sans confirmation.\n"
        ).utf8))
        return false
    }
    print("\(kind.frenchLabel.capitalized) \(detail) ?")
    if kind == .quit || kind == .kill {
        print("  " + Ansi.yellow("Le travail non enregistré sera perdu."))
    }
    print("  Confirmer [o/N] ", terminator: "")
    fflush(stdout)
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return answer == "o" || answer == "oui" || answer == "y" || answer == "yes"
}

// MARK: - Commandes

switch command {

case "status", "st":
    let sample = sampleWithRates()
    let assessment = RiskModel.assess(sample, thresholds: config.thresholds)
    if asJSON {
        struct Payload: Encodable {
            let sample: MemorySample
            let assessment: RiskAssessment
        }
        emitJSON(Payload(sample: sample, assessment: assessment))
    } else {
        print(Format.status(sample, assessment))
    }
    exit(assessment.tier >= .high ? 1 : 0)

case "top":
    let limit = Int(takeOption("-n", "--limit") ?? "15") ?? 15
    let groups = ProcessInventory.currentGroups()
        .filter { $0.footprintBytes >= config.reportFloorBytes }
    if asJSON {
        emitJSON(groups)
    } else {
        print(Format.top(groups, config: config, limit: limit))
    }

case "watch":
    let interval = Double(takeOption("-i", "--interval") ?? "") ?? config.pollSeconds
    var cfg = config
    cfg.pollSeconds = interval
    // `watch` observe sans jamais agir : c'est `guard` qui a le droit d'agir.
    cfg.actions.suspendAtHigh = false
    cfg.actions.quitAtCritical = false
    cfg.actions.notify = false
    let guardian = Guardian(config: cfg, dryRun: true)
    guardian.onSample = { sample, assessment, groups in
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        print(Format.status(sample, assessment))
        print(Format.top(groups.filter { $0.footprintBytes >= cfg.reportFloorBytes },
                         config: cfg, limit: 8))
        print("  " + Ansi.dim("Ctrl-C pour quitter · rafraîchi toutes les \(Int(interval)) s"))
    }
    guardian.run()

case "guard":
    let guardian = Guardian(config: config, dryRun: dryRun)
    let mode = dryRun ? "simulation" : "actif"
    print("klodymem guard démarré (\(mode)) — sondage toutes les \(Int(config.pollSeconds)) s")
    if config.manageable.isEmpty {
        print("  note : `manageable` est vide → notifications seulement, aucune action.")
    }
    fflush(stdout)
    guardian.run()

case "reserve":
    guard let raw = argv.first, let target = Bytes.parse(raw) else {
        fail("usage : klodymem reserve <taille>   (ex. « 40G »)")
    }
    let sample = sampleWithRates(delay: 0.2)
    let groups = ProcessInventory.currentGroups()
    let reclaimer = Reclaimer(config: config, dryRun: dryRun)
    let plan = reclaimer.plan(target: target, sample: sample, groups: groups)

    print("")
    print("  Cible          \(Bytes.human(target)) de marge")
    print("  Actuel         \(Bytes.human(plan.startingHeadroom))")
    if plan.startingHeadroom >= target {
        print("  " + Ansi.green("Rien à faire — la marge est déjà suffisante."))
        print("")
        exit(0)
    }
    if plan.steps.isEmpty {
        print("  " + Ansi.red("Aucun candidat.") + " Ajoutez des apps à `manageable` dans "
            + Config.configURL.path)
        print("")
        exit(1)
    }
    print("  Plan")
    for step in plan.steps {
        print("    · \(step.kind.frenchLabel) \(step.group.name) "
            + Ansi.dim("(\(Bytes.human(step.group.footprintBytes)))"))
    }
    print("  Projeté        \(Bytes.human(plan.projectedHeadroom))"
        + (plan.sufficient ? "" : Ansi.yellow("  — insuffisant, mais on fait au mieux")))
    print("")

    let results = reclaimer.execute(plan, sampler: sampler)
    for r in results {
        let mark = r.succeeded ? Ansi.green("✓") : Ansi.red("✗")
        print("  \(mark) \(r.kind.frenchLabel) \(r.target) — \(r.message)")
    }
    let after = sampler.sample()
    print("")
    print("  Marge finale   \(Bytes.human(after.headroomBytes))")
    print("")
    exit(after.headroomBytes >= target ? 0 : 1)

case "suspend", "resume", "quit", "kill":
    guard let needle = argv.first else { fail("usage : klodymem \(command) <application|pid>") }
    let groups = ProcessInventory.currentGroups()
    do {
        let group = try resolveGroup(needle, in: groups)
        let kind = ActionKind(rawValue: command)!
        guard confirmUnlisted(group, kind: kind) else {
            print("annulé")
            exit(1)
        }
        let result = Actuator(config: config, dryRun: dryRun).perform(kind, on: group)
        if asJSON {
            emitJSON(result)
        } else {
            let mark = result.succeeded ? Ansi.green("✓") : Ansi.red("✗")
            print("\(mark) \(kind.frenchLabel) \(result.target) "
                + "[\(result.pids.map(String.init).joined(separator: " "))] — \(result.message)")
        }
        exit(result.succeeded ? 0 : 1)
    } catch {
        fail("\(error)")
    }

case "history":
    let limit = Int(takeOption("-n", "--limit") ?? "20") ?? 20
    let entries = HistoryLog().tail(limit)
    if asJSON {
        emitJSON(entries)
    } else if entries.isEmpty {
        print("  aucun historique — le garde n'a encore rien journalisé")
    } else {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        print("")
        for e in entries {
            print("  \(df.string(from: e.date))  "
                + Ansi.tier(e.tier).padding(toLength: 24, withPad: " ", startingAt: 0)
                + "marge \(Bytes.human(e.headroomBytes))  "
                + "swap \(Bytes.human(e.swapUsedBytes))  "
                + Ansi.dim(e.action ?? ""))
        }
        print("")
    }

case "config":
    switch argv.first ?? "show" {
    case "path":
        print(Config.configURL.path)
    case "init":
        if FileManager.default.fileExists(atPath: Config.configURL.path) {
            fail("le fichier existe déjà : \(Config.configURL.path)")
        }
        do {
            try Config().save()
            print("écrit : \(Config.configURL.path)")
        } catch {
            fail("\(error)")
        }
    default:
        emitJSON(config)
    }

case "doctor":
    exit(runDoctor(config: config, sampler: sampler))

case "help", "--help", "-h":
    printUsage()

default:
    FileHandle.standardError.write(Data("klodymem: commande inconnue « \(command) »\n".utf8))
    printUsage()
    exit(2)
}
