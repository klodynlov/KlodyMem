import XCTest
@testable import KlodyMemCore

// MARK: - Fabriques

private let GiB: UInt64 = 1 << 30

private func makeSample(
    total: UInt64 = 128 * GiB,
    app: UInt64 = 40 * GiB,
    wired: UInt64 = 10 * GiB,
    compressed: UInt64 = 5 * GiB,
    cached: UInt64 = 20 * GiB,
    free: UInt64 = 50 * GiB,
    swapTotal: UInt64 = 8 * GiB,
    swapUsed: UInt64 = 1 * GiB,
    vmFree: UInt64 = 800 * GiB,
    swapGrowth: Double? = nil,
    pressure: KernelPressure = .normal
) -> MemorySample {
    MemorySample(
        date: Date(),
        pageSize: 16384,
        totalBytes: total,
        appMemoryBytes: app,
        wiredBytes: wired,
        compressedBytes: compressed,
        cachedFilesBytes: cached,
        freeBytes: free,
        swapTotalBytes: swapTotal,
        swapUsedBytes: swapUsed,
        swapFreeBytes: swapTotal - swapUsed,
        vmVolumeFreeBytes: vmFree,
        swapGrowthBytesPerSec: swapGrowth,
        compressionsPerSec: 0,
        decompressionsPerSec: 0,
        pageoutsPerSec: 0,
        kernelPressure: pressure
    )
}

private func makeGroup(
    name: String,
    bundle: String? = nil,
    bytes: UInt64 = GiB,
    pids: [pid_t] = [4242],
    mine: Bool = true,
    suspended: Bool = false
) -> AppGroup {
    AppGroup(
        key: bundle ?? name,
        name: name,
        bundlePath: bundle,
        leaderPID: pids[0],
        pids: pids,
        footprintBytes: bytes,
        residentBytes: bytes,
        ownedByCurrentUser: mine,
        suspended: suspended
    )
}

// MARK: - Formatage

final class BytesTests: XCTestCase {
    func testHumanUsesBinaryUnits() {
        XCTAssertEqual(Bytes.human(UInt64(512)), "512 o")
        XCTAssertEqual(Bytes.human(GiB), "1,0 Gio".replacingOccurrences(of: ",", with: decimalSeparator))
        XCTAssertEqual(Bytes.human(25 * GiB + 400 * (1 << 20), decimals: 1),
                       "25,4 Gio".replacingOccurrences(of: ",", with: decimalSeparator))
    }

    /// `String(format:)` suit la locale ; on compare donc au séparateur réel.
    private var decimalSeparator: String {
        String(format: "%.1f", 1.5).contains(",") ? "," : "."
    }

    func testParseAcceptsSuffixes() {
        XCTAssertEqual(Bytes.parse("40G"), 40 * GiB)
        XCTAssertEqual(Bytes.parse("40g"), 40 * GiB)
        XCTAssertEqual(Bytes.parse("512M"), 512 * (1 << 20))
        XCTAssertEqual(Bytes.parse("2Ti"), 2 * (1 << 40))
        XCTAssertEqual(Bytes.parse("1024"), 1024)
        XCTAssertNil(Bytes.parse("plein"))
        XCTAssertNil(Bytes.parse(""))
    }

    /// Ce que l'outil affiche doit pouvoir se recoller dans une commande :
    /// unités françaises, espace, virgule décimale.
    func testParseAcceptsItsOwnOutput() {
        XCTAssertEqual(Bytes.parse("64 Gio"), 64 * GiB)
        XCTAssertEqual(Bytes.parse("19,5 Gio"), UInt64(19.5 * Double(GiB)))
        XCTAssertEqual(Bytes.parse("512 Mio"), 512 * (1 << 20))
        XCTAssertEqual(Bytes.parse("512 o"), 512)
        for value: UInt64 in [512, 4 * GiB, 25 * GiB + 400 * (1 << 20)] {
            XCTAssertNotNil(Bytes.parse(Bytes.human(value)), "aller-retour sur \(value)")
        }
    }
}

// MARK: - Modèle de risque

final class RiskModelTests: XCTestCase {
    func testRampIsClamped() {
        XCTAssertEqual(RiskModel.ramp(0.5, low: 0.6, high: 0.9), 0, accuracy: 1e-9)
        XCTAssertEqual(RiskModel.ramp(0.75, low: 0.6, high: 0.9), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RiskModel.ramp(2.0, low: 0.6, high: 0.9), 1, accuracy: 1e-9)
    }

    func testIdleMachineIsOK() {
        let assessment = RiskModel.assess(makeSample(), thresholds: Thresholds())
        XCTAssertEqual(assessment.tier, .ok)
        XCTAssertLessThan(assessment.score, 0.35)
    }

