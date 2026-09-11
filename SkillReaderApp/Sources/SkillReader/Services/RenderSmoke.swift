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

        // 接收页面回传消息（ready / findResult 等）。actor 安全：handler 里只写
        // 线程安全容器，不触碰 AppState（AppState 为 @MainActor 隔离）。
        let readyFlag = ReadyFlag()
        let findCapture = FindResultCapture()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let smokeHandler = SmokeHandler { body in
            guard let dict = body as? [String: Any],
                  let action = dict["action"] as? String else { return }
            switch action {
            case "ready":
                readyFlag.set()
            case "findResult":
                if let c = dict["count"] as? Int,
                   let i = dict["index"] as? Int {
                    findCapture.set(count: c, index: i)
                }
            default:
                break
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

        // runloop 轮询等待 ready（页面 ready 消息触发 readyFlag）
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
          var copyBtns = content ? content.querySelectorAll('.md-code .md-code-copy').length : 0;
          var p = content ? content.querySelector('.md-content > p') : null;
          var pUserSelect = p ? (getComputedStyle(p).webkitUserSelect || getComputedStyle(p).userSelect) : '';
          return JSON.stringify({ textLen: text.length, codeCount: codeCount, hlDone: hlDone, copyBtns: copyBtns, pUserSelect: pUserSelect, text: text.slice(0, 600) });
        })()
        """
        var gotResult = false
        var copyBtns = 0
        var pUserSelect = ""
        webView.evaluateJavaScript(jsCheck) { obj, _ in
            if let s = obj as? String,
               let d = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                renderText = parsed["text"] as? String ?? ""
                codeCount = parsed["codeCount"] as? Int ?? 0
                hlDone = parsed["hlDone"] as? Int ?? 0
                copyBtns = parsed["copyBtns"] as? Int ?? 0
                pUserSelect = parsed["pUserSelect"] as? String ?? ""
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
        // user-select: contain 在 WebKit 下会让双击选中整个段落（连空白一起复制），
        // 已移除；这里确保它不再回归。
        if pUserSelect == "contain" {
            failures.append("user-select: contain 仍生效（会导致双击选中整段带空白）")
        }
        // Markdown 代码块应有悬停复制按钮
        if codeCount > 0 && copyBtns < codeCount {
            failures.append("Markdown 代码块缺少复制按钮 (\(copyBtns)/\(codeCount))")
        }
        print("--- 页面文本预览 ---")
        print(renderText)
        print("--- end ---")
        if textLen >= 50 {
            print("✓ 渲染成功")
        } else {
            failures.append("页面仍显示加载中或为空")
        }

        // 回归：确认传给 JS 的查询串字面量生成正确（这是「搜不出来」的历史根因）
        checkJSStringLiteral(&failures)

        // 端到端验证：window.findInPage → notify({action:"findResult"}) → 消息处理器
        // （与 DocWebView.Coordinator 完全相同的契约）。这里用 actor 安全的 SmokeHandler
        // 捕获回传，确认 findResult 能从 JS 正确回到 Swift 侧并携带 count / index。
        // 这覆盖了「集成代码 → JS → 回传」整条链路的关键缺口。
        do {
            // 取页面首个英文词作为查询（与下方专项验证 C 一致）
            let jsTerm = """
            (function() {
              var c = document.getElementById('content');
              var t = c ? c.innerText || '' : '';
              var m = t.match(/[A-Za-z]{3,}/);
              return JSON.stringify({ term: m ? m[0] : null });
            })()
            """
            var termDone = false
            var term = ""
            webView.evaluateJavaScript(jsTerm) { obj, _ in
                if let s = obj as? String,
                   let d = s.data(using: .utf8),
                   let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    term = p["term"] as? String ?? ""
                }
                termDone = true
            }
            let tDeadline = Date().addingTimeInterval(5)
            while !termDone && Date() < tDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if term.isEmpty {
                print("E2E find: SKIP（页面无英文词，交给专项验证 C 兜底）")
            } else {
                findCapture.reset()
                webView.evaluateJavaScript("window.findInPage(\(jsStringLiteral(term)), {})")
                let fDeadline = Date().addingTimeInterval(5)
                while findCapture.count <= 0 && Date() < fDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                print("E2E findResult via handler: count=\(findCapture.count), index=\(findCapture.index)")
                if findCapture.count <= 0 {
                    failures.append("findResult 回传失败：handler 未收到 count>0 的 findResult 消息")
                } else {
                    // 验证 next / close 的回传
                    webView.evaluateJavaScript("window.findInPageNext()") { _, _ in }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    let idxAfterNext = findCapture.index
                    if idxAfterNext != 1 {
                        failures.append("findInPageNext 未让 index 递增到 1（实际 \(idxAfterNext)）")
                    }
                    webView.evaluateJavaScript("window.findInPageClose()") { _, _ in }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    if findCapture.count != 0 {
                        failures.append("findInPageClose 未将 count 复位为 0")
                    }
                }
            }
        }

        // 专项验证 A：跨块选择裁剪 —— 模拟从 p1 中段拖到 p2 中段（正向），mouseup 后
        // 选区应裁剪回锚点所在块 p1：起点精确停在锚点（不是 p1 开头整块全选），
        // 终点不越过 p1 进入 p2。
        do {
            let jsSetup = """
            (function() {
              try {
                function firstText(p) {
                  var w = document.createTreeWalker(p, NodeFilter.SHOW_TEXT, null);
                  var n;
                  while ((n = w.nextNode())) { if (n.textContent.trim()) return n; }
                  return null;
                }
                var ps = document.querySelectorAll('#content .md-content > p');
                if (ps.length < 2) return JSON.stringify({setup: 'few-ps'});
                var t1 = firstText(ps[0]), t2 = firstText(ps[1]);
                if (!t1 || !t2) return JSON.stringify({setup: 'no-text'});
                window.__srT1 = t1;
                window.__srOff = Math.min(3, t1.textContent.length);
                var sel = window.getSelection();
                var r = document.createRange();
                r.setStart(t1, window.__srOff);
                r.setEnd(t2, Math.min(3, t2.textContent.length));
                sel.removeAllRanges(); sel.addRange(r);
                document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
                return JSON.stringify({setup: 'ok', off: window.__srOff});
              } catch (e) { return JSON.stringify({setup: 'error', err: String(e)}); }
            })()
            """
            var setupDone = false
            var setupState = ""
            webView.evaluateJavaScript(jsSetup) { obj, _ in
                if let s = obj as? String,
                   let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    setupState = parsed["setup"] as? String ?? ""
                }
                setupDone = true
            }
            let sDeadline = Date().addingTimeInterval(5)
            while !setupDone && Date() < sDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if setupState == "ok" {
                // 等 mouseup 收口的 setTimeout(0) 执行
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let jsVerify = """
                (function() {
                  var sel = window.getSelection();
                  if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return JSON.stringify({pass: false, why: 'no-selection'});
                  var r = sel.getRangeAt(0);
                  var nodeOf = function(n) { return n.nodeType === 3 ? n.parentElement : n; };
                  var blockOf = function(el) {
                    var n = el;
                    while (n && n !== document.body) {
                      var pp = n.parentElement;
                      if (pp && (pp.classList.contains('md-content') || pp.classList.contains('md-body'))) return n;
                      n = pp;
                    }
                    return null;
                  };
                  var ps = document.querySelectorAll('#content .md-content > p');
                  var p1 = ps[0], p2 = ps[1];
                  var sb = blockOf(nodeOf(r.startContainer)), eb = blockOf(nodeOf(r.endContainer));
                  var startAtAnchor = r.startContainer === window.__srT1 && r.startOffset === window.__srOff;
                  var withinP1 = sb === p1 && eb === p1;
                  var notWholeBlock = !(sb === p1 && r.startOffset === 0 && r.startContainer === p1);
                  return JSON.stringify({
                    pass: !!(startAtAnchor && withinP1 && notWholeBlock),
                    startAtAnchor: !!startAtAnchor, withinP1: !!withinP1,
                    textLen: sel.toString().length, p1Len: p1.textContent.length
                  });
                })()
                """
                var verifyDone = false
                var verifyPass: Bool?
                var verifyDetail = ""
                webView.evaluateJavaScript(jsVerify) { obj, _ in
                    if let s = obj as? String,
                       let d = s.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        verifyPass = parsed["pass"] as? Bool
                        verifyDetail = "\(parsed)"
                    }
                    verifyDone = true
                }
                let vDeadline = Date().addingTimeInterval(5)
                while !verifyDone && Date() < vDeadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                print("跨块选择裁剪: \(verifyDetail)")
                if verifyPass != true {
                    failures.append("跨块选择未正确裁剪到锚点所在块（应停在锚点且不越界）")
                }
            } else if setupState == "few-ps" || setupState == "no-text" {
                print("跨块选择裁剪: SKIP（技能正文段落数不足）")
            } else {
                print("跨块选择裁剪: SKIP（setup=\(setupState)）")
            }
        }

        // 专项验证 B：双击选中整段 —— 两条触发路径都要生效（dblclick 事件，以及
        // mouseup 且 detail>=2）。结果：选区覆盖整段文字、首尾无空白、不越界到相邻块。
        func checkDoubleClickSelectsBlock(index: Int, eventName: String, label: String, twice: Bool = false) {
            let jsSetup = """
            (function() {
              try {
                var ps = document.querySelectorAll('#content .md-content > p');
                if (ps.length <= \(index)) return JSON.stringify({setup: 'few-ps'});
                function fire() {
                  ps[\(index)].dispatchEvent(new MouseEvent('\(eventName)',
                    {bubbles: true, detail: \(twice ? 1 : 2), clientX: 120, clientY: 120}));
                }
                fire();
                \(twice ? "fire();" : "")
                return JSON.stringify({setup: 'ok'});
              } catch (e) { return JSON.stringify({setup: 'error', err: String(e)}); }
            })()
            """
            var setupDone = false
            var setupState = ""
            webView.evaluateJavaScript(jsSetup) { obj, _ in
                if let s = obj as? String,
                   let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    setupState = parsed["setup"] as? String ?? ""
                }
                setupDone = true
            }
            let sDeadline = Date().addingTimeInterval(5)
            while !setupDone && Date() < sDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            guard setupState == "ok" else {
                print("\(label): SKIP（\(setupState)）")
                return
            }
            // 等 mouseup 分支的 setTimeout(0) 执行
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let jsVerify = """
            (function() {
             try {
              var ps = document.querySelectorAll('#content .md-content > p');
              var target = ps[\(index)];
              var sel = window.getSelection();
              if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return JSON.stringify({pass: false, why: 'no-selection'});
              var r = sel.getRangeAt(0);
              var nodeOf = function(n) { return n.nodeType === 3 ? n.parentElement : n; };
              var blockOf = function(el) {
                var n = el;
                while (n && n !== document.body) {
                  var pp = n.parentElement;
                  if (pp && (pp.classList.contains('md-content') || pp.classList.contains('md-body'))) return n;
                  n = pp;
                }
                return null;
              };
              var got = sel.toString();
              // 段落内软换行在渲染/复制时表现为空格，比较时统一按空白归一，
              // 只校验文字内容一致 + 首尾无空白 + 不越界。
              var norm = function(s) { return s.replace(/\\s+/g, ' ').trim(); };
              var want = norm(target.textContent);
              var inBlock = blockOf(nodeOf(r.startContainer)) === target && blockOf(nodeOf(r.endContainer)) === target;
              var sameText = norm(got) === want;
              var noEdgeBlank = got === got.replace(/^\\s+/, '') && got === got.replace(/\\s+$/, '');
              return JSON.stringify({
                pass: !!(inBlock && sameText && noEdgeBlank),
                inBlock: !!inBlock, sameText: !!sameText, noEdgeBlank: !!noEdgeBlank,
                gotLen: got.length, wantLen: want.length
              });
             } catch (e) { return JSON.stringify({pass: false, err: String(e)}); }
            })()
            """
            var verifyDone = false
            var verifyPass: Bool?
            var verifyDetail = ""
            webView.evaluateJavaScript(jsVerify) { obj, err in
                if let err { verifyDetail = "JS_ERROR: \(err.localizedDescription)" }
                if let s = obj as? String,
                   let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    if verifyPass == nil { verifyPass = parsed["pass"] as? Bool }
                    verifyDetail += "\(parsed)"
                }
                verifyDone = true
            }
            let vDeadline = Date().addingTimeInterval(5)
            while !verifyDone && Date() < vDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            print("\(label): \(verifyDetail)")
            if verifyPass != true {
                failures.append("\(label) 未选中整段文字（应覆盖整段且首尾无空白）")
            }
        }
        checkDoubleClickSelectsBlock(index: 1, eventName: "dblclick", label: "双击选中整段(dblclick)")
        checkDoubleClickSelectsBlock(index: 2, eventName: "mouseup", label: "双击选中整段(mouseup detail=2)")
        // 真实双击的最小模型：连续两次 mouseup（detail 均为 1，坐标一致）
        checkDoubleClickSelectsBlock(index: 3, eventName: "mouseup",
                                     label: "双击选中整段(两次 mouseup)", twice: true)

        // 专项验证 C：正文内查找（find-in-page）—— 取页面首个英文词，调 window.findInPage
        // 高亮，断言命中数 > 0；再清空字符串应移除所有高亮。
        do {
            let jsFind = """
            (function() {
              try {
                var content = document.getElementById('content');
                if (!content) return JSON.stringify({setup: 'no-content'});
                var text = content.innerText || '';
                var m = text.match(/[A-Za-z]{3,}/);
                var term = m ? m[0] : null;
                if (!term) return JSON.stringify({setup: 'no-word', textLen: text.length});
                window.findInPage(term, {});
                var hits = content.querySelectorAll('mark.sr-find').length;
                return JSON.stringify({setup: 'ok', term: term, hits: hits});
              } catch (e) { return JSON.stringify({setup: 'error', err: String(e)}); }
            })()
            """
            var findDone = false
            var findSetup = ""
            var findHits = 0
            var findTerm = ""
            webView.evaluateJavaScript(jsFind) { obj, _ in
                if let s = obj as? String,
                   let d = s.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    findSetup = parsed["setup"] as? String ?? ""
                    findHits = parsed["hits"] as? Int ?? 0
                    findTerm = parsed["term"] as? String ?? ""
                }
                findDone = true
            }
            let fDeadline = Date().addingTimeInterval(5)
            while !findDone && Date() < fDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            print("正文内查找(term=\(findTerm)): setup=\(findSetup), hits=\(findHits)")
            if findSetup == "ok" {
                if findHits <= 0 {
                    failures.append("find-in-page 未高亮任何命中（期望 > 0）")
                } else {
                    let jsClear = """
                    window.findInPage('', {});
                    (function() {
                      var c = document.getElementById('content');
                      return JSON.stringify({marks: c ? c.querySelectorAll('mark.sr-find').length : 0});
                    })()
                    """
                    var clearDone = false
                    var clearMarks = -1
                    webView.evaluateJavaScript(jsClear) { obj, _ in
                        if let s = obj as? String,
                           let d = s.data(using: .utf8),
                           let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            clearMarks = parsed["marks"] as? Int ?? -1
                        }
                        clearDone = true
                    }
                    let cDeadline = Date().addingTimeInterval(5)
                    while !clearDone && Date() < cDeadline {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    }
                    print("清空查找后高亮数: \(clearMarks)")
                    if clearMarks != 0 {
                        failures.append("find-in-page 清空后仍有残留高亮（期望 0）")
                    }
                }
            } else {
                print("正文内查找: SKIP（\(findSetup)）")
            }
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

// MARK: - findResult 回传捕获（线程安全）

final class FindResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = -1
    private var _index = -1
    func set(count: Int, index: Int) {
        lock.lock(); defer { lock.unlock() }
        _count = count; _index = index
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _count = -1; _index = -1
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var index: Int { lock.lock(); defer { lock.unlock() }; return _index }
}

// MARK: - 回归断言：JS 字符串字面量生成

/// 回归：传给 JS 的查询串必须是带引号的合法字符串字面量。
/// 历史 bug：把 String 直接交给 JSONSerialization 顶层序列化会抛 NSException，
/// 退化为 "{}" 后 JS 侧拿不到查询词，表现为「搜不出来」。
func checkJSStringLiteral(_ failures: inout [String]) {
    let lit = jsStringLiteral("skills")
    print("jsStringLiteral 回归: \(lit)")
    guard lit.hasPrefix("\""), lit.hasSuffix("\""), lit.contains("skills") else {
        failures.append("jsStringLiteral 未生成合法 JS 字符串字面量（实际 \(lit)）")
        return
    }
    // 含特殊字符也不能破坏 JS 语法
    let tricky = jsStringLiteral("a\"b\\c\n")
    print("jsStringLiteral 特殊字符: \(tricky)")
    if tricky == "{}" || tricky.isEmpty {
        failures.append("jsStringLiteral 对特殊字符退化为非法值（实际 \(tricky)）")
    }
}
