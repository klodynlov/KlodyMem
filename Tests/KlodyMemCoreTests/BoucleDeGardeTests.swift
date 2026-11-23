import XCTest
@testable import KlodyMemCore

/// La boucle de garde ne doit pas grossir d'un tour à l'autre.
///
/// Vécu le 2026-11-23 : `klodymem guard` à 11,9 Gio après 15 jours (sondage
/// toutes les 5 s, ~263 000 tours, ~45 Ko perdus par tour) — un garde-fou
/// mémoire devenu le 4ᵉ consommateur de la machine. Cause : aucun
/// `autoreleasepool` autour du tour, dans un CLI sans run loop.
final class BoucleDeGardeTests: XCTestCase {
    /// Empreinte physique du processus de test (celle que lit `klodymem top`).
    private static func empreinte() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func testLaBoucleFaitLeNombreDeToursDemande() {
        var tours = 0
        Guardian.boucle(tours: 7, intervalle: 0) { tours += 1 }
        XCTAssertEqual(tours, 7)
        Guardian.boucle(tours: 0, intervalle: 0) { XCTFail("zéro tour demandé") }
    }

    func testLaBoucleAttendEntreDeuxTours() {
        let debut = Date()
        Guardian.boucle(tours: 3, intervalle: 0.05) {}
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(debut), 0.14)
    }

    /// Le travail réel d'un tour (inventaire des process + échantillon), rejoué
    /// 400 fois. Mesuré : 50 145 octets par tour sans pool, ~480 avec. Le
    /// plafond de 8 Ko par tour laisse un facteur 16 au bruit de l'allocateur
    /// et reste 6 fois sous la fuite.
    func testUnTourNeLaisseRienDerriereLui() {
        let sampler = MemorySampler()
        let travail = {
            _ = ProcessInventory.currentGroups()
            _ = sampler.sample()
        }
        Guardian.boucle(tours: 40, intervalle: 0, travail)   // amorce les caches
        let avant = Self.empreinte()
        XCTAssertGreaterThan(avant, 0, "empreinte illisible : le test ne jugerait rien")
        let tours = 400
        Guardian.boucle(tours: tours, intervalle: 0, travail)
        let apres = Self.empreinte()
        let parTour = (Int64(apres) - Int64(avant)) / Int64(tours)
        XCTAssertLessThan(parTour, 8_192,
            "la boucle de garde perd \(parTour) octets par tour")
    }
}