    func testExhaustedHeadroomIsCritical() {
        let sample = makeSample(app: 118 * GiB, cached: GiB / 2, free: GiB)
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        XCTAssertEqual(assessment.tier, .critical)
    }

    /// Le noyau est autoritaire : même avec des chiffres flatteurs, sa pression
    /// critique doit faire basculer le verdict.
    func testKernelCriticalOverridesCalmNumbers() {
        let assessment = RiskModel.assess(makeSample(pressure: .critical), thresholds: Thresholds())
        XCTAssertEqual(assessment.tier, .critical)
    }

    func testKernelWarningFloorsAtHigh() {
        let assessment = RiskModel.assess(makeSample(pressure: .warning), thresholds: Thresholds())
        XCTAssertGreaterThanOrEqual(assessment.tier, RiskTier.high)
    }

    /// Un swap qui grimpe alors que la marge est déjà mince : c'est le signal
    /// que l'alerte système approche.
    func testSwapGrowthRaisesRiskWhenHeadroomIsThin() {
        let thin = makeSample(app: 110 * GiB, cached: GiB, free: 3 * GiB)
        let calm = RiskModel.assess(thin, thresholds: Thresholds())
        let climbing = RiskModel.assess(
            makeSample(app: 110 * GiB, cached: GiB, free: 3 * GiB,
                       swapGrowth: 100 * 1024 * 1024),
            thresholds: Thresholds()
        )
        XCTAssertGreaterThanOrEqual(climbing.score, calm.score)
        XCTAssertGreaterThanOrEqual(climbing.tier, RiskTier.high)
    }

    /// Régression observée en conditions réelles : à la sortie de veille, et au
    /// chargement d'un gros modèle, le swap grimpe à ~1 Gio/s avec 33 Gio de
    /// marge disponible. Ce n'est pas un danger et ça ne doit pas déclencher.
    func testSwapGrowthIsIgnoredWhenHeadroomIsAmple() {
        let sample = makeSample(app: 16 * GiB, wired: 14 * GiB, compressed: 64 * GiB,
                                cached: 5 * GiB, free: 28 * GiB,
                                swapTotal: 32 * GiB, swapUsed: 31 * GiB,
                                swapGrowth: 961 * 1024 * 1024)
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        let trend = assessment.components.first { $0.name == "tendance swap" }
        XCTAssertNotNil(trend)
        XCTAssertLessThan(trend?.score ?? 1, 0.35, "la tendance ne doit pas porter le score")
        XCTAssertLessThan(assessment.tier, RiskTier.critical)
    }

    /// Reproduit la configuration de la capture d'écran : le pager ne peut plus
    /// agrandir le swap faute de place disque.
    func testFullVMVolumeIsCritical() {
        let sample = makeSample(swapTotal: 64 * GiB, swapUsed: 63 * GiB, vmFree: GiB)
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        XCTAssertEqual(assessment.tier, .critical)
        XCTAssertTrue(assessment.summary.contains("volume VM"))
    }

    /// Régression : sur machine saine le swap reste à ~96 % en permanence
    /// (le pager redimensionne ses fichiers). Tant que le volume VM a de la
    /// place, ça ne doit pas produire d'alerte.
    func testFullButExtensibleSwapIsNotAlarming() {
        let sample = makeSample(app: 15 * GiB, wired: 40 * GiB, compressed: 7 * GiB,
                                cached: 6 * GiB, free: 59 * GiB,
                                swapTotal: 20 * GiB, swapUsed: 19 * GiB,
                                vmFree: 864 * GiB)
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        XCTAssertEqual(assessment.tier, .ok)
    }

    /// Même swap saturé, mais le volume VM est plein : là c'est le scénario du
    /// dialogue « forcer à quitter ».
    func testFullSwapOnFullVolumeIsCritical() {
        let sample = makeSample(app: 15 * GiB, wired: 40 * GiB, compressed: 7 * GiB,
                                cached: 6 * GiB, free: 59 * GiB,
                                swapTotal: 20 * GiB, swapUsed: 19 * GiB,
                                vmFree: 2 * GiB)
        XCTAssertEqual(RiskModel.assess(sample, thresholds: Thresholds()).tier, .critical)
    }

    func testDriversExplainTheVerdict() {
        let sample = makeSample(app: 118 * GiB, cached: GiB / 2, free: GiB)
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        XCTAssertFalse(assessment.drivers.isEmpty)
        XCTAssertFalse(assessment.summary.isEmpty)
    }
}

// MARK: - Politique

final class ConfigPolicyTests: XCTestCase {
    func testHardProtectedCannotBeOverridden() {
        var config = Config()
        config.manageable = ["Finder", "WindowServer"]
        XCTAssertTrue(config.isProtected(makeGroup(name: "Finder")))
        XCTAssertFalse(config.isManageable(makeGroup(name: "Finder")))
    }

