// swift-tools-version: 6.0
// Claude Plugin Manager — App
//
// 메뉴바 native SwiftUI 앱. PluginCore (Foundation-only) 위에 UI 만 얹는다.
// 별도 패키지로 분리해서 PluginCore 의 Foundation-only 불변식을 보호.

import PackageDescription

let package = Package(
    name: "App",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CCPluginManager",
            targets: ["App"]
        )
    ],
    dependencies: [
        .package(path: "../PluginCore")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "PluginCore", package: "PluginCore")
            ],
            path: "Sources/App"
        )
    ]
)
