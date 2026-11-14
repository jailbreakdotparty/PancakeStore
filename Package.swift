// swift-tools-version: 6.0
// Hand-written (idlproj.yml sets package_swift: false): idl's generated
// package cannot declare SwiftPM dependencies. Used by `idl build` via xtool.
import PackageDescription

let package = Package(
    name: "PancakeStore",
    platforms: [.iOS("16.4")],
    products: [.library(name: "PancakeStore", targets: ["PancakeStore"])],
    dependencies: [
        .package(url: "https://github.com/jailbreakdotparty/PartyUI", from: "1.1.3"),
        .package(url: "https://github.com/marmelroy/Zip.git", from: "2.1.2"),
        .package(path: "AnisetteKit"),
    ],
    targets: [
        .target(
            name: "PancakeStore",
            dependencies: [
                .product(name: "PartyUI", package: "PartyUI"),
                .product(name: "Zip", package: "Zip"),
                .product(name: "MacAnisetteKit", package: "AnisetteKit"),
                .product(name: "SAPKit", package: "AnisetteKit"),
            ],
            path: "MuffinStoreJailed",
            // Localizations are copied to the app root by xtool (idlproj.yml
            // resources) so String(localized:) keeps using Bundle.main.
            exclude: ["Assets", "bridge.h"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
