import Foundation
import SwiftUI
import WebKit

// MARK: - 目录项

struct TocItem: Identifiable, Equatable {
    let id: String
    let text: String
    let level: Int
}

// MARK: - 全局状态

@MainActor
final class AppState: ObservableObject {
    let store = SkillStore()

    // ---- 技能列表 / 搜索 ----
    @Published var skills: [Skill] = []
    @Published var searchText: String = ""
    @Published var searchResults: [SearchResult]? = nil   // nil = 列表模式
    @Published var isSearching = false
    @Published var searchDone = false

    // ---- 当前打开 ----
    @Published var activeSkill: Skill?
    @Published var activePath: String? = nil
    @Published var activeKind: FileKind = .md
    @Published var currentFile: FileContent?

    // ---- 侧栏展开 ----
    @Published var expandedSkills: Set<String> = []
    @Published var treeCache: [String: FileNode] = [:]

    // ---- 右键目标高亮（菜单打开期间保持选中感）----
    @Published var contextTarget: String? = nil   // "s:<skillPath>" 或 "f:<skillPath>|<rel>"
    func clearContextTarget() { contextTarget = nil }

    // ---- TOC / 源码模式 ----
    @Published var tocItems: [TocItem] = []
    @Published var activeHeadingID: String?
    @Published var activeHeadingText: String?
    @Published var tocVisible = false
    @Published var sourceMode = false

    // ---- WebView ----
    @Published var webReady = false
    weak var webView: WKWebView?

    // ---- Toast ----
    @Published var toastMessage: String?
    @Published var toastIsError = false
    private var toastTask: Task<Void, Never>?

    // ---- 首次 Agent 配置 ----
    @Published var needsSetup: Bool = false

    // ---- Skill 互通（分发到平台）----
    @Published var distributeSkillName: String? = nil   // nil = sheet 关闭；非 nil = 正在配置该 skill
    @Published var distributePlatforms: Set<String> = [] // sheet 中勾选的平台 id

    // MARK: - 初始化

    init() {
        // 确保中心库目录存在（作为阅读器 root 的挂载点）
        _ = SkillDistributor.shared.ensureLibrary()
        // 是否需要在进入阅读器前先做 Agent 配置（无配置 或 没有任何 Agent 被纳入管理）
        needsSetup = AgentRegistry.shared.needsSetup
        store.loadRoots()
        reloadSkills()
        // skill 互通：启动时全量同步一次分发挂载（幂等，纯文件 IO）
        _ = SkillDistributor.shared.syncAll()
    }

    // MARK: - 首次 Agent 配置

    /// 完成配置：保存 Agent 列表、重建 ~/.agent 集中管理、切换进阅读器。
    func finishSetup(_ list: [AgentProfile]) {
        AgentRegistry.shared.save(list)
        enterReader()
    }

    /// 稍后配置：跳过配置页直接进入阅读器，不保存、不重建 ~/.agent。
    /// 下次启动时若仍无配置，会再次弹出配置页。
    func skipSetup() {
        enterReader()
    }

    /// 从阅读器回到配置页（重新管理 Agent）。
    func reopenSetup() {
        needsSetup = true
    }

    private func enterReader() {
        needsSetup = false
        store.loadRoots()
        reloadSkills()
    }

    // MARK: - Skill 互通（分发到平台）

    /// 当前 skill 是否位于中心库（只有中心库的 skill 能分发）
    var isSkillInLibrary: Bool {
        guard let root = store.currentRootPath else { return false }
        let lib = SkillDistributor.shared.libraryDir
        let rootReal = (root as NSString).standardizingPath
        let libReal = (lib as NSString).standardizingPath
        return rootReal == libReal
    }

    /// 打开「分发到平台」sheet，预填当前已启用平台
    func openDistribute(for skill: Skill) {
        distributeSkillName = skill.name
        distributePlatforms = Set(SkillDistributor.shared.enabledPlatforms(for: skill.name))
    }

    /// 把任意 root 下的 skill 复制进中心库，成功后切到中心库并打开分发 sheet
    func copySkillToLibrary(_ skill: Skill) {
        // 已在中心库：无需复制，直接打开分发
        if isSkillInLibrary {
            openDistribute(for: skill)
            return
        }
        guard let root = store.currentRootPath else { return }
        let src = (root as NSString).appendingPathComponent(skill.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir) else {
            flashToast("复制到中心库失败", isError: true)
            return
        }
        guard SkillDistributor.shared.importToLibrary(from: src, skillName: skill.name) != nil else {
            flashToast("复制到中心库失败", isError: true)
            return
        }
        // 切到中心库查看，并打开分发 sheet
        store.loadRoots()
        if let libRoot = store.roots.first(where: { $0.path == SkillDistributor.shared.libraryDir }) {
            switchRoot(id: libRoot.id)
        }
        reloadSkills()
        openDistribute(for: skill)
        flashToast("已复制到中心库")
    }

