// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CLAYAndroid",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CLAYAndroidBridge", type: .dynamic, targets: ["CLAYAndroidBridge"])],
    dependencies: [.package(name: "CLAY", path: "../..")],
    targets: [.target(name: "CLAYAndroidBridge", dependencies: [.product(name: "CLAYCore", package: "CLAY")])]
)
