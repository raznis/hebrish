// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LayoutFix",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: layout derivation, transliteration, lexicon, scoring.
        // No AppKit, no event taps — everything here is unit-testable.
        .target(name: "LayoutFixCore"),

        // The menu-bar agent.
        .executableTarget(name: "LayoutFixApp", dependencies: ["LayoutFixCore"]),

        // Build-time tool: frequency lists -> Resources/lexicon.bin
        .executableTarget(name: "BakeLexicon", dependencies: ["LayoutFixCore"]),

        // Offline calibration harness (FPR / recall sweep over the threshold).
        .executableTarget(name: "LayoutFixEval", dependencies: ["LayoutFixCore"]),

        .testTarget(name: "LayoutFixCoreTests", dependencies: ["LayoutFixCore"]),
    ]
)
