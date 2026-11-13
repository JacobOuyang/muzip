// swift-tools-version: 5.9
// MuZip for iPhone: open this folder in Xcode (File > Open... > MuZipPhone.swiftpm), pick your iPhone, Run.
// It shares MuZipCore (the codes, the sketch and close-ups, one question's loop) with the Mac app in ../MuZip.
import AppleProductTypes
import PackageDescription

let package = Package(
    name: "MuZipPhone",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "MuZip",
            targets: ["AppModule"],
            bundleIdentifier: "app.muzip.phone",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .asset("AppIcon"),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.phone],
            supportedInterfaceOrientations: [.portrait],
            capabilities: [
                .camera(purposeString: "MuZip takes the photo you ask about. The photo stays on your iPhone."),
                .photoLibrary(purposeString: "MuZip can ask about a photo you already took. It stays on your iPhone."),
                .localNetwork(purposeString: "MuZip's Simulated and WhatsApp modes talk to the MuZip simulator on your Mac."),
            ],
            additionalInfoPlistContentFilePath: "Info.plist"
        ),
    ],
    dependencies: [.package(path: "../MuZip")],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [.product(name: "MuZipCore", package: "MuZip")],
            path: ".",
            exclude: ["Info.plist"]
        ),
    ]
)
