// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VPhonePort",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "FirmwarePatcher", targets: ["FirmwarePatcher"]),
               .executable(name: "monolith-fw", targets: ["monolith-fw"])],
    dependencies: [
        .package(url: "https://github.com/p-x9/MachOKit.git", exact: "0.54.1"),
        .package(url: "https://github.com/Lakr233/libimg4-spm.git", exact: "0.1.1"),
        .package(url: "https://github.com/Lakr233/libcapstone-spm.git", exact: "0.1.3"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.3.1"),
    ],
    targets: [
        // MONOLITH: Monolith's own APFS code (apfs/ at the repository's top), for guest volumes on iOS.
        .target(name: "MonolithAPFS", cSettings: [.unsafeFlags(["-Wno-unused-function"])],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("compression")]),
        .target(name: "VPhonePatchKit", dependencies: [.product(name: "Capstone", package: "libcapstone-spm")]),
        .target(name: "VPhoneSign"),
        .target(name: "VPhoneArchiveKit", dependencies: ["VPhoneCoreKit", .product(name: "ArchiveKit", package: "libarchive.xcframework")]),
        .target(name: "VPhoneCoreKit", dependencies: ["MonolithAPFS", .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                                                      .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        // MONOLITH: vphone-cli's custom-firmware installer and what it needs from the command target.
        .target(name: "VPhoneInstaller", dependencies: ["VPhoneCoreKit", "FirmwarePatcher", "VPhonePatchKit", "VPhoneSign", "VPhoneArchiveKit",
                                                        .product(name: "ArgumentParser", package: "swift-argument-parser"),
                                                        .product(name: "MachOKit", package: "MachOKit"),
                                                        .product(name: "Img4tool", package: "libimg4-spm")]),
        .executableTarget(name: "monolith-fw", dependencies: ["VPhoneCoreKit", "FirmwarePatcher", "VPhoneInstaller"]),
        .target(name: "FirmwarePatcher", dependencies: ["VPhonePatchKit", "VPhoneSign", "VPhoneCoreKit", "VPhoneArchiveKit",
                                                        .product(name: "MachOKit", package: "MachOKit"),
                                                        .product(name: "Img4tool", package: "libimg4-spm"),
                                                        .product(name: "Capstone", package: "libcapstone-spm")],
                exclude: ["KernelCache/KDK/LICENSE"]),
    ],
    swiftLanguageModes: [.v5]
)
