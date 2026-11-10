// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "WoowAssistantCore",
    platforms: [.macOS(.v13), .iOS("17.0")],
    products: [
        .library(name: "AssistantContracts", targets: ["AssistantContracts"]),
        .library(name: "AssistantDomain", targets: ["AssistantDomain"]),
        .library(name: "AssistantBrowser", targets: ["AssistantBrowser"]),
        .library(name: "AssistantModels", targets: ["AssistantModels"]),
        .library(name: "AssistantMCP", targets: ["AssistantMCP"]),
        .library(name: "AssistantMemory", targets: ["AssistantMemory"]),
        .library(name: "AssistantSkills", targets: ["AssistantSkills"]),
        .library(name: "AssistantPersistence", targets: ["AssistantPersistence"])
    ],
    targets: [
        .target(name: "AssistantContracts", path: "Sources/AssistantContracts"),
        .target(
            name: "AssistantDomain",
            dependencies: ["AssistantContracts"],
            path: "Sources/AssistantDomain"
        ),
        .target(name: "AssistantBrowser", dependencies: ["AssistantModels", "AssistantSkills"], path: "Sources/AssistantBrowser"),
        .target(name: "AssistantModels", path: "Sources/AssistantModels"),
        .target(name: "AssistantMCP", dependencies: ["AssistantModels"], path: "Sources/AssistantMCP"),
        .target(name: "AssistantMemory", dependencies: ["AssistantModels"], path: "Sources/AssistantMemory"),
        .target(name: "AssistantSkills", dependencies: ["AssistantModels"], path: "Sources/AssistantSkills", resources: [.process("Resources")]),
        .target(name: "AssistantPersistence", path: "Sources/AssistantPersistence"),
        .testTarget(name: "AssistantMemoryTests", dependencies: ["AssistantMemory", "AssistantModels"], path: "Tests/AssistantMemoryTests"),
        .testTarget(name: "AssistantSkillsTests", dependencies: ["AssistantSkills", "AssistantModels", "AssistantPersistence"], path: "Tests/AssistantSkillsTests"),
        .testTarget(name: "AssistantPersistenceTests", dependencies: ["AssistantPersistence"], path: "Tests/AssistantPersistenceTests"),
        .testTarget(name: "AssistantMCPTests", dependencies: ["AssistantMCP", "AssistantModels"], path: "Tests/AssistantMCPTests"),
        .testTarget(name: "AssistantModelsTests", dependencies: ["AssistantModels"], path: "Tests/AssistantModelsTests"),
        .testTarget(
            name: "AssistantDomainTests",
            dependencies: ["AssistantContracts", "AssistantDomain", "AssistantBrowser", "AssistantModels"],
            path: "Tests/AssistantDomainTests"
        )
    ]
)
