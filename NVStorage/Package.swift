// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NVStorage",
    platforms: [.macOS("11.5")],
    products: [.library(name: "NVStorageCore", targets: ["NVStorageCore"]),
               .library(name: "NVStorageRuntime", targets: ["NVStorageRuntime"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
    ],
    targets: [
        .target(name: "CArgon2", path: "Vendor/Argon2", exclude: ["LICENSE", "README.nv.md"],
                sources: ["src/argon2.c", "src/core.c", "src/blake2/blake2b.c", "src/thread.c", "src/encoding.c", "src/ref.c"],
                publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .define("ARGON2_NO_THREADS")]),
        .target(name: "CZstd", path: "Vendor/Zstd", exclude: ["LICENSE", "README.nv.md", "lib/decompress/huf_decompress_amd64.S"],
                sources: ["lib/common", "lib/compress", "lib/decompress"],
                publicHeadersPath: "include", cSettings: [.define("ZSTD_DISABLE_ASM"), .define("ZSTD_LEGACY_SUPPORT", to: "0")]),
        .systemLibrary(name: "CSQLCipher", pkgConfig: "sqlcipher"),
        .target(name: "CStorageIO"),
        .target(name: "NVStorageCore", dependencies: [
            "CArgon2",
            "CZstd",
            .product(name: "Crypto", package: "swift-crypto")
        ], swiftSettings: [.strictMemorySafety(), .treatAllWarnings(as: .error)]),
        .target(name: "NVStorageRuntime", dependencies: ["NVStorageCore", "CSQLCipher", "CStorageIO",
            .product(name: "Crypto", package: "swift-crypto")], resources: [.copy("Resources")],
            swiftSettings: [.strictMemorySafety(), .treatAllWarnings(as: .error)]),
        .testTarget(name: "NVStorageCoreTests", dependencies: ["NVStorageCore"], resources: [.copy("Fixtures")]),
        .target(name: "CStorageFaults", dependencies: ["CSQLCipher"], path: "Tests/Support/CStorageFaults"),
        .executableTarget(name: "NVStorageProbe", dependencies: ["NVStorageRuntime", "CStorageFaults", "CSQLCipher"], path: "Tests/Support/NVStorageProbe"),
        .testTarget(name: "NVStorageRuntimeTests", dependencies: ["NVStorageRuntime", "CSQLCipher", "CStorageFaults"])
    ],
    swiftLanguageModes: [.v6]
)
