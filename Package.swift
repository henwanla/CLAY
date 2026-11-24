// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "CLAY", platforms: [.macOS(.v13)],
    products: [.executable(name: "CLAY", targets: ["CLAY"]), .executable(name: "clayctl", targets: ["clayctl"])],
    targets: [
        .target(name: "CYaml", path: "Vendor/Yams/Sources/CYaml", exclude: ["CMakeLists.txt"],
                cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "CLAYCore", dependencies: ["CYaml"]),
        .executableTarget(name: "CLAY", dependencies: ["CLAYCore"]),
        .executableTarget(name: "clayctl", dependencies: ["CLAYCore"]),
        .executableTarget(name: "CLAYCoreChecks", dependencies: ["CLAYCore"], path: "Tests/CLAYCoreChecks")
    ]
)
