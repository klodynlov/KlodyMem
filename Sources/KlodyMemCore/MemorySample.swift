import Darwin
import Foundation

/// Niveau de pression rapporté par le noyau (`kern.memorystatus_vm_pressure_level`).
/// C'est ce compteur qui pilote le chemin `memorystatus` menant au dialogue
/// « Votre système a utilisé toute la mémoire allouée aux applications ».
public enum KernelPressure: Int, Codable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

/// Niveau de risque calculé par KlodyMem. Combine RAM, compresseur, swap et
/// dérivées temporelles — voir `RiskModel`.
public enum RiskTier: String, Codable, Sendable, CaseIterable, Comparable {
    case ok
    case watch
    case high
    case critical

    var rank: Int {
        switch self {
        case .ok: return 0
        case .watch: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool { lhs.rank < rhs.rank }

    /// Libellé court pour la barre de menus.
    public var glyph: String {
        switch self {
        case .ok: return "􀆼"
        case .watch: return "􀇾"
        case .high: return "􀇿"
        case .critical: return "􀇾"
        }
    }

    public var frenchLabel: String {
        switch self {
        case .ok: return "sain"
        case .watch: return "surveillance"
        case .high: return "élevé"
        case .critical: return "critique"
        }
    }
}

/// Instantané complet de l'état mémoire de la machine.
public struct MemorySample: Codable, Sendable {
    public let date: Date
    public let pageSize: UInt64

    // Décomposition alignée sur le Moniteur d'activité.
    public let totalBytes: UInt64
    public let appMemoryBytes: UInt64      // internal − purgeable : « mémoire allouée aux applications »
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64     // pages occupées par le compresseur
    public let cachedFilesBytes: UInt64    // external + purgeable (récupérable)
    public let freeBytes: UInt64

    // Swap et volume qui l'héberge.
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapFreeBytes: UInt64
    public let vmVolumeFreeBytes: UInt64

    // Dérivées temporelles — `nil` sur le tout premier échantillon.
    public let swapGrowthBytesPerSec: Double?
    public let compressionsPerSec: Double?
    public let decompressionsPerSec: Double?
    public let pageoutsPerSec: Double?

    public let kernelPressure: KernelPressure

    /// « Mémoire utilisée » du Moniteur d'activité.
    public var memoryUsedBytes: UInt64 { appMemoryBytes + wiredBytes + compressedBytes }

    public var usedRatio: Double {
        totalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(totalBytes)
    }

    /// Fraction du swap consommée. Attention : `swapTotalBytes` est dynamique
    /// sous macOS (le pager ajoute des swapfiles tant que le disque suit).
    public var swapRatio: Double {
        swapTotalBytes == 0 ? 0 : Double(swapUsedBytes) / Double(swapTotalBytes)
    }

    /// Ce qu'on peut encore allouer sans provoquer de swap : libre + caches
    /// récupérables.
    public var headroomBytes: UInt64 { freeBytes &+ cachedFilesBytes }

    public var headroomRatio: Double {
        totalBytes == 0 ? 0 : Double(headroomBytes) / Double(totalBytes)
    }

    /// Le pager peut-il encore agrandir le swap ? Il lui faut de la place sur
    /// `/System/Volumes/VM`.
    public var swapCanGrow: Bool { vmVolumeFreeBytes > 8 << 30 }
}

/// Compteurs bruts conservés entre deux échantillons pour calculer les débits.
private struct RawCounters {
    let date: Date
    let swapUsed: UInt64
    let compressions: UInt64
    let decompressions: UInt64
    let pageouts: UInt64
}

/// Échantillonneur mémoire. Conserve l'échantillon précédent pour dériver les
/// débits — ce sont eux qui distinguent « 60 Gio de swap stable » (bénin) de
/// « 60 Gio et ça monte de 200 Mio/s » (l'alerte système arrive).
public final class MemorySampler {
    private var previous: RawCounters?
    private let pageSize: UInt64
    private let totalBytes: UInt64

    public init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps == 0 ? 16384 : ps)

        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &mem, &size, nil, 0) != 0 { mem = 0 }
        totalBytes = mem
    }

    public func sample() -> MemorySample {
        let now = Date()
        let vm = Self.vmStatistics()
        let swap = Self.swapUsage()
        let pressure = Self.kernelPressure()
        let vmFree = Self.freeSpace(atPath: "/System/Volumes/VM")

        func bytes(_ pages: UInt32) -> UInt64 { UInt64(pages) &* pageSize }
        func bytes64(_ pages: UInt64) -> UInt64 { pages &* pageSize }

        let purgeable = bytes(vm.purgeable_count)
        let internalBytes = bytes(vm.internal_page_count)
        let externalBytes = bytes(vm.external_page_count)
        let appMemory = internalBytes > purgeable ? internalBytes - purgeable : 0

        // Débits depuis l'échantillon précédent.
        var swapRate: Double?
        var compRate: Double?
        var decompRate: Double?
        var pageoutRate: Double?
        if let prev = previous {
            let dt = now.timeIntervalSince(prev.date)
            if dt > 0.2 {
                swapRate = (Double(swap.used) - Double(prev.swapUsed)) / dt
                compRate = Self.delta(vm.compressions, prev.compressions) / dt
                decompRate = Self.delta(vm.decompressions, prev.decompressions) / dt
                pageoutRate = Self.delta(vm.pageouts, prev.pageouts) / dt
            }
        }
        previous = RawCounters(
            date: now,
            swapUsed: swap.used,
            compressions: vm.compressions,
            decompressions: vm.decompressions,
            pageouts: UInt64(vm.pageouts)
        )

        return MemorySample(
            date: now,
            pageSize: pageSize,
            totalBytes: totalBytes,
            appMemoryBytes: appMemory,
            wiredBytes: bytes(vm.wire_count),
            compressedBytes: bytes(vm.compressor_page_count),
            cachedFilesBytes: externalBytes &+ purgeable,
            freeBytes: bytes(vm.free_count) &+ bytes(vm.speculative_count),
            swapTotalBytes: swap.total,
            swapUsedBytes: swap.used,
            swapFreeBytes: swap.free,
            vmVolumeFreeBytes: vmFree,
            swapGrowthBytesPerSec: swapRate,
            compressionsPerSec: compRate,
            decompressionsPerSec: decompRate,
            pageoutsPerSec: pageoutRate,
            kernelPressure: pressure
        )
        // `bytes64` reste disponible si un compteur 64 bits est ajouté plus tard.
    }

    /// Compteurs monotones : un redémarrage du pager peut les remettre à zéro.
    private static func delta(_ current: UInt64, _ previous: UInt64) -> Double {
        current >= previous ? Double(current - previous) : 0
    }

    private static func delta(_ current: UInt32, _ previous: UInt64) -> Double {
        delta(UInt64(current), previous)
    }

    // MARK: - Sondes système

    static func vmStatistics() -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr != KERN_SUCCESS { return vm_statistics64_data_t() }
        return stats
    }

    static func swapUsage() -> (total: UInt64, used: UInt64, free: UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else {
            return (0, 0, 0)
        }
        return (xsw.xsu_total, xsw.xsu_used, xsw.xsu_avail)
    }

    static func kernelPressure() -> KernelPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return KernelPressure(rawValue: Int(level)) ?? .normal
    }

    static func freeSpace(atPath path: String) -> UInt64 {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return 0 }
        return UInt64(st.f_bavail) &* UInt64(st.f_bsize)
    }
}
