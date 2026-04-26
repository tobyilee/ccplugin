// swift-tools-version: 6.0
// Claude Plugin Manager — PluginCore
// 비-UI 라이브러리. Foundation 만 의존. SwiftUI/AppKit 의존 금지.
//
// 테스트는 swift-testing (Xcode 없이 동작) — XCTest 회피.

import PackageDescription

let package = Package(
    name: "PluginCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PluginCore",
            targets: ["PluginCore"]
        )
    ],
    dependencies: [
        // Command Line Tools 에는 Testing module 미포함 → 명시 의존 유지.
        // (Xcode 가 설치되면 시스템 Testing 이 우선이지만 이 의존은 안전.)
        // 0.10+ 의 deprecation warning 은 Xcode 환경에서만 의미 있음 — 무시.
        .package(url: "https://github.com/apple/swift-testing", from: "0.10.0")
    ],
    targets: [
        .target(
            name: "PluginCore",
            path: "Sources/PluginCore"
        ),
        .testTarget(
            name: "PluginCoreTests",
            dependencies: [
                "PluginCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/PluginCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