    func testManageableMatchesNameAndBundle() {
        var config = Config()
        config.manageable = ["Google Chrome"]
        XCTAssertTrue(config.isManageable(
            makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app")
        ))
        XCTAssertFalse(config.isManageable(makeGroup(name: "Safari")))
    }

    func testOtherUsersProcessesAreNeverManageable() {
        var config = Config()
        config.manageable = ["someroot"]
        XCTAssertFalse(config.isManageable(makeGroup(name: "someroot", mine: false)))
    }

    /// Régression : ajouter un réglage a rendu illisibles toutes les configs
    /// déjà écrites, et l'agent est parti en boucle de redémarrage. Une clé
    /// absente doit valoir sa valeur par défaut.
    func testDecodingToleratesMissingKeys() throws {
        let json = Data(#"{"manageable":["Google Chrome"]}"#.utf8)
        let c = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(c.manageable, ["Google Chrome"])
        XCTAssertEqual(c.pollSeconds, Config().pollSeconds)
        XCTAssertEqual(c.actions.quitGraceSeconds, ActionPolicy().quitGraceSeconds)
        XCTAssertEqual(c.thresholds.criticalHeadroomBytes, Thresholds().criticalHeadroomBytes)
    }

    func testDecodingAnEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: Data("{}".utf8)), Config())
    }

    /// Une config partielle ne doit pas perdre ce qu'elle précise.
    func testPartialSectionsKeepTheirOverrides() throws {
        let json = Data(#"{"actions":{"quitAtCritical":true},"thresholds":{"trendHeadroomRatio":0.5}}"#.utf8)
        let c = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertTrue(c.actions.quitAtCritical)
        XCTAssertEqual(c.thresholds.trendHeadroomRatio, 0.5)
        XCTAssertEqual(c.actions.confirmSamples, ActionPolicy().confirmSamples)
        XCTAssertEqual(c.thresholds.watchUsedRatio, Thresholds().watchUsedRatio)
    }

    /// Aller-retour : ce que l'outil écrit doit se relire à l'identique.
    func testSaveLoadRoundTrip() throws {
        var c = Config()
        c.manageable = ["Google Chrome"]
        c.actions.suspendAtHigh = true
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), c)
    }

    func testEmptyManageableEntriesAreIgnored() {
        var config = Config()
        config.manageable = ["", "  "]
        XCTAssertFalse(config.isManageable(makeGroup(name: "")))
    }
}

// MARK: - Actions

final class ActuatorTests: XCTestCase {
    func testValidateRefusesProtected() {
        let actuator = Actuator(config: Config(), dryRun: true)
        XCTAssertThrowsError(try actuator.validate(makeGroup(name: "Finder"), kind: .suspend))
    }

    func testValidateRefusesSystemPIDs() {
        let actuator = Actuator(config: Config(), dryRun: true)
        XCTAssertThrowsError(
            try actuator.validate(makeGroup(name: "quelquechose", pids: [42]), kind: .suspend)
        )
    }

    func testValidateRefusesKillUnlessAllowed() {
        let actuator = Actuator(config: Config(), dryRun: true)
        let group = makeGroup(name: "Cobaye", pids: [40000])
        XCTAssertThrowsError(try actuator.validate(group, kind: .kill))
        XCTAssertNoThrow(try actuator.validate(group, kind: .suspend))
    }

    func testResumeIsAlwaysAllowed() {
        let actuator = Actuator(config: Config(), dryRun: true)
        XCTAssertNoThrow(try actuator.validate(makeGroup(name: "Finder"), kind: .resume))
    }

    func testDryRunSendsNoSignal() {
        let actuator = Actuator(config: Config(), dryRun: true)
        let result = actuator.perform(.suspend, on: makeGroup(name: "Cobaye", pids: [40000]))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.message.contains("simulation"))
    }

    /// Régression constatée en production : Chrome a ignoré la demande d'arrêt,
    /// et le garde a compté un succès — donc respecté son cooldown pendant que
    /// la mémoire n'était jamais rendue.
    func testWaitForExitReportsSurvivors() {
        let live = getpid()
        XCTAssertEqual(Actuator.waitForExit([live], timeout: 0.4), [live])
    }

    func testWaitForExitReturnsEmptyForDeadPIDs() {
        // PID hors de la plage allouable : garanti absent.
        XCTAssertTrue(Actuator.waitForExit([pid_t(999_999)], timeout: 0.4).isEmpty)
    }

    func testWaitForExitDetectsAnActualExit() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["0.3"]
        try task.run()
        let pid = task.processIdentifier
        XCTAssertTrue(
            Actuator.waitForExit([pid], timeout: 3).isEmpty,
            "la sortie du process doit être détectée avant l'échéance"
        )
        task.waitUntilExit()
    }

    func testPerformOnProtectedReturnsFailureNotCrash() {
        let result = Actuator(config: Config(), dryRun: true)
            .perform(.quit, on: makeGroup(name: "WindowServer"))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.reclaimedBytes, 0)
    }
}

