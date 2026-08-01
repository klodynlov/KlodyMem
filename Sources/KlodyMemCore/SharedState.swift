import Foundation

/// Snapshot publié par le garde et lu par la barre de menus. Écrit
/// atomiquement : la barre ne lira jamais un JSON à moitié écrit.
public struct SharedState: Codable, Sendable {
    public var date: Date
    public var tier: RiskTier
    public var score: Double
    public var summary: String
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var headroomBytes: UInt64
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    public var swapGrowthBytesPerSec: Double?
    public var kernelPressure: KernelPressure
    public var top: [TopEntry]
    public var suspended: [String]
    public var guardRunning: Bool
    public var lastAction: String?

    public struct TopEntry: Codable, Sendable {
        public let name: String
        public let bytes: UInt64
        public let pids: [pid_t]
        public let manageable: Bool
        public let suspended: Bool
    }

    public static var url: URL {
        Config.stateDirectory.appendingPathComponent("state.json")
    }

    public func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Config.stateDirectory, withIntermediateDirectories: true
        )
        try? data.write(to: Self.url, options: .atomic)
    }

    public static func read() -> SharedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedState.self, from: data)
    }

    /// Un état plus vieux que ça vient d'un garde mort : la barre l'affichera
    /// comme périmé plutôt que de mentir avec des chiffres figés.
    public var isStale: Bool { Date().timeIntervalSince(date) > 60 }
}
