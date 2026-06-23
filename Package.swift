// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

var defaultSwiftSettings: [SwiftSetting] = [
    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md
    .enableUpcomingFeature("ExistentialAny"),

    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
    .enableUpcomingFeature("InternalImportsByDefault"),

]

#if compiler(>=6.1)
// Member import visibility strengthens diagnostics when the active compiler
// supports SE-0444 without raising the package's minimum Swift version.
defaultSwiftSettings.append(
    .enableUpcomingFeature("MemberImportVisibility")
)
#endif

let package = Package(
    name: "swift-zip-archive",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15)],
    products: [
        .library(name: "ZipArchive", targets: ["ZipArchive"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0")
    ],
    targets: [
        .target(name: "CZipArchiveZlib"),
        .target(
            name: "ZipArchive",
            dependencies: [
                "CZipArchiveZlib",
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .testTarget(
            name: "ZipArchiveTests",
            dependencies: ["ZipArchive"],
            resources: [.process("resources")]
        ),
    ]
)

if let target = package.targets.filter({ $0.name == "CZipZlib" }).first {
    #if os(Windows)
    if ProcessInfo.processInfo.environment["ZIP_USE_DYNAMIC_ZLIB"] == nil {
        target.cSettings?.append(contentsOf: [.define("ZLIB_STATIC")])
        target.linkerSettings = [.linkedLibrary("zlibstatic")]
    } else {
        target.linkerSettings = [.linkedLibrary("zlib")]
    }
    #else
    target.linkerSettings = [.linkedLibrary("z")]
    #endif
}
