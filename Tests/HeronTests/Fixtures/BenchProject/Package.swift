// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shop",
    targets: [
        .target(name: "Shop"),
        .testTarget(name: "ShopTests", dependencies: ["Shop"]),
    ]
)
