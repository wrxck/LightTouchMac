#!/bin/bash
# build-helper.sh APP OUT: builds LightTouchDevice with SwiftPM (no Xcode project, so any Xcode with Swift 6 builds
# it), unsandboxed and signed ad hoc, at OUT/Contents/MacOS, beside OUT/Contents/Frameworks linked to APP's: the
# helper loads APP's libqemu-arm.dylib as the bundled one does. Not a release build (scripts/ship makes those).
set -euo pipefail
if [ $# -ne 2 ]; then
    echo "usage: $0 'Light Touch.app' OUT" >&2
    exit 64
fi
APP=$(cd "$1" && pwd)
OUT=$2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PKG=$ROOT/tools/headless/.build/helper-package
rm -rf "$PKG/Sources"
mkdir -p "$PKG/Sources/LightTouchDevice" "$PKG/Sources/GuestTLS/include"
# the helper's sources as they are: its C (GuestTLS) becomes a module the bridging header imports
for f in "$ROOT"/LightTouchDevice/*.swift; do ln -s "$f" "$PKG/Sources/LightTouchDevice/"; done
ln -s "$ROOT/LightTouchDevice/GuestTLS.c" "$PKG/Sources/GuestTLS/GuestTLS.c"
ln -s "$ROOT/LightTouchDevice/GuestTLS.h" "$PKG/Sources/GuestTLS/include/GuestTLS.h"
cat > "$PKG/Package.swift" <<PKG
// swift-tools-version: 6.0
// Written by tools/headless/build-helper.sh.
import PackageDescription

let package = Package(
    name: "LightTouchDeviceHelper",
    platforms: [.macOS("14.4")],
    dependencies: [.package(path: "$ROOT/Packages/HostRuntime"), .package(path: "$ROOT/Packages/DeviceRuntime")],
    targets: [
        .target(name: "GuestTLS", linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "LightTouchDevice",
            dependencies: [
                "GuestTLS", .product(name: "HostRuntime", package: "HostRuntime"),
                .product(name: "DeviceRuntime", package: "DeviceRuntime"),
            ],
            swiftSettings: [.unsafeFlags(["-import-objc-header", "$PKG/Sources/GuestTLS/include/GuestTLS.h"])]
        ),
    ]
)
PKG
swift build -c release --package-path "$PKG"
mkdir -p "$OUT/Contents/MacOS"
cp "$PKG/.build/release/LightTouchDevice" "$OUT/Contents/MacOS/LightTouchDevice"
ln -sfn "$APP/Contents/Frameworks" "$OUT/Contents/Frameworks"
# no hardened runtime: library validation stays off, so the app's Developer ID dylib loads into an ad hoc helper
codesign -f -s - --entitlements "$ROOT/Configuration/LightTouchDevice.entitlements" "$OUT/Contents/MacOS/LightTouchDevice"
echo "$OUT/Contents/MacOS/LightTouchDevice"
