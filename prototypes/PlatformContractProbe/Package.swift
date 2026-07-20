// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PlatformContractProbe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "platform-contract-probe",
            targets: ["PlatformContractProbe"]
        ),
        .executable(
            name: "platform-contract-probe-self-test",
            targets: ["PlatformContractProbeSelfTest"]
        )
    ],
    targets: [
        .target(name: "PlatformContractProbeCore"),
        .executableTarget(
            name: "PlatformContractProbe",
            dependencies: ["PlatformContractProbeCore"]
        ),
        .executableTarget(
            name: "PlatformContractProbeSelfTest",
            dependencies: ["PlatformContractProbeCore"]
        )
    ]
)
