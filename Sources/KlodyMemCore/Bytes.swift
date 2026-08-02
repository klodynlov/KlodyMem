import Foundation

public enum Bytes {
    /// Formate en unités binaires courtes : « 25,4 Gio ».
    public static func human(_ value: UInt64, decimals: Int = 1) -> String {
        human(Double(value), decimals: decimals)
    }

    public static func human(_ value: Double, decimals: Int = 1) -> String {
        let units = ["o", "Kio", "Mio", "Gio", "Tio"]
        var v = abs(value)
        var idx = 0
        while v >= 1024, idx < units.count - 1 {
            v /= 1024
            idx += 1
        }
        let sign = value < 0 ? "-" : ""
        let d = idx == 0 ? 0 : decimals
        return "\(sign)\(String(format: "%.\(d)f", v)) \(units[idx])"
    }

    /// Débit lisible : « 120 Mio/s ».
    public static func rate(_ bytesPerSec: Double?) -> String {
        guard let r = bytesPerSec else { return "—" }
        return human(r, decimals: 0) + "/s"
    }

    /// Parse « 40G », « 4096M », « 12Gi », « 500000000 ».
    public static func parse(_ text: String) -> UInt64? {
        // Doit accepter ce que l'outil lui-même affiche : « 19,5 Gio » doit se
        // recoller dans une commande sans retouche. D'où l'espace toléré, la
        // virgule décimale, et les unités françaises.
        let s = text
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: ",", with: ".")
            .lowercased()
        guard !s.isEmpty else { return nil }
        // Suffixes les plus longs d'abord : « gib » doit gagner avant « gi »,
        // qui doit gagner avant « g ».
        let kib = 1024.0, mib = kib * 1024, gib = mib * 1024, tib = gib * 1024
        let multipliers: [(String, Double)] = [
            ("tio", tib), ("gio", gib), ("mio", mib), ("kio", kib),
            ("tib", tib), ("gib", gib), ("mib", mib), ("kib", kib),
            ("ti", tib), ("gi", gib), ("mi", mib), ("ki", kib),
            ("tb", 1e12), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3),
            ("t", tib), ("g", gib), ("m", mib), ("k", kib),
            ("o", 1),
        ]
        for (suffix, mult) in multipliers where s.hasSuffix(suffix) {
            let head = String(s.dropLast(suffix.count))
            guard let n = Double(head), n >= 0 else { return nil }
            return UInt64(n * mult)
        }
        guard let n = Double(s), n >= 0 else { return nil }
        return UInt64(n)
    }

    public static func percent(_ ratio: Double) -> String {
        String(format: "%.0f %%", ratio * 100)
    }
}
