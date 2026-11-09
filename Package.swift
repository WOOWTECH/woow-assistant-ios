// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "WoowAssistantCore",
    platforms: [.macOS(.v13), .iOS("17.0")],
    products: [
        .library(name: "AssistantContracts", targets: ["AssistantContracts"]),
        .library(name: "AssistantDomain", targets: ["AssistantDomain"]),
        .library(name: "AssistantBrowser", targets: ["AssistantBrowser"])
    ],
    targets: [
        .target(name: "AssistantContracts", path: "Sources/AssistantContracts"),
        .target(
            name: "AssistantDomain",
            dependencies: ["AssistantContracts"],
            path: "Sources/AssistantDomain"
        ),
        .target(name: "AssistantBrowser", path: "Sources/AssistantBrowser"),
        .testTarget(
            name: "AssistantDomainTests",
            dependencies: ["AssistantContracts", "AssistantDomain", "AssistantBrowser"],
            path: "Tests/AssistantDomainTests"
        )
    ]
)
