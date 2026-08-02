import Darwin
import Foundation

/// État BSD d'un process (`sys/proc.h`).
private let SSTOP_STATUS: UInt32 = 4

public struct ProcessEntry: Codable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let uid: uid_t
    public let name: String
    public let execPath: String
    /// `phys_footprint` — c'est la colonne « Mémoire » du Moniteur d'activité,
    /// pas le RSS. Le RSS sous-estime lourdement les process MLX/Metal.
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let suspended: Bool
    /// Nom parlant : pour un interpréteur, le script exécuté plutôt que
    /// « Python ». Vaut `name` quand rien de mieux n'est disponible.
    public let label: String
}

/// Un ou plusieurs process regroupés comme le fait le Moniteur d'activité :
/// tous les helpers d'un bundle `.app` comptent sous l'app parente.
public struct AppGroup: Codable, Sendable {
    public let key: String
    public let name: String
    public let bundlePath: String?
    public let leaderPID: pid_t
    public let pids: [pid_t]
    public let footprintBytes: UInt64
    public let residentBytes: UInt64
    public let ownedByCurrentUser: Bool
    public let suspended: Bool

    public var isApp: Bool { bundlePath != nil }
}

public enum ProcessInventory {

    /// Liste tous les process lisibles. Ceux appartenant à root sont ignorés
    /// silencieusement : `proc_pid_rusage` échoue dessus sans privilèges, et on
    /// ne veut de toute façon jamais y toucher.
    public static func snapshot() -> [ProcessEntry] {
        let pids = allPIDs()
        var out: [ProcessEntry] = []
        out.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let bsd = bsdInfo(pid) else { continue }
            let footprint = physFootprint(pid)
            let resident = residentSize(pid)
            // Sans footprint ni RSS, le process est inaccessible : on l'ignore.
            guard footprint != nil || resident != nil else { continue }

            let name = procName(bsd) ?? "pid \(pid)"
            let path = execPath(pid) ?? ""
            let bytes = footprint ?? resident ?? 0
            // Étiqueter tout le monde, y compris les petits process. Le seuil
            // qui existait ici faisait qu'une cible de `manageable` cessait
            // d'être reconnue dès qu'elle maigrissait, ce qui est exactement
            // le moment où l'on veut encore savoir que c'est elle. Mesuré :
            // ~3 ms pour l'inventaire complet, 643 process étiquetés.
            let label = commandLabel(pid: pid, name: name, execPath: path)

            out.append(
                ProcessEntry(
                    pid: pid,
                    ppid: pid_t(bitPattern: bsd.pbi_ppid),
                    uid: bsd.pbi_uid,
                    name: name,
                    execPath: path,
                    footprintBytes: bytes,
                    residentBytes: resident ?? 0,
                    suspended: bsd.pbi_status == SSTOP_STATUS,
                    label: label
                )
            )
        }
        return out
    }

    /// Agrège les process en groupes affichables, triés par empreinte
    /// décroissante.
    public static func groups(from entries: [ProcessEntry]) -> [AppGroup] {
        let me = getuid()
        var buckets: [String: [ProcessEntry]] = [:]

        for e in entries {
            buckets[groupKey(for: e), default: []].append(e)
        }

        var groups: [AppGroup] = []
        for (key, members) in buckets {
            let sorted = members.sorted { $0.footprintBytes > $1.footprintBytes }
            let bundle = key.hasSuffix(".app") ? key : nil
            // Le leader d'un bundle est le process dont l'exécutable est
            // directement sous `<bundle>/Contents/MacOS/` ; à défaut, le plus gros.
            let leader = sorted.first { entry in
                guard let b = bundle else { return true }
                return entry.execPath.hasPrefix(b + "/Contents/MacOS/")
            } ?? sorted[0]

            groups.append(
                AppGroup(
                    key: key,
                    name: bundle.map { displayName(forBundle: $0) } ?? leader.label,
                    bundlePath: bundle,
                    leaderPID: leader.pid,
                    pids: sorted.map(\.pid),
                    footprintBytes: sorted.reduce(0) { $0 &+ $1.footprintBytes },
                    residentBytes: sorted.reduce(0) { $0 &+ $1.residentBytes },
                    ownedByCurrentUser: sorted.allSatisfy { $0.uid == me },
                    suspended: sorted.allSatisfy(\.suspended)
                )
            )
        }
        return groups.sorted { $0.footprintBytes > $1.footprintBytes }
    }

    public static func currentGroups() -> [AppGroup] {
        groups(from: snapshot())
    }

    // MARK: - Regroupement

    /// Clé de regroupement : le bundle `.app` le plus externe du chemin, sinon
    /// le process seul. `/Applications/Claude.app/Contents/Frameworks/Claude
    /// Helper (Renderer).app/…` retombe donc sur `/Applications/Claude.app`.
    static func groupKey(for entry: ProcessEntry) -> String {
        if let bundle = outermostAppBundle(entry.execPath) { return bundle }
        return entry.execPath.isEmpty ? "\(entry.name)#\(entry.pid)" : "\(entry.execPath)#\(entry.pid)"
    }

    /// Un `.app` rencontré *après* un `.framework` est un stub interne, pas une
    /// application : `…/Python.framework/…/Resources/Python.app` en est un.
    /// Le regrouper fusionnerait tous les interpréteurs Python de la machine
    /// sous une seule entrée — et « quitter Python » tuerait tout d'un coup.
    /// Les helpers Electron, eux, vivent sous un `.app` qui précède les
    /// `Frameworks/`, donc ils restent correctement regroupés.
    static func outermostAppBundle(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.hasSuffix(".framework") { return nil }
            components.append(String(component))
            if component.hasSuffix(".app") {
                return components.joined(separator: "/")
            }
        }
        return nil
    }

    /// Interpréteurs et lanceurs dont le nom de binaire n'apprend rien : pour
    /// eux, c'est le script exécuté qui identifie le process.
    static let genericRunners: Set<String> = [
        "python", "python2", "python3", "python3.9", "python3.10", "python3.11",
        "python3.12", "python3.13", "Python", "node", "deno", "bun", "ruby",
        "perl", "java", "sh", "bash", "zsh", "uv", "uvicorn", "gunicorn",
    ]

    /// Nom parlant pour un process. Quatre Python à 36, 23, 12 et 4 Gio sont
    /// indiscernables ; « gateway.py », « brain.py » ne le sont pas.
    static func commandLabel(pid: pid_t, name: String, execPath: String) -> String {
        let base = (execPath as NSString).lastPathComponent
        let generic = genericRunners.contains(base) || genericRunners.contains(name)
        guard generic else { return name }

        let args = commandArguments(pid)
        // Premier argument qui ressemble à un script ou à un module, options
        // ignorées. `python -m uvicorn app:api` doit donner « uvicorn ».
        var skipNext = false
        for arg in args.dropFirst() {
            if skipNext { skipNext = false; return shortModule(arg) }
            if arg == "-m" || arg == "-c" { skipNext = true; continue }
            if arg.hasPrefix("-") { continue }
            return shortModule(arg)
        }
        // `python -` lit son script sur l'entrée standard : il n'y a aucun nom
        // à en tirer. Le PID vaut mieux que quatre entrées « Python »
        // indiscernables dans un rapport.
        return "\(name) (pid \(pid))"
    }

    /// « /chemin/vers/gateway.py » → « gateway.py » ; « app.main:api » → « app.main ».
    static func shortModule(_ arg: String) -> String {
        let head = arg.split(separator: ":").first.map(String.init) ?? arg
        let base = (head as NSString).lastPathComponent
        return base.isEmpty ? arg : base
    }

    /// Arguments d'un process via `KERN_PROCARGS2`. Le tampon commence par
    /// `argc` (4 octets), puis le chemin de l'exécutable, un bourrage de NUL,
    /// puis `argc` chaînes terminées par NUL.
    static func commandArguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            dst.copyBytes(from: buffer[0..<4])
        }
        guard argc > 0 else { return [] }

        var index = 4
        while index < size, buffer[index] != 0 { index += 1 } // saute exec_path
        while index < size, buffer[index] == 0 { index += 1 } // saute le bourrage

        var args: [String] = []
        var start = index
        while index < size, args.count < Int(argc) {
            if buffer[index] == 0 {
                if index > start {
                    args.append(String(decoding: buffer[start..<index], as: UTF8.self))
                }
                start = index + 1
            }
            index += 1
        }
        return args
    }

    static func displayName(forBundle path: String) -> String {
        let base = (path as NSString).lastPathComponent
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }

    // MARK: - Sondes libproc

    /// `proc_listallpids` compte en **PID**, pas en octets — contrairement à ce
    /// que laisse croire son paramètre de taille, qui lui est en octets.
    ///
    /// Diviser la valeur de retour par `MemoryLayout<pid_t>.size` ne rendait
    /// donc qu'un quart des process (160 sur 643 mesurés), et le tampon calculé
    /// de la même façon était trop petit : le sous-ensemble obtenu était
    /// arbitraire. Des cibles de `manageable` disparaissaient de l'inventaire
    /// sans le moindre signe.
    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Large marge : la table des process bouge entre les deux appels.
        let capacity = Int(count) * 2 + 256
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listallpids(&buffer, Int32(capacity * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return Array(buffer.prefix(min(Int(written), capacity)))
    }

    static func physFootprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    static func residentSize(_ pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        return rc == size ? info.pti_resident_size : nil
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return rc == size ? info : nil
    }

    static func execPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let rc = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return rc > 0 ? String(cString: buffer) : nil
    }

    /// `pbi_name` est vide pour certains process : `pbi_comm` prend le relais
    /// (tronqué à 16 caractères, mais toujours présent).
    static func procName(_ info: proc_bsdinfo) -> String? {
        var copy = info
        let name = withUnsafeBytes(of: &copy.pbi_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        if !name.isEmpty { return name }
        let comm = withUnsafeBytes(of: &copy.pbi_comm) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return comm.isEmpty ? nil : comm
    }
}
