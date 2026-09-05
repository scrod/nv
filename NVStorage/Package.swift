// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NVStorage",
    platforms: [.macOS("11.5")],
    products: [.library(name: "NVStorageCore", targets: ["NVStorageCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
    ],
    targets: [
        .target(name: "NVStorageCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "NVStorageCoreTests", dependencies: ["NVStorageCore"])
    ]
)