// MARK: - Récupération

final class ReclaimerTests: XCTestCase {
    func testPlanIsEmptyWhenHeadroomSuffices() {
        var config = Config()
        config.manageable = ["Cobaye"]
        let reclaimer = Reclaimer(config: config, dryRun: true)
        let plan = reclaimer.plan(
            target: 10 * GiB,
            sample: makeSample(),
            groups: [makeGroup(name: "Cobaye", bytes: 8 * GiB, pids: [40000])]
        )
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.sufficient)
    }

    func testPlanOnlyTargetsManageableApps() {
        var config = Config()
        config.manageable = ["Cobaye"]
        let reclaimer = Reclaimer(config: config, dryRun: true)
        let plan = reclaimer.plan(
            target: 100 * GiB,
            sample: makeSample(cached: GiB, free: GiB),
            groups: [
                makeGroup(name: "Cobaye", bytes: 8 * GiB, pids: [40000]),
                makeGroup(name: "Intouchable", bytes: 40 * GiB, pids: [40001]),
            ]
        )
        XCTAssertEqual(plan.steps.map(\.group.name), ["Cobaye"])
    }

    func testPlanSkipsAlreadySuspended() {
        var config = Config()
        config.manageable = ["Cobaye"]
        let reclaimer = Reclaimer(config: config, dryRun: true)
        let plan = reclaimer.plan(
            target: 100 * GiB,
            sample: makeSample(cached: GiB, free: GiB),
            groups: [makeGroup(name: "Cobaye", bytes: 8 * GiB, pids: [40000], suspended: true)]
        )
        XCTAssertTrue(plan.steps.isEmpty)
    }
}

// MARK: - Regroupement des process

final class ProcessInventoryTests: XCTestCase {
    /// Les helpers Electron sont eux-mêmes des `.app` imbriqués ; il faut
    /// remonter au bundle le plus externe pour retrouver le total du Moniteur
    /// d'activité.
    func testHelpersGroupUnderOutermostBundle() {
        let helper = "/Applications/Claude.app/Contents/Frameworks/"
            + "Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
        XCTAssertEqual(
            ProcessInventory.outermostAppBundle(helper),
            "/Applications/Claude.app"
        )
    }

    /// Régression : les 8 process de la passerelle MLX se retrouvaient
    /// fusionnés sous un unique groupe « Python » via le stub
    /// `Python.framework/…/Python.app`.
    func testFrameworkInternalStubIsNotAnApp() {
        let stub = "/opt/homebrew/Cellar/python@3.11/3.11.15_1/Frameworks/"
            + "Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
        XCTAssertNil(ProcessInventory.outermostAppBundle(stub))
    }

    func testTwoPythonProcessesStayInSeparateGroups() {
        let path = "/opt/homebrew/Cellar/python@3.11/3.11.15_1/Frameworks/"
            + "Python.framework/Versions/3.11/Resources/Python.app/Contents/MacOS/Python"
        let a = ProcessEntry(pid: 100, ppid: 1, uid: 501, name: "Python", execPath: path,
                             footprintBytes: 40 << 30, residentBytes: 0, suspended: false,
                             label: "gateway.py")
        let b = ProcessEntry(pid: 200, ppid: 1, uid: 501, name: "Python", execPath: path,
                             footprintBytes: 30 << 30, residentBytes: 0, suspended: false,
                             label: "brain.py")
        XCTAssertEqual(ProcessInventory.groups(from: [a, b]).count, 2)
    }

    func testGroupNameUsesTheCommandLabel() {
        let path = "/opt/homebrew/bin/python3.11"
        let a = ProcessEntry(pid: 100, ppid: 1, uid: 501, name: "Python", execPath: path,
                             footprintBytes: 40 << 30, residentBytes: 0, suspended: false,
                             label: "gateway.py")
        XCTAssertEqual(ProcessInventory.groups(from: [a]).first?.name, "gateway.py")
    }

    func testShortModuleStripsPathAndAttribute() {
        XCTAssertEqual(ProcessInventory.shortModule("/srv/klody/gateway.py"), "gateway.py")
        XCTAssertEqual(ProcessInventory.shortModule("app.main:api"), "app.main")
        XCTAssertEqual(ProcessInventory.shortModule("uvicorn"), "uvicorn")
    }

    func testNonGenericBinaryKeepsItsName() {
        XCTAssertEqual(
            ProcessInventory.commandLabel(pid: 1, name: "Xcode", execPath: "/usr/bin/xcodebuild"),
            "Xcode"
        )
    }

