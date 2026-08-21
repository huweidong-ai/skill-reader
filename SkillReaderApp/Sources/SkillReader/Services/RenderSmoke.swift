import AppKit
import Foundation
import WebKit

// MARK: - WebView 渲染冒烟测试（--render-smoke）
// 不依赖屏幕截图：加载真实技能库的 SKILL.md，等待渲染完成后 dump 页面文本与 TOC，
// 程序化验证 marked 渲染 / 高亮 / TOC 收集链路。
// 注意：必须用 runloop 轮询而非 semaphore 阻塞主线程，否则 WKWebView 回调无法执行。

enum RenderSmoke {
    static func run() -> Int32 {
        var failures: [String] = []
        var renderText = ""
        var codeCount = 0
        var hlDone = 0

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let readyFlag = ReadyFlag()
        // 注意：WKUserContentController 对 handler 是弱引用，必须强持有
        let smokeHandler = SmokeHandler { body in
            if let dict = body as? [String: Any], dict["action"] as? String == "ready" {
                readyFlag.set()
            }
        }
        controller.add(smokeHandler, name: "skillReader")
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        // 注册 srfile:// 协议（图片/PDF 由 Swift 读文件）
        let srfileHandler = SrfileSchemeHandler()
        config.setURLSchemeHandler(srfileHandler, forURLScheme: "srfile")

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 640),
                                configuration: config)
        guard let url = SkillReaderResources.renderHTMLURL() else {
            print("FAIL: 找不到 render.html")
            return 1
        }

        // 找一个真实技能库
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let skillsDir = (home as NSString).appendingPathComponent(".workbuddy/skills")
        guard FileManager.default.fileExists(atPath: skillsDir) else {
            print("SKIP: 无技能库 %@，跳过", skillsDir)
            return 0
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: skillsDir)) ?? []
        guard let skillDir = entries.first(where: {
            FileManager.default.fileExists(atPath: (skillsDir as NSString).appendingPathComponent($0 + "/SKILL.md"))
        }) else {
            print("SKIP: 技能库无含 SKILL.md 的包")
            return 0
        }
        let skillPath = (skillsDir as NSString).appendingPathComponent(skillDir)
        let skillMd = (skillPath as NSString).appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOfFile: skillMd, encoding: .utf8) else {
            print("FAIL: 读取 SKILL.md 失败")
            return 1
        }

        // 加载页面（自包含 render.html，readAccess 只需覆盖 bundle 目录）
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        // runloop 轮询等待 ready
        let deadline = Date().addingTimeInterval(15)
        while !readyFlag.isSet && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !readyFlag.isSet {
            print("FAIL: 页面加载超时")
            return 1
        }

        // 注入真实内容渲染
        let payload: [String: Any] = [
            "kind": "md",
            "name": "SKILL.md",
            "size": "1KB",
            "skillName": skillDir,
            "baseDir": URL(fileURLWithPath: skillPath, isDirectory: true).absoluteString,
            "content": content,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            print("FAIL: payload 序列化失败")
            return 1
        }
        var jsDone = false
        webView.evaluateJavaScript("window.renderSkill(\(json))") { _, err in
            if let err { failures.append("renderSkill JS 错误: \(err.localizedDescription)") }
            jsDone = true
        }
        let jDeadline = Date().addingTimeInterval(5)
        while !jsDone && Date() < jDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // 给渲染/高亮留一点时间
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        // 读取渲染结果
        let jsCheck = """
        (function() {
          var content = document.getElementById('content');
          var text = content ? content.innerText : '';
          var codeCount = content ? content.querySelectorAll('pre code').length : 0;
          var hlDone = content ? document.querySelectorAll('pre code[data-hl="1"]').length : 0;
          return JSON.stringify({ textLen: text.length, codeCount: codeCount, hlDone: hlDone, text: text.slice(0, 600) });
        })()
        """
        var gotResult = false
        webView.evaluateJavaScript(jsCheck) { obj, _ in
            if let s = obj as? String,
               let d = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                renderText = parsed["text"] as? String ?? ""
                codeCount = parsed["codeCount"] as? Int ?? 0
                hlDone = parsed["hlDone"] as? Int ?? 0
            }
            gotResult = true
        }
        let rDeadline = Date().addingTimeInterval(5)
        while !gotResult && Date() < rDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let textLen = renderText.count
        print("== render-smoke ==")
        print("技能: \(skillDir)")
        print("页面文本长度: \(textLen)")
        print("代码块: \(codeCount) (高亮完成: \(hlDone))")
        if textLen < 50 {
            failures.append("渲染文本过短 (\(textLen))，可能渲染失败")
        }
        if codeCount > 0 && hlDone < codeCount {
            failures.append("代码高亮未完成 (\(hlDone)/\(codeCount))")
        }
        print("--- 页面文本预览 ---")
        print(renderText)
        print("--- end ---")
        if textLen >= 50 {
            print("✓ 渲染成功")
        } else {
            failures.append("页面仍显示加载中或为空")
        }

        // 专项验证：找一个含特殊字符（>&2、tab 缩进）的 bash 脚本，
        // 看 hljs 输出是否含字面 `\n`（两字符），确认 sanitizeHljs 生效
        let homeSkills = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".workbuddy/skills")
        var installPath: String?
        var installRoot: String?
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: homeSkills)) ?? [] {
            let p = (homeSkills as NSString).appendingPathComponent("\(entry)/scripts/install.sh")
            if FileManager.default.fileExists(atPath: p) {
                installPath = p
                installRoot = (homeSkills as NSString).appendingPathComponent(entry)
                break
            }
        }
        if let installPath, let installRoot {
            if let bashCode = try? String(contentsOfFile: installPath, encoding: .utf8) {
                let codePayload: [String: Any] = [
                    "kind": "code",
                    "name": "install.sh",
                    "size": "5KB",
                    "skillName": installRoot,
                    "baseDir": URL(fileURLWithPath: installRoot, isDirectory: true).absoluteString,
                    "lang": "bash",
                    "content": bashCode,
                ]
                if let cdata = try? JSONSerialization.data(withJSONObject: codePayload),
                   let cjson = String(data: cdata, encoding: .utf8) {
                    var cjs = false
                    webView.evaluateJavaScript("window.renderSkill(\(cjson))") { _, err in
                        if let err { failures.append("renderCode JS 错误: \(err.localizedDescription)") }
                        cjs = true
                    }
                    let cD = Date().addingTimeInterval(5)
                    while !cjs && Date() < cD {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                    // 检查渲染结果：pre/code 的 innerText 应该是真换行；含 `\n` 两字符则说明还有字面残留
                    let jsInspect = """
                    (function() {
                      var pre = document.querySelector('pre code');
                      if (!pre) return JSON.stringify({error: 'no pre'});
                      var text = pre.innerText;
                      var hasLiteral = text.indexOf('\\\\n') >= 0;
                      var backslashN = text.indexOf('\\\\n');
                      var closeCode = pre.innerHTML.indexOf('</code>') >= 0;
                      var escapedCloseCode = pre.innerHTML.indexOf('&lt;/code&gt;') >= 0;
                      return JSON.stringify({
                        textLen: text.length,
                        hasLiteralBackslashN: hasLiteral,
                        backslashNAt: backslashN,
                        closeCodeInHTML: closeCode,
                        escapedCloseCode: escapedCloseCode,
                        first200: text.slice(0, 200)
                      });
                    })()
                    """
                    var got = false
                    var inspectResult = ""
                    webView.evaluateJavaScript(jsInspect) { obj, _ in
                        inspectResult = obj as? String ?? "{}"
                        got = true
                    }
                    let iD = Date().addingTimeInterval(5)
                    while !got && Date() < iD {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    print("--- install.sh 渲染检查 ---")
                    print(inspectResult)

                    // 回归：检查代码块内容没有溢出 .code-view（如 copy 按钮 onclick 属性未闭合导致泄漏）
                    let jsDump = """
                    (function() {
                      var c = document.getElementById('content');
                      var text = c ? c.innerText : '';
                      var codeView = c ? c.querySelector('.code-view') : null;
                      var codeViewText = codeView ? codeView.innerText : '';
                      var btn = codeView ? codeView.querySelector('.code-header button') : null;
                      var onclick = btn ? btn.getAttribute('onclick') : '';
                      var attrBroken = btn ? (onclick.indexOf('copyText(\"') < 0 && onclick.indexOf('copyText(&quot;') < 0) : true;
                      return JSON.stringify({
                        textLen: text.length,
                        codeViewTextLen: codeViewText.length,
                        hasTextOutsideCodeView: text.length > codeViewText.length + 10,
                        copyButtonBroken: attrBroken
                      });
                    })()
                    """
                    var gotDump = false
                    var dumpResult = ""
                    webView.evaluateJavaScript(jsDump) { obj, _ in
                        dumpResult = obj as? String ?? "{}"
                        gotDump = true
                    }
                    let dD = Date().addingTimeInterval(5)
                    while !gotDump && Date() < dD {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    print("--- install.sh #content 回归检查 ---")
                    print(dumpResult)

                    if let data = inspectResult.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if obj["hasLiteralBackslashN"] as? Bool == true {
                            failures.append("hljs 输出含字面 \\n（位置: \(obj["backslashNAt"] ?? -1)）")
                        }
                    }
                    if let data = dumpResult.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if obj["hasTextOutsideCodeView"] as? Bool == true {
                            failures.append("代码块外出现额外文本，HTML 结构被破坏")
                        }
                        if obj["copyButtonBroken"] as? Bool == true {
                            failures.append("复制按钮 onclick 属性解析异常")
                        }
                    }
                }
            }
        }

        if failures.isEmpty {
            print("-----------------------------")
            print("RenderSmoke: PASS")
            return 0
        }
        for f in failures { print("FAIL: \(f)") }
        return 1
    }
}

// MARK: - 线程安全 ready 标志

final class ReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _isSet }
    func set() { lock.lock(); _isSet = true; lock.unlock() }
}

// MARK: - 消息回调

final class SmokeHandler: NSObject, WKScriptMessageHandler {
    let onMessage: (Any) -> Void
    init(_ onMessage: @escaping (Any) -> Void) {
        self.onMessage = onMessage
    }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        onMessage(message.body)
    }
}
