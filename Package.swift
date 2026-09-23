// swift-tools-version:5.9
import PackageDescription

// The speech recogniser is the C + Metal runtime in ../nemoasr-c, built as a static library
// (`make -C ../nemoasr-c lib`). Scripts/bundle.sh does that and assembles the .app.
let nemo = "\(Context.packageDirectory)/../nemoasr-c"
let link: [LinkerSetting] = [
    .unsafeFlags(["-L\(nemo)/build"]),
    .linkedLibrary("nemoasr"),
    .linkedFramework("Metal"),
    .linkedFramework("Foundation"),
]

let package = Package(
    name: "NemoDictate",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CNemoASR", path: "Sources/CNemoASR"),
        .target(name: "NemoAudio", path: "Sources/NemoAudio", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "NemoCaret", path: "Sources/NemoCaret", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices")]),
        .executableTarget(
            name: "NemoDictate",
            dependencies: ["CNemoASR", "NemoAudio", "NemoCaret"],
            path: "Sources/NemoDictate",
            linkerSettings: link + [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("AVFoundation"), .linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "nemo-feed",
            dependencies: ["CNemoASR", "NemoAudio"],
            path: "Sources/nemo-feed",
            linkerSettings: link + [.linkedFramework("AVFoundation")]
        ),
    ]
)
