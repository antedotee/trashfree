// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrashFree",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TrashFreeApp", targets: ["TrashFreeApp"]),
        .executable(name: "tfscan", targets: ["tfscan"]),
        .library(name: "TrashFreeCore", targets: ["TrashFreeCore"]),
        .library(name: "TrashFreeUI", targets: ["TrashFreeUI"]),
    ],
    targets: [
        .executableTarget(
            name: "TrashFreeApp",
            dependencies: ["TrashFreeUI", "TrashFreeCore"],
            path: "TrashFreeApp"),
        .executableTarget(
            name: "tfscan",
            dependencies: ["TrashFreeCore"],
            path: "Tools/tfscan"),
        .target(
            name: "TrashFreeCore",
            path: "Sources/TrashFreeCore"),
        .target(
            name: "TrashFreeUI",
            dependencies: ["TrashFreeCore"],
            path: "Sources/TrashFreeUI"),
        .testTarget(
            name: "TrashFreeTests",
            dependencies: ["TrashFreeCore"],
            path: "Tests"),
    ]
)
