// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "klodymem",
    platforms: [.macOS(.v14)],
    targets: [
        // Échantillonnage mémoire, inventaire process, politique et actions.
        .target(
            name: "KlodyMemCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI + daemon de garde (utilisateur, pas de root).
        .executableTarget(
            name: "klodymem",
            dependencies: ["KlodyMemCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation")
            ]
        ),
        // Moniteur menu-bar — lit l'état, déclenche les actions manuelles.
        .executableTarget(
            name: "klodymem-bar",
            dependencies: ["KlodyMemCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "KlodyMemCoreTests",
            dependencies: ["KlodyMemCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
