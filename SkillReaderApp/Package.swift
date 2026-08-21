// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SkillReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SkillReader", targets: ["SkillReader"])
    ],
    targets: [
        .executableTarget(
            name: "SkillReader",
            path: "Sources/SkillReader",
            resources: [
                .process("Resources/web")
            ]
        )
    ]
)
