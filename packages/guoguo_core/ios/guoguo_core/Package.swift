// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "guoguo_core",
    platforms: [.iOS("15.0")],
    products: [.library(name: "guoguo-core", targets: ["guoguo_core"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .binaryTarget(name: "GuoguoMobile", path: "../Frameworks/GuoguoMobile.xcframework"),
        .target(name: "guoguo_core", dependencies: ["GuoguoMobile", .product(name: "FlutterFramework", package: "FlutterFramework")])
    ]
)
