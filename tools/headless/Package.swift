// swift-tools-version: 6.0
// ltm-boot: a LightTouchDevice headless config for a prepared base (tools/headless/README.md).
import PackageDescription

let package = Package(
    name: "Headless",
    platforms: [.macOS("14.4")],
    dependencies: [.package(path: "../../Packages/HostRuntime")],
    targets: [
        .executableTarget(name: "ltm-boot", dependencies: [.product(name: "HostRuntime", package: "HostRuntime")])
    ]
)
