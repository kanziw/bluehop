// swift-tools-version:5.10
// 외부 의존성 0개 — dependencies 를 추가하지 않는다 (AGENTS.md "절대 규칙").
import PackageDescription

let package = Package(
    name: "bluehop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bluehop", targets: ["BluehopCLI"]),
    ],
    targets: [
        .target(
            name: "BluehopCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BluehopCLI",
            dependencies: ["BluehopCore"]
        ),
        .testTarget(
            name: "BluehopCoreTests",
            dependencies: ["BluehopCore"]
        ),
    ]
)
