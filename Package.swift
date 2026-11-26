// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "CLAYCore", targets: ["CLAYCore"]),
    .executable(name: "clay-portable", targets: ["clay-portable"])
]
var platformTargets: [Target] = []
var portableDependencies: [Target.Dependency] = ["CLAYCore"]
let excludedCoreSources: [String]
// Swift's Windows Clang importer must see the same static declarations as CYaml.
#if os(Windows)
let coreSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DYAML_DECLARE_STATIC"])]
#else
let coreSwiftSettings: [SwiftSetting] = []
#endif

#if os(macOS)
excludedCoreSources = []
products += [.executable(name: "CLAY", targets: ["CLAY"]), .executable(name: "clayctl", targets: ["clayctl"])]
platformTargets = [
    .executableTarget(name: "CLAY", dependencies: ["CLAYCore"]),
    .executableTarget(name: "clayctl", dependencies: ["CLAYCore"]),
    .executableTarget(name: "CLAYCoreChecks", dependencies: ["CLAYCore"], path: "Tests/CLAYCoreChecks")
]
#else
// The desktop runtime, Apple PAC services and subscription networking remain
// macOS-only. The CLI uses the shared offline parsers and PAC generator.
excludedCoreSources = ["PACServer.swift", "Runtime.swift", "Subscriptions.swift", "SystemPAC.swift"]
#endif

#if os(Windows)
portableDependencies.append("CWindowsRuntime")
platformTargets.append(.target(name: "CWindowsRuntime", linkerSettings: [
    .linkedLibrary("Advapi32"), .linkedLibrary("Bcrypt"), .linkedLibrary("Iphlpapi"),
    .linkedLibrary("Ole32"), .linkedLibrary("Shell32"), .linkedLibrary("Ws2_32")
]))
#endif

let package = Package(
    name: "CLAY", platforms: [.macOS(.v13), .iOS(.v16)], products: products,
    targets: [
        .target(name: "CYaml", path: "Vendor/Yams/Sources/CYaml", exclude: ["CMakeLists.txt"],
                cSettings: [.define("YAML_DECLARE_STATIC")]),
        .target(name: "CLAYCore", dependencies: ["CYaml"], exclude: excludedCoreSources, swiftSettings: coreSwiftSettings),
        .executableTarget(name: "clay-portable", dependencies: portableDependencies)
    ] + platformTargets
)
