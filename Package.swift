// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RepoAtlas",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RepoAtlasApp", targets: ["RepoAtlasApp"])
    ],
    targets: [
        .executableTarget(
            name: "RepoAtlasApp",
            resources: [
                .copy("Resources/DeepSeekConfig.plist.template")
            ]
        )
    ]
)
