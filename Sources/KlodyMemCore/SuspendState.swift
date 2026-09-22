import Foundation

/// Groupes actuellement gelés (SIGSTOP) par le garde, persistés sur disque.
///
/// Sans ce fichier, l'ensemble des cibles gelées ne vivait qu'en mémoire : un
/// redémarrage du daemon en plein gel (mise à jour, `launchctl bootout`,
/// crash) oubliait qui avait été suspendu. Au retour au niveau sain, le garde
/// journalisait « recovered » sans rien réveiller — sept épisodes
/// `suspend:mlx_server_guarded.py` sans `resume:` dans l'historique, et
/// aucune garantie que les process aient jamais reçu SIGCONT.
///
/// Le fichier est réécrit atomiquement à chaque changement et supprimé quand
/// plus rien n'est gelé. Au démarrage, `Guardian` le relit et réveille ce qui
/// est encore réellement en STOP (cf. `Guardian.orphanedSuspensions`).
public struct SuspendState: Codable, Sendable, Equatable {

    /// Un process signalé, avec son exécutable au moment du gel : sert à
    /// reconnaître le process au redémarrage et à ne pas réveiller un PID
    /// réattribué à autre chose (un `Ctrl-Z` dans un terminal, par exemple).
    public struct Member: Codable, Sendable, Equatable {
        public let pid: pid_t
        public let execPath: String

        public init(pid: pid_t, execPath: String) {
            self.pid = pid
            self.execPath = execPath
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let name: String
        public let bundlePath: String?
        public let leaderPID: pid_t
        public let members: [Member]
        public let since: Date

        public init(
            key: String, name: String, bundlePath: String?, leaderPID: pid_t,
            members: [Member], since: Date
        ) {
            self.key = key
            self.name = name
            self.bundlePath = bundlePath
            self.leaderPID = leaderPID
            self.members = members
            self.since = since
        }

        /// Reconstruit un groupe signalable pour `Actuator.perform(.resume)`,
        /// qui repart de l'arbre vivant à partir de ces racines.
        public var group: AppGroup {
            AppGroup(
                key: key, name: name, bundlePath: bundlePath, leaderPID: leaderPID,
                pids: members.map(\.pid), footprintBytes: 0, residentBytes: 0,
                ownedByCurrentUser: true, suspended: true
            )
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public static var url: URL {
        Config.stateDirectory.appendingPathComponent("suspended.json")
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var keys: Set<String> { Set(entries.map(\.key)) }
    public func contains(_ key: String) -> Bool { entries.contains { $0.key == key } }

    /// Enregistre un gel. `touched` sont les PID effectivement signalés — l'arbre
    /// vivant, pas l'instantané du groupe — et `execPaths` leur exécutable.
    public mutating func insert(
        _ group: AppGroup, touched: [pid_t], execPaths: [pid_t: String], at date: Date = Date()
    ) {
        entries.removeAll { $0.key == group.key }
        let pids = touched.isEmpty ? group.pids : touched
        entries.append(Entry(
            key: group.key, name: group.name, bundlePath: group.bundlePath,
            leaderPID: group.leaderPID,
            members: pids.map { Member(pid: $0, execPath: execPaths[$0] ?? "") },
            since: date
        ))
    }

    public mutating func remove(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    // MARK: - Disque

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Écrit l'état, ou supprime le fichier s'il n'y a plus rien à retenir :
    /// l'absence du fichier signifie « rien de gelé », sans ambiguïté.
    public func write(to url: URL = SuspendState.url) {
        let fm = FileManager.default
        if entries.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        guard let data = try? Self.encoder.encode(self) else { return }
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Relit l'état. Fichier absent ou illisible → état vide : on ne réveille
    /// jamais sur la foi d'un JSON à moitié écrit.
    public static func read(from url: URL = SuspendState.url) -> SuspendState {
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(SuspendState.self, from: data)
        else { return SuspendState() }
        return state
    }
}
