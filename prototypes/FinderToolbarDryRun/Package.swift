// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "FinderToolbarDryRun",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "finder-toolbar-dry-run", targets: ["FinderToolbarDryRun"]),
        .executable(name: "finder-toolbar-dry-run-self-test", targets: ["FinderToolbarDryRunSelfTest"])
    ],
    targets: [
        .target(name: "FinderToolbarDryRunCore"),
        .executableTarget(
            name: "FinderToolbarDryRun",
            dependencies: ["FinderToolbarDryRunCore"]
        ),
        .executableTarget(
            name: "FinderToolbarDryRunSelfTest",
            dependencies: ["FinderToolbarDryRunCore"]
        )
    ]
)