    /// Lecture réelle de KERN_PROCARGS2 sur le process de test.
    func testCommandArgumentsReadsOwnProcess() {
        let args = ProcessInventory.commandArguments(getpid())
        XCTAssertFalse(args.isEmpty, "KERN_PROCARGS2 doit rendre au moins argv[0]")
        XCTAssertFalse(args[0].isEmpty)
    }

    func testPlainBinaryHasNoBundle() {
        XCTAssertNil(ProcessInventory.outermostAppBundle("/usr/bin/ssh"))
        XCTAssertNil(ProcessInventory.outermostAppBundle(""))
    }

    func testDisplayNameStripsExtension() {
        XCTAssertEqual(
            ProcessInventory.displayName(forBundle: "/Applications/Google Chrome.app"),
            "Google Chrome"
        )
    }

    func testNonBundledProcessesStayDistinct() {
        let a = ProcessEntry(pid: 10, ppid: 1, uid: 501, name: "python3",
                             execPath: "/usr/bin/python3", footprintBytes: 0,
                             residentBytes: 0, suspended: false, label: "python3")
        let b = ProcessEntry(pid: 11, ppid: 1, uid: 501, name: "python3",
                             execPath: "/usr/bin/python3", footprintBytes: 0,
                             residentBytes: 0, suspended: false, label: "python3")
        XCTAssertNotEqual(ProcessInventory.groupKey(for: a), ProcessInventory.groupKey(for: b))
    }
}

// MARK: - Sondes réelles

final class LiveProbeTests: XCTestCase {
    func testSamplerReturnsCoherentValues() {
        let sample = MemorySampler().sample()
        XCTAssertGreaterThan(sample.totalBytes, 0)
        XCTAssertGreaterThan(sample.memoryUsedBytes, 0)
        XCTAssertLessThanOrEqual(sample.memoryUsedBytes, sample.totalBytes)
        XCTAssertGreaterThan(sample.pageSize, 0)
    }

    func testRatesAppearOnSecondSample() {
        let sampler = MemorySampler()
        XCTAssertNil(sampler.sample().swapGrowthBytesPerSec)
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertNotNil(sampler.sample().swapGrowthBytesPerSec)
    }

    /// Régression : `proc_listallpids` compte en PID et non en octets. La
    /// division par `MemoryLayout<pid_t>.size` ne rendait qu'un quart des
    /// process, et des cibles armées disparaissaient sans signe.
    func testAllPIDsMatchesTheSystemCount() throws {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let expected = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count

        let got = ProcessInventory.allPIDs().count
        XCTAssertGreaterThan(expected, 50, "le système doit avoir bien plus de 50 process")
        // ±15 % : la table bouge entre les deux mesures.
        XCTAssertEqual(Double(got), Double(expected), accuracy: Double(expected) * 0.15,
                       "allPIDs() rend \(got) PID, ps en compte \(expected)")
    }

    /// Les process lourds de l'utilisateur doivent tous être atteignables :
    /// c'est la condition pour que `manageable` fonctionne.
    func testInventoryCoversLargeUserProcesses() {
        let entries = ProcessInventory.snapshot()
        let mine = entries.filter { $0.uid == getuid() }
        XCTAssertGreaterThan(mine.count, 20, "trop peu de process utilisateur visibles")
    }

    func testInventoryFindsThisProcess() {
        let entries = ProcessInventory.snapshot()
        XCTAssertFalse(entries.isEmpty)
        let me = entries.first { $0.pid == getpid() }
        XCTAssertNotNil(me, "le process de test doit apparaître dans son propre inventaire")
        XCTAssertGreaterThan(me?.footprintBytes ?? 0, 0)
    }

    /// Le garde-fou le plus important : jamais d'action sur soi-même.
    func testSelfIsAlwaysProtected() {
        let groups = ProcessInventory.currentGroups()
        guard let mine = groups.first(where: { $0.pids.contains(getpid()) }) else {
            return XCTFail("process de test introuvable dans les groupes")
        }
        XCTAssertTrue(Config().isProtected(mine))
    }
}

// MARK: - Journal

final class HistoryLogTests: XCTestCase {
    func testAppendThenTailRoundTrips() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("klodymem-test-\(getpid()).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = HistoryLog(url: tmp)
        let sample = makeSample()
        let assessment = RiskModel.assess(sample, thresholds: Thresholds())
        log.append(HistoryEntry(sample: sample, assessment: assessment,
                                topOffenders: ["Cobaye 8 Gio"], action: "notify"))
        log.append(HistoryEntry(sample: sample, assessment: assessment,
                                topOffenders: [], action: "recovered"))

        let entries = log.tail(10)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.last?.action, "recovered")
        XCTAssertEqual(entries.first?.topOffenders, ["Cobaye 8 Gio"])
    }

    func testTailOnMissingFileIsEmpty() {
        let missing = URL(fileURLWithPath: "/nonexistent/klodymem/history.jsonl")
        XCTAssertTrue(HistoryLog(url: missing).tail(5).isEmpty)
    }
}

