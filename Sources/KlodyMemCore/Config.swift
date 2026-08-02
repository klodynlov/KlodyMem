import Foundation

extension KeyedDecodingContainer {
    /// Clé absente ou du mauvais type : on retombe sur la valeur par défaut.
    ///
    /// Le `Codable` synthétisé exige au contraire *toutes* les clés, valeurs
    /// par défaut comprises. Ajouter un réglage rendait donc illisibles toutes
    /// les configs déjà écrites — constaté en production, l'agent est parti en
    /// boucle de redémarrage.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }
}

/// Seuils du modèle de risque. Toutes les valeurs sont surchargeables depuis
/// `~/.config/klodymem/config.json`.
public struct Thresholds: Codable, Sendable, Equatable {
    /// Fraction de RAM « utilisée » (app + wired + compressée).
    public var watchUsedRatio: Double = 0.75
    public var highUsedRatio: Double = 0.88
    public var criticalUsedRatio: Double = 0.95

    /// Marge réellement allouable (libre + caches récupérables).
    public var highHeadroomBytes: UInt64 = 8 << 30
    public var criticalHeadroomBytes: UInt64 = 3 << 30

    /// Occupation du swap. Pondérée à la baisse tant que le pager peut encore
    /// agrandir les swapfiles.
    public var watchSwapRatio: Double = 0.50
    public var highSwapRatio: Double = 0.80
    public var criticalSwapRatio: Double = 0.95

    /// Croissance du swap : c'est la dérivée qui prédit l'alerte système, pas
    /// le niveau absolu.
    public var watchSwapGrowthBytesPerSec: Double = 8 * 1024 * 1024
    public var criticalSwapGrowthBytesPerSec: Double = 80 * 1024 * 1024
    /// Au-dessus de cette fraction de marge, la croissance du swap est
    /// considérée comme du travail normal et non comme un signal de danger.
    public var trendHeadroomRatio: Double = 0.25

    /// Sous ce seuil de place libre sur `/System/Volumes/VM`, le pager ne peut
    /// plus agrandir le swap : c'est la configuration qui produit le dialogue
    /// « forcer à quitter ».
    public var minVMVolumeFreeBytes: UInt64 = 16 << 30

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Thresholds()
        watchUsedRatio = c.value(.watchUsedRatio, d.watchUsedRatio)
        highUsedRatio = c.value(.highUsedRatio, d.highUsedRatio)
        criticalUsedRatio = c.value(.criticalUsedRatio, d.criticalUsedRatio)
        highHeadroomBytes = c.value(.highHeadroomBytes, d.highHeadroomBytes)
        criticalHeadroomBytes = c.value(.criticalHeadroomBytes, d.criticalHeadroomBytes)
        watchSwapRatio = c.value(.watchSwapRatio, d.watchSwapRatio)
        highSwapRatio = c.value(.highSwapRatio, d.highSwapRatio)
        criticalSwapRatio = c.value(.criticalSwapRatio, d.criticalSwapRatio)
        watchSwapGrowthBytesPerSec = c.value(.watchSwapGrowthBytesPerSec, d.watchSwapGrowthBytesPerSec)
        criticalSwapGrowthBytesPerSec = c.value(.criticalSwapGrowthBytesPerSec, d.criticalSwapGrowthBytesPerSec)
        trendHeadroomRatio = c.value(.trendHeadroomRatio, d.trendHeadroomRatio)
        minVMVolumeFreeBytes = c.value(.minVMVolumeFreeBytes, d.minVMVolumeFreeBytes)
    }
}

/// Escalade autorisée. Volontairement conservatrice par défaut : le garde
/// n'agit sur un process que s'il figure dans `manageable`.
public struct ActionPolicy: Codable, Sendable, Equatable {
    /// Notification système quand le niveau monte.
    public var notify: Bool = true
    /// Suspendre (SIGSTOP) les apps de `manageable` au niveau « élevé ».
    public var suspendAtHigh: Bool = false
    /// Quitter proprement les apps de `manageable` au niveau « critique ».
    public var quitAtCritical: Bool = false
    /// SIGKILL. Jamais activé par défaut — perte de données garantie.
    public var allowForceKill: Bool = false
    /// Relancer (SIGCONT) ce qui a été suspendu dès le retour à « sain ».
    public var autoResume: Bool = true
    /// Délai minimal entre deux actions sur la même cible.
    public var cooldownSeconds: Double = 120
    /// Temps laissé à une application pour honorer une demande d'arrêt avant
    /// de considérer qu'elle l'a refusée.
    public var quitGraceSeconds: Double = 5
    /// Nombre d'échantillons consécutifs au-dessus du seuil avant d'agir.
    public var confirmSamples: Int = 3

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ActionPolicy()
        notify = c.value(.notify, d.notify)
        suspendAtHigh = c.value(.suspendAtHigh, d.suspendAtHigh)
        quitAtCritical = c.value(.quitAtCritical, d.quitAtCritical)
        allowForceKill = c.value(.allowForceKill, d.allowForceKill)
        autoResume = c.value(.autoResume, d.autoResume)
        cooldownSeconds = c.value(.cooldownSeconds, d.cooldownSeconds)
        quitGraceSeconds = c.value(.quitGraceSeconds, d.quitGraceSeconds)
        confirmSamples = c.value(.confirmSamples, d.confirmSamples)
    }
}

