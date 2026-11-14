// swift-tools-version: 6.0
//
//  Package.swift
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

import PackageDescription

#if canImport(Darwin)
let unicornBinaryTargets: [Target] = [
    .binaryTarget(
        name: "Unicorn",
        url: "https://github.com/mahee96/unicorn/releases/download/2.1.4-xcf-a53ddc9/Unicorn.xcframework.zip#AnisetteKit",
        checksum: "52e4ac9e2d704c4941adc2c381df8706aabf673dc843611a90b33ad349d562db"
    )
]
let unicornCoreDependencies: [Target.Dependency] = [
    "Unicorn"
]
let unicornLinkerSettings: [LinkerSetting] = []
#else
let unicornBinaryTargets: [Target] = []
let unicornCoreDependencies: [Target.Dependency] = []
let unicornLinkerSettings: [LinkerSetting] = [
    .linkedLibrary("unicorn")
]
#endif

let package = Package(
    name: "AnisetteKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AnisetteKit",
            targets: ["AnisetteKit"]
        )
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
                "LICENSE"
            ],
            sources: ["Sources"]
        ),
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