// MARK: - Notifications

final class NotifierTests: XCTestCase {
    func testEscapeNeutralisesQuotesAndNewlines() {
        XCTAssertEqual(Notifier.escape("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(Notifier.escape("un\ndeux"), "\"un · deux\"")
        XCTAssertEqual(Notifier.escape("c:\\chemin"), "\"c:\\\\chemin\"")
    }
}


// MARK: - Échelle d'escalade

final class EscalationTests: XCTestCase {
    private func armed(quit: Bool) -> Config {
        var c = Config()
        c.manageable = ["Google Chrome"]
        c.actions.suspendAtHigh = true
        c.actions.quitAtCritical = quit
        return c
    }

    private var chrome: AppGroup {
        makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app",
                  bytes: 4 * GiB, pids: [40000, 40001])
    }

    private var untouchable: AppGroup {
        makeGroup(name: "Xcode", bundle: "/Applications/Xcode.app",
                  bytes: 8 * GiB, pids: [40002])
    }

    func testNothingHappensBelowHigh() {
        for tier in [RiskTier.ok, .watch] {
            let plan = Guardian.plannedActions(
                tier: tier, groups: [chrome], config: armed(quit: true), suspendedKeys: []
            )
            XCTAssertTrue(plan.isEmpty, "aucune action attendue au niveau \(tier)")
        }
    }

    func testHighSuspendsOnlyManageable() {
        let plan = Guardian.plannedActions(
            tier: .high, groups: [chrome, untouchable],
            config: armed(quit: true), suspendedKeys: []
        )
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].group.name, "Google Chrome")
        XCTAssertEqual(plan[0].kind, .suspend)
    }

    /// Régression : les deux blocs se déclenchaient dans le même tour au niveau
    /// critique. La cible était gelée puis on lui demandait de quitter — un
    /// process gelé ne traite jamais cette demande, et la mémoire n'était
    /// jamais rendue.
    func testCriticalQuitsInsteadOfSuspending() {
        let plan = Guardian.plannedActions(
            tier: .critical, groups: [chrome], config: armed(quit: true), suspendedKeys: []
        )
        XCTAssertEqual(plan.map(\.kind), [.quit])
        XCTAssertFalse(plan.contains { $0.kind == .suspend })
    }

    /// Régression : une cible déjà suspendue au niveau « élevé » était exclue
    /// du filtre et n'était donc jamais quittée quand ça empirait. Or suspendre
    /// n'a rendu aucune mémoire.
    func testCriticalStillQuitsAnAlreadySuspendedTarget() {
        let frozen = makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app",
                               bytes: 4 * GiB, pids: [40000], suspended: true)
        let plan = Guardian.plannedActions(
            tier: .critical, groups: [frozen], config: armed(quit: true),
            suspendedKeys: [frozen.key]
        )
        XCTAssertEqual(plan.map(\.kind), [.quit])
    }

    func testCriticalFallsBackToSuspendWhenQuitDisabled() {
        let plan = Guardian.plannedActions(
            tier: .critical, groups: [chrome], config: armed(quit: false), suspendedKeys: []
        )
        XCTAssertEqual(plan.map(\.kind), [.suspend])
    }

    func testAlreadySuspendedIsNotSuspendedTwice() {
        let plan = Guardian.plannedActions(
            tier: .high, groups: [chrome], config: armed(quit: true),
            suspendedKeys: [chrome.key]
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testDisarmedPolicyNeverActs() {
        var c = Config()
        c.manageable = ["Google Chrome"] // liste blanche seule : n'arme rien
        for tier in RiskTier.allCases {
            XCTAssertTrue(
                Guardian.plannedActions(tier: tier, groups: [chrome], config: c,
                                        suspendedKeys: []).isEmpty
            )
        }
    }
}


// MARK: - Résumé de session

final class BriefTests: XCTestCase {
    private func brief(_ sample: MemorySample, config: Config = Config()) -> [String] {
        Brief.lines(
            sample: sample,
            assessment: RiskModel.assess(sample, thresholds: config.thresholds),
            groups: [makeGroup(name: "gateway.py", bytes: 36 * GiB, pids: [40000])],
            state: nil, config: config
        )
    }

    func testHealthyMachineIsOneLine() {
        let lines = brief(makeSample())
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("sain"))
    }

    func testTenseMachineExplainsAndSuggests() {
        let lines = brief(makeSample(app: 118 * GiB, cached: GiB / 2, free: GiB))
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("cause:") })
        XCTAssertTrue(lines.contains { $0.contains("plus gros:") })
    }

    /// La commande proposée doit être exécutable telle quelle.
    func testSuggestedReserveTargetParses() {
        let lines = brief(makeSample(app: 118 * GiB, cached: GiB / 2, free: GiB))
        guard let line = lines.first(where: { $0.contains("reserve") }) else {
            return XCTFail("aucune suggestion de libération")
        }
        let token = line
            .components(separatedBy: "reserve ")[1]
            .components(separatedBy: .whitespaces)[0]
        XCTAssertNotNil(Bytes.parse(token), "« \(token) » doit être analysable")
        XCTAssertGreaterThan(Bytes.parse(token) ?? 0, 0)
    }

    func testGuardSummaryReflectsArmedActions() {
        var c = Config()
        c.manageable = ["Google Chrome"]
        c.actions.suspendAtHigh = true
        c.actions.quitAtCritical = true
        let state = SharedState(
            date: Date(), tier: .ok, score: 0, summary: "", usedBytes: 0, totalBytes: 0,
            headroomBytes: 0, swapUsedBytes: 0, swapTotalBytes: 0,
            swapGrowthBytesPerSec: nil, kernelPressure: .normal, top: [], suspended: [],
            guardRunning: true, lastAction: nil
        )
        let summary = Brief.guardSummary(state: state, config: c)
        XCTAssertTrue(summary.contains("suspend+quit"), summary)
    }

    func testStaleStateReadsAsInactive() {
        let old = SharedState(
            date: Date(timeIntervalSinceNow: -600), tier: .ok, score: 0, summary: "",
            usedBytes: 0, totalBytes: 0, headroomBytes: 0, swapUsedBytes: 0,
            swapTotalBytes: 0, swapGrowthBytesPerSec: nil, kernelPressure: .normal,
            top: [], suspended: [], guardRunning: true, lastAction: nil
        )
        XCTAssertEqual(Brief.guardSummary(state: old, config: Config()), "garde inactif")
    }
}


