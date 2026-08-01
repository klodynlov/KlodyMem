import AppKit
import KlodyMemCore

/// Moniteur de la barre de menus.
///
/// Il échantillonne lui-même plutôt que de dépendre du daemon : la barre reste
/// utile même si `klodymem guard` n'est pas installé. Si le daemon tourne, son
/// `state.json` sert à afficher la dernière action appliquée.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sampler = MemorySampler()
    private var config = Config.loadOrDefault()
    private var timer: Timer?

    private var lastSample: MemorySample?
    private var lastAssessment: RiskAssessment?
    private var lastGroups: [AppGroup] = []

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        refresh()
        // 5 s : assez fin pour voir une rampe de swap, assez lâche pour ne rien
        // coûter (un tick complet mesure ~15 ms sur 500 process).
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.map { RunLoop.main.add($0, forMode: .common) }
    }

    // MARK: - Échantillonnage

    private func refresh() {
        let sample = sampler.sample()
        let assessment = RiskModel.assess(sample, thresholds: config.thresholds)
        lastSample = sample
        lastAssessment = assessment
        lastGroups = ProcessInventory.currentGroups()
        render(sample, assessment)
    }

    private func render(_ sample: MemorySample, _ assessment: RiskAssessment) {
        guard let button = statusItem.button else { return }
        let percent = Int((sample.usedRatio * 100).rounded())
        let title = " \(percent)%"

        let color: NSColor
        switch assessment.tier {
        case .ok: color = .secondaryLabelColor
        case .watch: color = .systemYellow
        case .high: color = .systemOrange
        case .critical: color = .systemRed
        }

        let symbol = symbolName(for: assessment.tier)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mémoire")
        button.image?.isTemplate = assessment.tier == .ok
        button.contentTintColor = assessment.tier == .ok ? nil : color
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color]
        )
        button.toolTip = "Mémoire \(Bytes.percent(sample.usedRatio)) · marge "
            + "\(Bytes.human(sample.headroomBytes)) · \(assessment.summary)"
    }

    private func symbolName(for tier: RiskTier) -> String {
        switch tier {
        case .ok: return "memorychip"
        case .watch: return "memorychip"
        case .high: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon"
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        config = Config.loadOrDefault() // relire à l'ouverture : édition à chaud
        refresh()
        menu.removeAllItems()
        guard let sample = lastSample, let assessment = lastAssessment else { return }

        menu.addItem(header("Niveau \(assessment.tier.frenchLabel) — \(assessment.summary)"))
        menu.addItem(info("Utilisée", "\(Bytes.human(sample.memoryUsedBytes)) / "
            + "\(Bytes.human(sample.totalBytes))  (\(Bytes.percent(sample.usedRatio)))"))
        menu.addItem(info("Marge allouable", Bytes.human(sample.headroomBytes)))
        var swapDetail = "\(Bytes.human(sample.swapUsedBytes)) / \(Bytes.human(sample.swapTotalBytes))"
        if let growth = sample.swapGrowthBytesPerSec, growth > 1024 * 1024 {
            swapDetail += "   +\(Bytes.rate(growth))"
        }
        menu.addItem(info("Swap", swapDetail))
        if !sample.swapCanGrow {
            menu.addItem(info("⚠︎ Volume VM", "\(Bytes.human(sample.vmVolumeFreeBytes)) libres — "
                + "le swap ne peut plus grandir"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Plus gros consommateurs"))
        let visible = lastGroups
            .filter { $0.footprintBytes >= config.reportFloorBytes }
            .prefix(8)
        if visible.isEmpty {
            menu.addItem(info("—", "rien au-dessus du seuil de rapport"))
        }
        for group in visible {
            menu.addItem(processItem(for: group))
        }

        menu.addItem(.separator())
        if let state = SharedState.read(), !state.isStale {
            menu.addItem(info("Garde", "actif" + (state.lastAction.map { " · \($0)" } ?? "")))
        } else {
            menu.addItem(info("Garde", "inactif — surveillance locale seulement"))
        }

        let reveal = NSMenuItem(
            title: "Ouvrir le Moniteur d'activité",
            action: #selector(openActivityMonitor), keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        let editConfig = NSMenuItem(
            title: "Modifier la configuration…",
            action: #selector(openConfig), keyEquivalent: ""
        )
        editConfig.target = self
        menu.addItem(editConfig)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quitter KlodyMem", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Chaque application porte un sous-menu d'actions. Les cibles protégées
    /// n'en ont pas : mieux vaut une entrée grisée qu'un bouton qui refuse.
    private func processItem(for group: AppGroup) -> NSMenuItem {
        let suffix = group.suspended ? "  ⏸" : ""
        let item = NSMenuItem(
            title: "\(Bytes.human(group.footprintBytes).leftPad(to: 9))   \(group.name)\(suffix)",
            action: nil, keyEquivalent: ""
        )
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]
        )

        if config.isProtected(group) || !group.ownedByCurrentUser {
            item.isEnabled = false
            return item
        }

        let submenu = NSMenu()
        if group.suspended {
            submenu.addItem(action("Reprendre", .resume, group))
        } else {
            submenu.addItem(action("Suspendre (réversible)", .suspend, group))
        }
        submenu.addItem(action("Quitter", .quit, group))
        submenu.addItem(.separator())
        submenu.addItem(info("PID", group.pids.map(String.init).joined(separator: " ")))
        item.submenu = submenu
        return item
    }

    private func action(_ title: String, _ kind: ActionKind, _ group: AppGroup) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [kind.rawValue, group.key] as NSArray
        return item
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard
            let payload = sender.representedObject as? NSArray,
            let raw = payload.firstObject as? String,
            let kind = ActionKind(rawValue: raw),
            let key = payload.lastObject as? String,
            let group = lastGroups.first(where: { $0.key == key })
        else { return }

        // Quitter peut faire perdre du travail non enregistré : on confirme.
        if kind == .quit || kind == .kill {
            let alert = NSAlert()
            alert.messageText = "\(kind.frenchLabel.capitalized) \(group.name) ?"
            alert.informativeText = "\(Bytes.human(group.footprintBytes)) seront libérés. "
                + "Le travail non enregistré peut être perdu."
            alert.alertStyle = .warning
            alert.addButton(withTitle: kind.frenchLabel.capitalized)
            alert.addButton(withTitle: "Annuler")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let result = Actuator(config: config).perform(kind, on: group)
        if !result.succeeded {
            Notifier().post(
                title: "Action refusée",
                subtitle: "\(kind.frenchLabel) \(group.name)",
                body: result.message
            )
        }
        refresh()
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func openConfig() {
        let url = Config.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Config().save()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Fabriques d'items

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        item.isEnabled = false
        return item
    }

    private func info(_ label: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label)   \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

extension String {
    func leftPad(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - Point d'entrée

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // barre de menus seulement, pas de Dock
app.run()
