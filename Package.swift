// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UnificadorVR",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UnificadorVR", targets: ["UnificadorVR"]),
        .library(name: "UnificadorCore", targets: ["UnificadorCore"]),
    ],
    targets: [
        // Núcleo de lógica: só Foundation, sem UI. Compila e testa também no Linux.
        .target(name: "UnificadorCore"),
        // Interface SwiftUI (macOS).
        .executableTarget(name: "UnificadorVR", dependencies: ["UnificadorCore"]),
        .testTarget(name: "UnificadorCoreTests", dependencies: ["UnificadorCore"]),
    ]
)