// MARK: - Plafond par cible

final class ManagedTargetTests: XCTestCase {
    private func config(_ targets: [ManagedTarget]) -> Config {
        var c = Config()
        c.manageable = targets
        c.actions.suspendAtHigh = true
        c.actions.quitAtCritical = true
        return c
    }

    private var service: AppGroup {
        makeGroup(name: "acestep_service.py", bytes: 114 * GiB, pids: [40010])
    }

    func testShortFormDecodesWithoutCeiling() throws {
        let list = try JSONDecoder().decode(
            [ManagedTarget].self, from: Data(#"["Google Chrome"]"#.utf8)
        )
        XCTAssertEqual(list, [ManagedTarget(name: "Google Chrome", maxAction: .quit)])
    }

    func testLongFormDecodesTheCeiling() throws {
        let json = #"[{"name":"acestep_service.py","maxAction":"suspend"}]"#
        let list = try JSONDecoder().decode([ManagedTarget].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.maxAction, .suspend)
    }

    func testMixedFormsCoexist() throws {
        let json = #"["Google Chrome",{"name":"acestep_service.py","maxAction":"suspend"}]"#
        let list = try JSONDecoder().decode([ManagedTarget].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["Google Chrome", "acestep_service.py"])
        XCTAssertEqual(list.map(\.maxAction), [.quit, .suspend])
    }

    /// Une cible sans plafond se réécrit en forme courte, pour que la config
    /// reste lisible à la main.
    func testEncodingRoundTripsAndStaysTerse() throws {
        let list: [ManagedTarget] = ["Google Chrome",
                                     ManagedTarget(name: "acestep_service.py", maxAction: .suspend)]
        let data = try JSONEncoder().encode(list)
        XCTAssertEqual(try JSONDecoder().decode([ManagedTarget].self, from: data), list)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"Google Chrome\""))
    }

    /// Le cœur du réglage : un service respawné à la demande rechargerait son
    /// modèle si on le quittait, et repartirait aussi gros. On le gèle.
    func testCappedTargetIsSuspendedEvenAtCritical() {
        let c = config([ManagedTarget(name: "acestep_service.py", maxAction: .suspend)])
        let plan = Guardian.plannedActions(tier: .critical, groups: [service],
                                           config: c, suspendedKeys: [])
        XCTAssertEqual(plan.map(\.kind), [.suspend])
    }

    func testUncappedTargetIsStillQuitAtCritical() {
        let c = config([ManagedTarget(name: "acestep_service.py")])
        let plan = Guardian.plannedActions(tier: .critical, groups: [service],
                                           config: c, suspendedKeys: [])
        XCTAssertEqual(plan.map(\.kind), [.quit])
    }

    /// Une cible plafonnée et déjà gelée n'a plus rien à subir : surtout pas
    /// un arrêt déguisé.
    func testCappedAndAlreadySuspendedYieldsNothing() {
        let frozen = makeGroup(name: "acestep_service.py", bytes: 114 * GiB,
                               pids: [40010], suspended: true)
        let c = config([ManagedTarget(name: "acestep_service.py", maxAction: .suspend)])
        XCTAssertTrue(
            Guardian.plannedActions(tier: .critical, groups: [frozen],
                                    config: c, suspendedKeys: []).isEmpty
        )
    }

    func testCeilingSurvivesConfigRoundTrip() throws {
        var c = Config()
        c.manageable = ["Google Chrome",
                        ManagedTarget(name: "indexer_worker.py", maxAction: .suspend)]
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data), c)
    }
}