    /// 保存分发配置并立即同步
    func saveDistribution() {
        guard let name = distributeSkillName else { return }
        var config = SkillDistributor.shared.loadConfig()
        if distributePlatforms.isEmpty {
            config.skills[name] = nil
        } else {
            config.skills[name] = distributePlatforms.sorted()
        }
        SkillDistributor.shared.saveConfig(config)
        let n = SkillDistributor.shared.syncAll()
        distributeSkillName = nil
        flashToast(n > 0 ? "已分发到 \(n) 个平台" : "已保存（未分发到任何平台）")
    }

    /// 手动全量同步（侧栏按钮）
    func syncDistribution() {
        let n = SkillDistributor.shared.syncAll()
        flashToast(n > 0 ? "已同步 \(n) 个平台挂载" : "没有待分发的 skill")
    }

    // MARK: - 技能列表

    func reloadSkills() {
        let list = store.listSkills()
        skills = list
        searchResults = nil
        searchDone = false
        treeCache = [:]
        expandedSkills = []
        if activeSkill == nil {
            if let first = list.first(where: { $0.entry != nil }) ?? list.first {
                selectSkill(first)
            } else {
                showWelcome()
            }
        } else if !list.contains(where: { $0.path == activeSkill?.path }) {
            activeSkill = nil
            if let first = list.first(where: { $0.entry != nil }) ?? list.first {
                selectSkill(first)
            } else {
                showWelcome()
            }
        } else {
            renderCurrent()
        }
    }

    // MARK: - 选择技能 / 文件

    private func showWelcome() {
        activeSkill = nil
        activePath = nil
        currentFile = nil
        tocItems = []
        renderCurrent()
    }

    func selectSkill(_ skill: Skill) {
        activeSkill = skill
        expandedSkills.insert(skill.path)
        if let entry = skill.entry {
            openFile(skill: skill, path: entry)
        } else {
            // 无主文档：显示目录提示
            activePath = nil
            currentFile = nil
            tocItems = []
            renderCurrent()
        }
    }

    func toggleSkill(_ skill: Skill) {
        if activeSkill?.path == skill.path && expandedSkills.contains(skill.path) {
            // 已展开则收起树，但保留已打开文件
            expandedSkills.remove(skill.path)
            return
        }
        selectSkill(skill)
    }

    func openFile(skill: Skill, path: String) {
        guard let file = store.readFile(skillPath: skill.path, relPath: path) else {
            flashToast("读取失败: 文件不存在", isError: true)
            return
        }
        activeSkill = skill
        activePath = path
        activeKind = file.kind
        currentFile = file
        sourceMode = false
        tocItems = []
        activeHeadingID = nil
        expandedSkills.insert(skill.path)
        renderCurrent()
    }

    func revealActiveFile() {
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        _ = store.revealInFinder(path: abs)
        flashToast("已在 Finder 中定位")
    }

    // MARK: - 右键菜单操作（复制副本 / 移入废纸篓 / 打开访达）

    /// 绝对路径：技能包目录 或 包内文件
    private func absolutePath(skill: Skill, rel: String?) -> String? {
        guard let rel else { return store.safeJoin(root: store.currentRootPath ?? "", rel: skill.path) }
        return store.rawPath(skillPath: skill.path, relPath: rel)
    }

