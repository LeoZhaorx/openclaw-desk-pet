// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskSprite",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "desk-sprite", targets: ["DeskSprite"])
    ],
    targets: [
        .executableTarget(
            name: "DeskSprite",
            path: "Sources/DeskSprite"
        )
    ]
)
