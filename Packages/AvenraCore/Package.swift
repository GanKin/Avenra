// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AvenraCore",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "AvenraCore", targets: ["AvenraCore"]),
        // A smoke check that actually calls the model providers. Not a test
        // target: it needs credentials and a network, so it must be runnable
        // deliberately rather than as part of `swift test`.
        .executable(name: "provider-check", targets: ["ProviderCheck"]),
    ],
    dependencies: [
        // Apple's cmark-gfm based Markdown parser. Gives us GitHub Flavored Markdown
        // (tables, strikethrough, task lists, autolinks) for free; Obsidian-specific
        // syntax (wikilinks, highlights, callouts, block refs) is layered on top.
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        // YAML parsing for note frontmatter.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // EPUB is a ZIP of XHTML; Foundation has no archive reader.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "AvenraCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                "Yams",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ProviderCheck",
            dependencies: ["AvenraCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AvenraCoreTests",
            dependencies: [
                "AvenraCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
