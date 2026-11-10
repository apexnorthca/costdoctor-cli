// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "costdoctor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "costdoctor", path: "Sources", sources: ["CostDoctorCore", "costdoctor"])
    ]
)
