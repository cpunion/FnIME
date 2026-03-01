// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FnIME",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "fn-ime", targets: ["FnIME"])
    ],
    targets: [
        .executableTarget(
            name: "FnIME",
            path: "Sources/FnIME"
        ),
        .testTarget(
            name: "FnIMETests",
            dependencies: [],
            path: "Tests/FnIMETests"
        )
    ]
)