// MARK: - Proportionnalité

final class ProportionalityTests: XCTestCase {
    /// Le garde traite les plus gros d'abord : c'est la seule façon qu'une
    /// action unique suffise et que les autres cibles soient épargnées.
    func testPlanIsOrderedByFootprintDescending() {
        var c = Config()
        c.manageable = [
            ManagedTarget(name: "petit", maxAction: .suspend),
            ManagedTarget(name: "gros", maxAction: .suspend),
            ManagedTarget(name: "moyen", maxAction: .suspend),
        ]
        c.actions.suspendAtHigh = true
        let groups = [
            makeGroup(name: "petit", bytes: 2 * GiB, pids: [40001]),
            makeGroup(name: "gros", bytes: 100 * GiB, pids: [40002]),
            makeGroup(name: "moyen", bytes: 30 * GiB, pids: [40003]),
        ]
        let ordered = Guardian.plannedActions(
            tier: .high, groups: groups, config: c, suspendedKeys: []
        ).sorted { $0.group.footprintBytes > $1.group.footprintBytes }
        XCTAssertEqual(ordered.map(\.group.name), ["gros", "moyen", "petit"])
    }

    /// Trois services lourds armés ne doivent pas produire trois actions
    /// distinctes par tour au niveau élevé — le plan les liste tous, c'est
    /// l'exécution qui s'arrête dès que la pression retombe.
    func testAllEligibleTargetsArePlannedButOrdered() {
        var c = Config()
        c.manageable = [
            ManagedTarget(name: "acestep_service.py", maxAction: .suspend),
            ManagedTarget(name: "mlx_server_guarded.py", maxAction: .suspend),
            "indexer_worker.py",
        ]
        c.actions.suspendAtHigh = true
        c.actions.quitAtCritical = true
        let groups = [
            makeGroup(name: "acestep_service.py", bytes: 115 * GiB, pids: [40010]),
            makeGroup(name: "mlx_server_guarded.py", bytes: 36 * GiB, pids: [40011]),
            makeGroup(name: "indexer_worker.py", bytes: 34 * GiB, pids: [40012]),
        ]
        let plan = Guardian.plannedActions(
            tier: .critical, groups: groups, config: c, suspendedKeys: []
        )
        XCTAssertEqual(plan.count, 3)
        // Les deux plafonnés sont gelés, le batch est quitté.
        let byName = Dictionary(uniqueKeysWithValues: plan.map { ($0.group.name, $0.kind) })
        XCTAssertEqual(byName["acestep_service.py"], .suspend)
        XCTAssertEqual(byName["mlx_server_guarded.py"], .suspend)
        XCTAssertEqual(byName["indexer_worker.py"], .quit)
    }
}


// MARK: - Plancher d'action

final class MinActionTests: XCTestCase {
    private func armed() -> Config {
        var c = Config()
        c.manageable = ["Google Chrome"]
        c.actions.suspendAtHigh = true
        c.actions.quitAtCritical = true
        return c
    }

    /// Observé en production : Chrome, 345 Mio, gelé pendant qu'il manquait
    /// 100 Gio. L'utilisateur perd son navigateur, la machine ne gagne rien.
    func testTinyTargetIsLeftAlone() {
        let small = makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app",
                              bytes: 345 << 20, pids: [40020])
        for tier in [RiskTier.high, .critical] {
            XCTAssertTrue(
                Guardian.plannedActions(tier: tier, groups: [small], config: armed(),
                                        suspendedKeys: []).isEmpty,
                "une cible de 345 Mio ne doit pas être touchée au niveau \(tier)"
            )
        }
    }

    func testTargetAboveTheFloorIsStillActedOn() {
        let big = makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app",
                            bytes: 4 * GiB, pids: [40020])
        XCTAssertEqual(
            Guardian.plannedActions(tier: .high, groups: [big], config: armed(),
                                    suspendedKeys: []).map(\.kind),
            [.suspend]
        )
    }

    func testFloorIsConfigurable() {
        var c = armed()
        c.actions.minActionBytes = 100 << 20
        let small = makeGroup(name: "Google Chrome", bundle: "/Applications/Google Chrome.app",
                              bytes: 345 << 20, pids: [40020])
        XCTAssertEqual(
            Guardian.plannedActions(tier: .high, groups: [small], config: c,
                                    suspendedKeys: []).map(\.kind),
            [.suspend]
        )
    }
}
