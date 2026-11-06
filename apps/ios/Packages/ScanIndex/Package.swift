// swift-tools-version:5.9
import PackageDescription

/* The scanner's name index (ScanNames in Table1/Library/CardMatcher.swift), on its own so it's built with
   optimization in every configuration: ~200k names take ~0.2 s optimized and 5 s at -Onone, and Xcode has no
   per-file optimization for Swift. A local package may use unsafeFlags. */
let package = Package(
    name: "ScanIndex",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ScanIndex", targets: ["ScanIndex"])],
    targets: [
        .target(name: "ScanIndex", swiftSettings: [.unsafeFlags(["-O"])]),
        .testTarget(name: "ScanIndexTests", dependencies: ["ScanIndex"]),
    ]
)