public struct Config: Codable, Sendable, Equatable {
    public var pollSeconds: Double = 5
    public var thresholds = Thresholds()
    public var actions = ActionPolicy()

    /// Jamais suspendu, jamais quitté, jamais tué — quoi qu'il arrive.
    /// Fusionné avec `Config.hardProtected`, qui n'est pas surchargeable.
    public var protected: [String] = []

    /// Seules ces apps peuvent être suspendues ou quittées automatiquement.
    /// Correspondance sur le nom affiché ou le chemin du bundle, insensible à
    /// la casse. Vide = le garde se contente de notifier.
    public var manageable: [String] = []

    /// Ignorer les groupes plus petits que ça dans les rapports.
    public var reportFloorBytes: UInt64 = 128 << 20

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        pollSeconds = c.value(.pollSeconds, d.pollSeconds)
        thresholds = c.value(.thresholds, d.thresholds)
        actions = c.value(.actions, d.actions)
        protected = c.value(.protected, d.protected)
        manageable = c.value(.manageable, d.manageable)
        reportFloorBytes = c.value(.reportFloorBytes, d.reportFloorBytes)
    }

    /// Process dont la suspension ou l'arrêt casse la session. Non
    /// surchargeable depuis la config : c'est le garde-fou de dernier recours.
    public static let hardProtected: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "SystemUIServer",
        "Dock", "Finder", "coreaudiod", "cfprefsd", "distnoted", "opendirectoryd",
        "securityd", "syslogd", "notifyd", "diskarbitrationd", "powerd", "kextd",
        "Terminal", "iTerm2", "Ghostty", "Alacritty", "kitty", "WezTerm",
        "klodymem", "klodymem-bar", "KlodyMem",
    ]

    // MARK: - Persistance

    /// Chemins redirigeables par variable d'environnement.
    ///
    /// Indispensable pour éprouver une politique sans toucher à celle qui
    /// tourne : sans ça, tester le scénario critique imposerait d'éditer la
    /// config de production, et le garde réel appliquerait la politique de
    /// test aux vraies applications.
    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["KLODYMEM_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/klodymem/config.json")
    }

    public static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KLODYMEM_STATE"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/klodymem")
    }

    /// Charge la config, ou renvoie les défauts si le fichier est absent.
    /// Un fichier illisible est signalé plutôt qu'ignoré en silence.
    public static func load() throws -> Config {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Config.self, from: data)
        } catch {
            throw KlodyMemError.badConfig(path: url.path, underlying: error)
        }
    }

    /// Charge en tolérant l'échec — utilisé par la barre de menus, qui ne doit
    /// jamais refuser de démarrer à cause d'une virgule en trop.
    public static func loadOrDefault() -> Config {
        (try? load()) ?? Config()
    }

    public func save() throws {
        let url = Config.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: - Décisions par groupe

    public func isProtected(_ group: AppGroup) -> Bool {
        if Config.hardProtected.contains(group.name) { return true }
        if group.pids.contains(getpid()) { return true }
        let needle = group.name.lowercased()
        let bundle = (group.bundlePath ?? "").lowercased()
        for entry in protected {
            let e = entry.lowercased()
            if e.isEmpty { continue }
            if needle == e || bundle == e || bundle.hasSuffix("/\(e).app") { return true }
        }
        return false
    }

    public func isManageable(_ group: AppGroup) -> Bool {
        guard group.ownedByCurrentUser, !isProtected(group) else { return false }
        let needle = group.name.lowercased()
        let bundle = (group.bundlePath ?? "").lowercased()
        for entry in manageable {
            let e = entry.lowercased()
            if e.isEmpty { continue }
            if needle == e || bundle == e || bundle.hasSuffix("/\(e).app") { return true }
        }
        return false
    }
}

public enum KlodyMemError: Error, CustomStringConvertible {
    case badConfig(path: String, underlying: Error)
    case protectedTarget(String)
    case notFound(String)
    case notPermitted(String)
    case usage(String)

    public var description: String {
        switch self {
        case let .badConfig(path, underlying):
            return "config illisible (\(path)) : \(underlying)"
        case let .protectedTarget(name):
            return "« \(name) » est protégé : action refusée"
        case let .notFound(name):
            return "introuvable : \(name)"
        case let .notPermitted(name):
            return "non autorisé : \(name)"
        case let .usage(message):
            return message
        }
    }
}
