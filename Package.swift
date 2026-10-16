// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkBuddySessionManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WorkBuddySessionManager",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
