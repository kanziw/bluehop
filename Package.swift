// swift-tools-version:5.10
// 외부 의존성 0개 — dependencies 를 추가하지 않는다 (AGENTS.md "절대 규칙").
import PackageDescription

let package = Package(
    name: "imsg-relay",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "imsg-relay", targets: ["ImsgRelayCLI"]),
    ],
    targets: [
        .target(
            name: "ImsgRelayCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ImsgRelayCLI",
            dependencies: ["ImsgRelayCore"]
        ),
        .testTarget(
            name: "ImsgRelayCoreTests",
            dependencies: ["ImsgRelayCore"]
        ),
    ]
)
