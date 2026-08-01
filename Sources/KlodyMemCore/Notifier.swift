import Foundation

/// Notifications système.
///
/// On passe par `osascript` et non par `UserNotifications` : ce dernier exige
/// un bundle signé avec un identifiant, ce qui exclut l'usage en CLI et sous
/// launchd. `osascript` fonctionne dans les deux cas.
public struct Notifier {
    public let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public func post(title: String, subtitle: String? = nil, body: String) {
        guard enabled else { return }
        var script = "display notification \(Self.escape(body)) with title \(Self.escape(title))"
        if let subtitle {
            script += " subtitle \(Self.escape(subtitle))"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    /// AppleScript n'a pas d'échappement d'accolade : on neutralise guillemets
    /// et antislashs, et on aplatit les retours à la ligne.
    static func escape(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " · ")
        let escaped = flattened
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
