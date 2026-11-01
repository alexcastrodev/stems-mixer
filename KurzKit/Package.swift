// swift-tools-version: 6.0
import PackageDescription

// Camadas, de dentro para fora: Core (dominio, sem dependencias) <- Audio (mixer) e Data (servidor e disco) <- Presentation (casos de uso das vistas).
// As dependencias declaradas aqui sao a regra: um modulo nao consegue importar o que nao declara.
let package = Package(
    name: "KurzKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "KurzCore", targets: ["KurzCore"]),
        .library(name: "KurzAudio", targets: ["KurzAudio"]),
        .library(name: "KurzData", targets: ["KurzData"]),
        .library(name: "KurzPresentation", targets: ["KurzPresentation"]),
    ],
    targets: [
        .target(name: "KurzCore"),
        .target(name: "KurzAudio", dependencies: ["KurzCore"]),
        .target(name: "KurzData", dependencies: ["KurzCore"]),
        .target(name: "KurzPresentation", dependencies: ["KurzCore", "KurzAudio", "KurzData"]),
        .testTarget(name: "KurzCoreTests", dependencies: ["KurzCore"]),
        .testTarget(name: "KurzAudioTests", dependencies: ["KurzAudio"], resources: [.copy("Fixtures")]),
        .testTarget(name: "KurzDataTests", dependencies: ["KurzData"], resources: [.copy("Fixtures")]),
        .testTarget(name: "KurzPresentationTests", dependencies: ["KurzPresentation"]),
    ],
    swiftLanguageModes: [.v5]
)
