// swift-tools-version: 6.0
//
//  Package.swift
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import PackageDescription

// Select Unicorn by the *target* platform, not the host evaluating this
// manifest: a Linux host cross-compiling for iOS (xtool) needs the
// XCFramework, while a native Linux build links the system libunicorn.
let applePlatforms: [Platform] = [.iOS, .macOS, .tvOS, .visionOS, .macCatalyst]
let unicornBinaryTargets: [Target] = [
    .binaryTarget(
        name: "Unicorn",
        url: "https://github.com/mahee96/unicorn/releases/download/2.1.4-xcf-a53ddc9/Unicorn.xcframework.zip#AnisetteKit",
        checksum: "52e4ac9e2d704c4941adc2c381df8706aabf673dc843611a90b33ad349d562db"
    )
]
let unicornCoreDependencies: [Target.Dependency] = [
    .target(name: "Unicorn", condition: .when(platforms: applePlatforms))
]
let unicornLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("unicorn", .when(platforms: [.linux, .windows, .android]))
]

let package = Package(
    name: "AnisetteKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "AnisetteKit", targets: ["AnisetteKit"]),
        .library(name: "MacAnisetteKit", targets: ["MacAnisetteKit"]),
        .library(name: "SAPKit", targets: ["SAPKit"]),
        .library(name: "FairPlayKit", targets: ["FairPlayKit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "anisette_core",
            dependencies: unicornCoreDependencies,
            path: "Native",
            cSettings: [
                .headerSearchPath(".")
            ],
            linkerSettings: unicornLinkerSettings
        ),
        .target(
            name: "AnisetteKit",
            dependencies: [
                "anisette_core"
            ],
            path: ".",
            exclude: [
                "Package.swift",
                "Native", 
                "Tests",
                "README.md",
                "LICENSE",
                "MacADI",
                "Binaries",
                "SourcesMac",
                "SourcesSAP",
                "NativeStore"
            ],
            sources: ["Sources"]
        ),
        .binaryTarget(name: "MacADICore", path: "Binaries/MacADICore.xcframework"),
        .target(name: "NativeStore", path: "NativeStore", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .target(name: "FairPlayKit", path: "FairPlayKit", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "MacAnisetteKit", dependencies: ["MacADICore", "NativeStore"], path: "SourcesMac", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SAPKit", dependencies: ["MacADICore"], path: "SourcesSAP", exclude: ["LICENSE"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedLibrary("bz2"), .linkedLibrary("z")]),
        .testTarget(
            name: "AnisetteKitTests",
            dependencies: [
                "AnisetteKit"
            ],
            path: "Tests"
        )
    ] + unicornBinaryTargets,
    cxxLanguageStandard: .cxx17
)
