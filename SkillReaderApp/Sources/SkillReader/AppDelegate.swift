import AppKit
import Foundation

/// 接收 macOS「用本 App 打开文件」事件（Finder 右键「打开方式」/ 双击 .md）
/// 通过 NSApplicationDelegateAdaptor 挂到 SwiftUI App 上。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 启动阶段（webView 尚未就绪）收到的打开请求，webView 就绪后由 DocWebView 消费。
    static var launchURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            Self.handle(url)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Self.handle(URL(fileURLWithPath: filename))
        return true
    }

    private static func handle(_ url: URL) {
        guard url.isFileURL else { return }
        if let state = AppState.shared, state.webReady {
            state.handleOpenURL(url)
        } else {
            // 暂存到静态队列，待 webView 就绪后 flush
            Self.launchURLs.append(url)
        }
    }

    /// webView 首次加载完成时调用：消费启动期间累积的打开请求
    static func flushLaunchURLs() {
        guard !Self.launchURLs.isEmpty else { return }
        let urls = Self.launchURLs
        Self.launchURLs.removeAll()
        for url in urls {
            AppState.shared?.handleOpenURL(url)
        }
    }
}
