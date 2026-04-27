import SwiftUI
import AppKit

/// 앱 메타 — 단일 source-of-truth.
/// `swift run` 빌드는 Info.plist 가 없어 `CFBundleShortVersionString` 이 nil →
/// 상수 fallback 사용. release 번들은 sign.sh 가 Info.plist 를 주입하면 그쪽 우선.
enum AppInfo {
    static let version: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        return "0.1.0-dev"
    }()
}

/// Claude Code Plugin Manager — 메뉴바 상주 SwiftUI 앱.
///
/// PRD §6.4: 메뉴바 popover (status) + 풀 매니저 윈도우 (Installed/Marketplaces 탭).
/// Dock 미노출 동작은 `AppDelegate.applicationDidFinishLaunching` 에서
/// `setActivationPolicy(.accessory)` 로 달성 — Info.plist `LSUIElement` 동등 효과.
@main
struct CCPluginManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var inventory = InventoryViewModel()

    var body: some Scene {
        MenuBarExtra("Plugin Manager", systemImage: "puzzlepiece.extension.fill") {
            MenubarPopover()
                .environmentObject(inventory)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Code Plugin Manager", id: "main") {
            MainWindow()
                .environmentObject(inventory)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// `LSUIElement = YES` 동등 — Dock 미노출, ⌘Q 만 완전 종료, 메인 윈도우 닫혀도 메뉴바 잔류.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 메인 윈도우 ⌘W 닫기 후에도 메뉴바 프로세스 유지.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
