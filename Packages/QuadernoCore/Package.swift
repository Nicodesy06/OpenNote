// swift-tools-version:5.10
// QuadernoCore: logica di dominio indipendente dalla piattaforma.
// Compila su iPadOS, macOS e Linux, così che pianificazione dei chunk, merge
// delle trascrizioni, client AI, pipeline di sbobinatura ed export siano
// testabili senza simulatore e senza spendere crediti API.
import PackageDescription

let package = Package(
    name: "QuadernoCore",
    defaultLocalization: "it",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuadernoCore", targets: ["QuadernoCore"])
    ],
    targets: [
        .target(
            name: "QuadernoCore",
            resources: [
                .copy("Resources/prompts")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "QuadernoCoreTests",
            dependencies: ["QuadernoCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
