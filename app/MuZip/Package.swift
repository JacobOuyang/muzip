// swift-tools-version:5.9
// MuZip for Mac (and, sharing MuZipCore, the iPhone app): the phone's side of the loop. See README.md.
import PackageDescription

let package = Package(
    name: "MuZip",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MuZipCore", targets: ["MuZipCore"]),
        .executable(name: "MuZip", targets: ["MuZip"]),
        .executable(name: "muzip-cli", targets: ["muzip-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", exact: "1.6.0"),
    ],
    targets: [
        .target(name: "MuZipCore", dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")]),
        .executableTarget(name: "MuZip", dependencies: ["MuZipCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "muzip-cli", dependencies: ["MuZipCore"]),
    ]
)
