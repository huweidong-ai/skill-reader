import AppKit
import SwiftUI
import WebKit

// MARK: - srfile:// 协议处理器
// 解决 loadFileURL 的 readAccess 只能覆盖单目录的问题：
// 主文档 render.html 在 bundle 内，而技能库图片/PDF 在用户目录，
// 二者无法被同一个 readAccess 覆盖。改用自定义 scheme 由 Swift 读文件。

final class SrfileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "srfile" else {
            task.didFailWithError(NSError(domain: "SrfileScheme", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "非法请求"]))
            return
        }
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            task.didFailWithError(NSError(domain: "SrfileScheme", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"]))
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            task.didFailWithError(NSError(domain: "SrfileScheme", code: 3,
                                          userInfo: [NSLocalizedDescriptionKey: "读取失败: \(path)"]))
            return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = mimeType(for: ext, path: path)
        let resp = URLResponse(url: url, mimeType: mime,
                               expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func mimeType(for ext: String, path: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }
}

// MARK: - WKWebView 封装（正文渲染）

struct DocWebView: NSViewRepresentable {
    @ObservedObject var state: AppState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "skillReader")
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.srfileHandler, forURLScheme: "srfile")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.isInspectable = true

        context.coordinator.webView = webView
        state.webView = webView
        context.coordinator.loadTemplate()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.state = state
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var state: AppState
        weak var webView: WKWebView?
        let srfileHandler = SrfileSchemeHandler()
        private var templateLoaded = false

        init(state: AppState) {
            self.state = state
            super.init()
        }

        /// 加载自包含 render.html（bundle 内），readAccess 指向其所在目录即可
        func loadTemplate() {
            guard let url = SkillReaderResources.renderHTMLURL() else {
                return
            }
            templateLoaded = true
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.webReady = true
            state.renderCurrent()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // 外链（http/https）一律交给系统浏览器
            if let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "skillReader",
                  let body = message.body as? [String: Any] else { return }
            let action = body["action"] as? String ?? ""

            switch action {
            case "ready":
                state.webReady = true
                state.renderCurrent()

            case "toc":
                let items = (body["items"] as? [[String: Any]] ?? []).compactMap { dict -> TocItem? in
                    guard let id = dict["id"] as? String else { return nil }
                    return TocItem(id: id,
                                   text: dict["text"] as? String ?? "",
                                   level: dict["level"] as? Int ?? 1)
                }
                state.tocItems = items

            case "heading":
                state.activeHeadingID = body["id"] as? String
                state.activeHeadingText = body["text"] as? String

            case "copy":
                if let text = body["text"] as? String {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    state.flashToast("已复制")
                }

            case "openURL":
                if let urlStr = body["url"] as? String, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }

            case "openRaw":
                state.revealActiveFile()

            default:
                break
            }
        }
    }
}
