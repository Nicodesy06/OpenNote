// swift-tools-version: 5.10
import PackageDescription

// Motori di trascrizione sul dispositivo. Separato da QuadernoCore perché
// dipende da CoreML (solo piattaforme Apple) e da pacchetti esterni:
// QuadernoCore resta compilabile e testabile anche su Linux.
let package = Package(
    name: "QuadernoOnDevice",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "QuadernoOnDevice", targets: ["QuadernoOnDevice"])
    ],
    dependencies: [
        .package(path: "../QuadernoCore"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "QuadernoOnDevice",
            dependencies: [
                .product(name: "QuadernoCore", package: "QuadernoCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        )
    ]
)