    func duplicateItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel),
              let newPath = store.duplicateItem(at: abs) else {
            flashToast("复制失败", isError: true)
            return
        }
        let name = (newPath as NSString).lastPathComponent
        flashToast("已复制：\(name)")
        refreshAfterFileOp(skill: skill)
    }

    func trashItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else { return }
        let name = (abs as NSString).lastPathComponent
        // 删除前确认（废纸篓可恢复）
        let alert = NSAlert()
        alert.messageText = "移入废纸篓"
        alert.informativeText = "确定将「\(name)」移入废纸篓吗？可从废纸篓恢复。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            guard store.trashItem(at: abs) else {
                flashToast("删除失败", isError: true)
                return
            }
            flashToast("已移入废纸篓：\(name)")
            refreshAfterFileOp(skill: skill)
        }
    }

    func revealItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else { return }
        _ = store.revealInFinder(path: abs)
        flashToast("已在 Finder 中定位")
    }

    /// 复制文件名（含扩展名）
    func copyItemName(skill: Skill, rel: String?) {
        let name = rel.flatMap { ($0 as NSString).lastPathComponent } ?? skill.name
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(name, forType: .string)
        flashToast("已复制文件名：\(name)")
    }

    /// 复制文件绝对路径
    func copyItemPath(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else {
            flashToast("复制失败：无法定位路径", isError: true)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(abs, forType: .string)
        flashToast("已复制路径")
    }

    // MARK: - 编辑（在系统默认编辑器中打开）+ 分享（Finder 定位 + 复制路径）

    /// 当前文件是否可在系统编辑器中打开（文本类）
    var canEditCurrent: Bool {
        guard let file = currentFile, file.content != nil, !file.tooLarge else { return false }
        switch file.kind {
        case .md, .code, .yaml, .json, .toml, .text: return true
        default: return false
        }
    }

    /// 在系统默认编辑器中打开当前文件（如 TextEdit / VSCode / Typora 等）
    func openInEditor() {
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: abs))
        flashToast("已在系统编辑器打开")
    }

    /// 分享：Finder 定位 + 复制路径（无中间文件）
    func shareActive() {
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
        let pb = NSPasteboard.general
        pb.clearContents()
        // 文本路径 + fileURL 双重写入，拖到微信/AirDrop/AI 对话时可直接传文件
        pb.setString(abs, forType: .string)
        pb.writeObjects([URL(fileURLWithPath: abs)] as [NSPasteboardWriting])
        flashToast("已在 Finder 定位 + 已复制路径，可拖入任意目标")
    }

    private func refreshAfterFileOp(skill: Skill) {
        treeCache.removeValue(forKey: skill.path)
        // 若删除的是当前打开的文件，回到主文档
        if activeSkill?.path == skill.path, let activePath {
            var stillExists = false
            if let abs = store.rawPath(skillPath: skill.path, relPath: activePath) {
                stillExists = FileManager.default.fileExists(atPath: abs)
            }
            if !stillExists {
                openFile(skill: skill, path: skill.entry ?? activePath)
            }
        }
        reloadSkills()
    }

    func backToEntry() {
        guard let skill = activeSkill, let entry = skill.entry,
              activePath != nil, activePath != entry else { return }
        openFile(skill: skill, path: entry)
    }

    func toggleSourceMode() {
        guard let file = currentFile, file.kind == .md, file.content != nil else { return }
        sourceMode.toggle()
        renderCurrent()
    }

    // MARK: - 渲染

    func renderCurrent() {
        guard webReady, let webView else { return }

        // 构建 payload
        var payload: [String: Any] = [:]
        guard let skill = activeSkill, let path = activePath,
              let file = currentFile, let abs = store.rawPath(skillPath: skill.path, relPath: path) else {
            payload["kind"] = "welcome"
            callJS("window.renderSkill(\(jsonString(payload)))", on: webView)
            return
        }

        let dir = (abs as NSString).deletingLastPathComponent
        payload["kind"] = file.kind.rawValue
        payload["name"] = file.name
        payload["size"] = file.sizeHuman
        payload["skillName"] = skill.name
        payload["tooLarge"] = file.tooLarge
        payload["baseDir"] = URL(fileURLWithPath: dir, isDirectory: true).absoluteString

        if let lang = file.lang {
            payload["lang"] = lang
        }
        if file.kind == .img || file.kind == .pdf {
            // 传绝对路径，JS 侧 toSrfile() 转成 srfile:// 协议
            payload["path"] = URL(fileURLWithPath: abs).absoluteString
        }
        if file.kind == .md, sourceMode {
            payload["sourceMode"] = true
        }
        if let content = file.content {
            payload["content"] = content
        }

        callJS("window.renderSkill(\(jsonString(payload)))", on: webView)
    }

    func scrollToHeading(id: String) {
        guard webReady, let webView else { return }
        callJS("window.scrollToHeading(\(jsonString(id)))", on: webView)
    }

    private func callJS(_ js: String, on webView: WKWebView) {
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                // 页面尚未就绪时忽略（didFinish 后会自动重绘）
                if (error as NSError).code != 4 { /* WebKitErrorFrameLoadInterrupted */ }
            }
        }
    }

    private func jsonString(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        // 转义 U+2028/U+2029（JS 字符串字面量不合法）
        return str.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                  .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - 搜索

    /// 输入即过滤：名称/描述（本地）
    var filteredSkills: [Skill] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return skills }
        return skills.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    /// 回车全局搜索（SKILL.md 内容）
    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = nil
            searchDone = false
            return
        }
        isSearching = true
        let results = store.search(q)
        searchResults = results
        searchDone = true
        isSearching = false
    }

    func clearSearch() {
        searchText = ""
        searchResults = nil
        searchDone = false
    }

    func openSearchResult(_ result: SearchResult) {
        guard let skill = skills.first(where: { $0.path == result.path }) else { return }
        searchResults = nil
        searchDone = false
        searchText = ""
        if let entry = skill.entry {
            openFile(skill: skill, path: entry)
        } else {
            selectSkill(skill)
        }
    }

    // MARK: - 根目录

    func switchRoot(id: String) {
        store.currentRootID = id
        activeSkill = nil
        activePath = nil
        currentFile = nil
        tocItems = []
        reloadSkills()
    }

    // MARK: - Toast

    func flashToast(_ msg: String, isError: Bool = false) {
        toastMessage = msg
        toastIsError = isError
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }
}
