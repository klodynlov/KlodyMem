import Foundation

/// Une ligne d'historique : l'échantillon, le verdict, et l'action éventuelle.
/// Sert au post-mortem (« pourquoi la machine a-t-elle ramé à 3 h ? ») et à
/// l'ajustement des seuils.
public struct HistoryEntry: Codable, Sendable {
    public let date: Date
    public let tier: RiskTier
    public let score: Double
    public let usedBytes: UInt64
    public let headroomBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapGrowthBytesPerSec: Double?
    public let kernelPressure: KernelPressure
    public let topOffenders: [String]
    public let action: String?

    public init(
        sample: MemorySample,
        assessment: RiskAssessment,
        topOffenders: [String],
        action: String? = nil
    ) {
        self.date = sample.date
        self.tier = assessment.tier
        self.score = assessment.score
        self.usedBytes = sample.memoryUsedBytes
        self.headroomBytes = sample.headroomBytes
        self.swapUsedBytes = sample.swapUsedBytes
        self.swapGrowthBytesPerSec = sample.swapGrowthBytesPerSec
        self.kernelPressure = sample.kernelPressure
        self.topOffenders = topOffenders
        self.action = action
    }
}

/// Journal JSONL avec rotation par taille. Une ligne par événement, pas par
/// échantillon : on n'écrit qu'aux changements de niveau et aux actions, sinon
/// le fichier grossit pour rien.
public final class HistoryLog {
    public let url: URL
    private let maxBytes: UInt64
    private let encoder: JSONEncoder

    public init(
        url: URL = Config.stateDirectory.appendingPathComponent("history.jsonl"),
        maxBytes: UInt64 = 8 << 20
    ) {
        self.url = url
        self.maxBytes = maxBytes
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func append(_ entry: HistoryEntry) {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)

        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? UInt64,
            size > maxBytes
        else { return }
        let archive = url.appendingPathExtension("1")
        try? fm.removeItem(at: archive)
        try? fm.moveItem(at: url, to: archive)
    }

    /// Relit les `limit` dernières lignes, la plus récente en dernier.
    public func tail(_ limit: Int) -> [HistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(HistoryEntry.self, from: data)
            }
    }
}
