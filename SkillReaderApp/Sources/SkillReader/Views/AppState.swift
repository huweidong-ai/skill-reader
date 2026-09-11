import Foundation
import SwiftUI
import Combine
import WebKit

// MARK: - 目录项

struct TocItem: Identifiable, Equatable {
    let id: String
    let text: String
    let level: Int
}

// MARK: - 撤销删除记录

/// 记录最后一次移入废纸篓的文件，用于「撤销删除」一次性回滚。
struct LastTrashRecord: Equatable {
    let originalPath: String
    let trashedURL: URL
    let skillPath: String
    let name: String
}

// MARK: - 主题模式

enum ThemeMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:  return L10n.t("跟随系统", "System")
        case .light: return L10n.t("浅色", "Light")
        case .dark:  return L10n.t("深色", "Dark")
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.righthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - 全局状态

@MainActor
final class AppState: ObservableObject {
    static var shared: AppState?

    let store = SkillStore()

    // ---- 语言刷新 ----
    // L10n.t() 是全局函数，UserDefaults 变化不会自动让依赖 state 的视图重建；
    // 这里监听并手动推送 objectWillChange，让所有视图重新取文案。
    private var lastLanguage: String = L10n.override.rawValue
    private var cancellables = Set<AnyCancellable>()

    // ---- 技能列表 / 搜索 ----
    @Published var skills: [Skill] = []
    @Published var searchText: String = ""
    @Published var searchResults: [SearchResult]? = nil   // nil = 列表模式
    @Published var isSearching = false
    @Published var searchDone = false
    @Published var searchExpanded = false               // 搜索框是否展开（ClaudeCode 风格折叠搜索）

    // ---- 正文内查找（find-in-page）----
    @Published var findVisible = false                 // 查找栏是否显示
    @Published var findText = ""
    @Published var findCount = 0                       // 命中数量
    @Published var findIndex = -1                      // 当前命中序号（0-based，-1 表示无）

    // ---- 当前打开 ----
    @Published var activeSkill: Skill?
    @Published var activePath: String? = nil
    @Published var activeKind: FileKind = .md
    @Published var currentFile: FileContent?

    // ---- 文件树选中态（供 ⌘C 复制文件实体）----
    @Published var selectedNodePath: String? = nil   // 选中的文件/文件夹绝对路径
    @Published var selectedNodeIsDir: Bool = false

    // ---- 侧栏展开 ----
    @Published var expandedSkills: Set<String> = []
    @Published var treeCache: [String: FileNode] = [:]

    // ---- 右键目标高亮（菜单打开期间保持选中感）----
    @Published var contextTarget: String? = nil   // "s:<skillPath>" 或 "f:<skillPath>|<rel>"
    func clearContextTarget() { contextTarget = nil }

    // ---- 撤销删除：记录最后一次废纸篓操作 ----
    @Published var lastTrashedItem: LastTrashRecord? = nil
    /// 有未撤销的删除且文件仍在废纸篓中
    var canUndoDelete: Bool {
        guard let record = lastTrashedItem else { return false }
        return FileManager.default.fileExists(atPath: record.trashedURL.path)
    }

    // ---- TOC / 源码模式 ----
    @Published var tocItems: [TocItem] = []
    @Published var activeHeadingID: String?
    @Published var activeHeadingText: String?
    @Published var tocVisible = false
    @Published var sourceMode = false

    // ---- 外部文件（Finder 右键「打开方式」打开的任意本地文件）----
    @Published var externalFile: URL? = nil
    var pendingOpenURL: URL? = nil   // webView 未就绪时暂存

    // ---- 导航栏折叠（参考 macos-swift-dev-guide 侧边栏导航模板）----
    @Published var sidebarUserCollapsed = false   // 用户手动收起
    @Published var sidebarTransient = false        // 收起态下临时滑出（点空白收回）
    @Published var sidebarWidth: CGFloat = 260
    @Published var windowWidth: CGFloat = 1100
    /// 进入外部文件模式前的导航栏收起状态（退出时恢复，尊重用户选择）
    private var sidebarCollapseBeforeExternal: Bool? = nil

    private let sidebarDetailMinWidth: CGFloat = 480
    /// 导航栏常驻所需最小窗口宽 = 侧栏宽 + 内容最小宽 + 间隙
    var sidebarDockedMinWidth: CGFloat { sidebarWidth + sidebarDetailMinWidth + 8 }
    /// 自动收起：仅当窗口太窄放不下导航栏。
    /// 外部文件模式的自动收起不在这里硬编码——由 openExternalFile 置 sidebarUserCollapsed 实现，
    /// 这样窗口够宽时用户点展开仍能固定到左侧常驻，而不是只能临时滑出。
    var sidebarAutoCollapsed: Bool {
        windowWidth < sidebarDockedMinWidth
    }
    /// 导航栏是否可见（常驻或临时滑出）
    var sidebarVisible: Bool {
        sidebarTransient || (!sidebarUserCollapsed && !sidebarAutoCollapsed)
    }
    /// 导航栏是否「常驻并挤压内容区」（区别于临时滑出浮层）
    var sidebarDocked: Bool {
        sidebarVisible && !sidebarTransient && !sidebarAutoCollapsed
    }

    /// 面包屑 / 工具栏的导航栏显隐按钮（参考侧边栏导航模板 §3.1 双分支逻辑）
    func toggleSidebar() {
        if sidebarVisible {
            // 展开态（常驻 或 临时 flyout）→ 无脑收起
            sidebarUserCollapsed = true
            sidebarTransient = false
        } else if currentWindowWidth() < sidebarDockedMinWidth {
            // 收起态 + 窗口太窄 → 临时滑出浮层，点空白收回，不挤压内容区
            sidebarTransient = true
            sidebarUserCollapsed = false
        } else {
            // 收起态 + 窗口足够宽（含外部文件模式）→ 固定到左侧常驻，内容区让出导航栏宽度
            sidebarUserCollapsed = false
            sidebarTransient = false
        }
    }

    /// 实时读取当前窗口宽度（避免 windowWidth 状态过期导致误判折叠/展开）
    private func currentWindowWidth() -> CGFloat {
        let candidates = ([NSApp.mainWindow, NSApp.keyWindow] as [NSWindow?]).compactMap { $0 }
            + NSApp.windows
        if let w = candidates.first(where: { $0.isVisible && !$0.isMiniaturized }) {
            return w.frame.width
        }
        return windowWidth
    }

    /// 由窗口 resize 通知驱动（读 NSWindow.frame，不用 GeometryReader，见 §A）
    func updateWindowWidth(_ w: CGFloat) {
        windowWidth = w
    }

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

    // ---- 主题 ----
    @Published var theme: ThemeMode = .auto

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
        // B 模式：为已纳入的 Agent 执行「采纳」（纳入即共享，单一真相源）。
        // 幂等、带备份；新加入/新装的 skill 会自动被采纳。
        for agent in AgentRegistry.shared.agents where agent.enabled {
            _ = SkillDistributor.shared.adoptAgentToLibrary(agent)
        }
        _ = SkillDistributor.shared.syncAll()
        // 主题
        if let raw = UserDefaults.standard.string(forKey: "skillreader_theme"),
           let mode = ThemeMode(rawValue: raw) {
            theme = mode
        }
        applyTheme()
        AppState.shared = self

        // 语言变化监听：切换语言后让所有视图重新取 L10n.t 文案。
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                let current = L10n.override.rawValue
                guard let self, current != self.lastLanguage else { return }
                self.lastLanguage = current
                self.objectWillChange.send()
                self.applyWebViewLanguage()
            }
            .store(in: &cancellables)
    }

    // MARK: - 主题

    /// 切换并持久化主题，同时作用于原生 App 外观与 WebView 阅读器
    func setTheme(_ mode: ThemeMode) {
        guard theme != mode else { return }
        theme = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "skillreader_theme")
        applyTheme()
        flashToast(L10n.t("已切换为：\(mode.label)", "Switched to: \(mode.label)"))
    }

    /// 应用主题到 AppKit 与 WKWebView（webReady 后生效）
    func applyTheme() {
        switch theme {
        case .auto:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        guard webReady, let webView else { return }
        // rawValue 为 auto/light/dark，仅含安全字符；直接嵌入 JS 字符串
        callJS("window.applyTheme(\"\(theme.rawValue)\")", on: webView)
    }

    /// 把当前语言推给 WebView 阅读器（欢迎页/加载态随语言切换）。
    /// 仅在 WebView 就绪后调用；未就绪时 renderCurrent 的 welcome payload 已带语言。
    func applyWebViewLanguage() {
        guard webReady, let webView else { return }
        let lang = L10n.isChinese ? "zh" : "en"
        callJS("window.setLanguage(\"\(lang)\")", on: webView)
    }

    // MARK: - 首次 Agent 配置

    /// 完成配置：保存 Agent 列表、重建 ~/.agent 集中管理、执行采纳、切换进阅读器。
    func finishSetup(_ list: [AgentProfile]) {
        AgentRegistry.shared.save(list)
        // B 模式：纳入即共享——为每个启用 Agent 采纳其真实 skills 到中心库
        for agent in list where agent.enabled {
            _ = SkillDistributor.shared.adoptAgentToLibrary(agent)
        }
        _ = SkillDistributor.shared.syncAll()
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
        exitExternalMode()
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

    /// 打开「分发到平台」sheet，预填当前已启用平台。
    /// `skill.name` 在中心库 root 下即 canonical（`<owner>__<skill>`），直接作为配置键。
    func openDistribute(for skill: Skill) {
        distributeSkillName = skill.name
        distributePlatforms = Set(SkillDistributor.shared.enabledPlatforms(for: skill.name))
    }

    /// 当前 root 对应的 owner Agent id（用于中心库命名去重）；非 Agent 挂载则记 "imported"。
    func ownerIdForCurrentRoot() -> String {
        guard let root = store.currentRootPath else { return "imported" }
        let mountStd = (AgentRegistry.shared.skillsMount as NSString).standardizingPath
        let rootStd = (root as NSString).standardizingPath
        guard rootStd.hasPrefix(mountStd + "/") else { return "imported" }
        let rest = String(rootStd.dropFirst(mountStd.count + 1))
        if let id = rest.components(separatedBy: "/").first,
           AgentRegistry.shared.agents.contains(where: { $0.id == id }) {
            return id
        }
        return "imported"
    }

    /// 把任意 root 下的 skill 复制进中心库（以 canonical 命名），
    /// 但保持当前 Agent root 不变，直接打开分发 sheet。
    /// 中心库作为后台分发源，不再跳到前台占用 root 切换菜单。
    func copySkillToLibrary(_ skill: Skill) {
        // 已在中心库：无需复制（skill.name 已是 canonical），直接打开分发
        if isSkillInLibrary {
            openDistribute(for: skill)
            return
        }
        guard let root = store.currentRootPath else { return }
        let src = (root as NSString).appendingPathComponent(skill.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir) else {
            flashToast(L10n.t("复制到中心库失败", "Failed to copy to library"), isError: true)
            return
        }
        let owner = ownerIdForCurrentRoot()
        let canonical = SkillDistributor.canonical(owner: owner, skill: skill.name)
        guard SkillDistributor.shared.importToLibrary(from: src, skillName: canonical) != nil else {
            flashToast(L10n.t("复制到中心库失败", "Failed to copy to library"), isError: true)
            return
        }
        // 保持当前 root 不变，仅刷新 roots 数据；分发 sheet 用 canonical 构造列表项
        store.loadRoots()
        reloadSkills()
        let libSkill = Skill(name: canonical, path: canonical, kind: .package,
                             entry: "SKILL.md", description: skill.description,
                             stats: skill.stats, modified: skill.modified)
        openDistribute(for: libSkill)
        flashToast(L10n.t("已复制到中心库", "Copied to library"))
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
        flashToast(n > 0
                   ? L10n.t("已分发到 \(n) 个平台", "Distributed to \(n) platform(s)")
                   : L10n.t("已保存（未分发到任何平台）", "Saved (not distributed to any platform)"))
    }

    /// 手动全量同步（侧栏按钮）
    func syncDistribution() {
        let n = SkillDistributor.shared.syncAll()
        flashToast(n > 0
                   ? L10n.t("已同步 \(n) 个平台挂载", "Synced \(n) platform mount(s)")
                   : L10n.t("没有待分发的 skill", "No skills pending distribution"))
    }

    // MARK: - 技能列表

    func reloadSkills() {
        // 重探所有已管理 Agent 根目录（含新装的 Agent），保留当前选中的根
        store.loadRoots()
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
        exitExternalMode()
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
        exitExternalMode()
        guard let file = store.readFile(skillPath: skill.path, relPath: path) else {
            flashToast(L10n.t("读取失败: 文件不存在", "Read failed: file not found"), isError: true)
            return
        }
        activeSkill = skill
        activePath = path
        activeKind = file.kind
        currentFile = file
        // 记录选中态，供 ⌘C 复制文件实体
        if let abs = store.rawPath(skillPath: skill.path, relPath: path) {
            selectedNodePath = abs
            selectedNodeIsDir = false
        }
        sourceMode = false
        tocItems = []
        activeHeadingID = nil
        expandedSkills.insert(skill.path)
        renderCurrent()
    }

    func revealActiveFile() {
        if let ext = externalFile {
            _ = store.revealInFinder(path: ext.path)
            flashToast(L10n.t("已在 Finder 中定位", "Located in Finder"))
            return
        }
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        _ = store.revealInFinder(path: abs)
        flashToast(L10n.t("已在 Finder 中定位", "Located in Finder"))
    }

    // MARK: - 右键菜单操作（复制副本 / 移入废纸篓 / 打开访达）

    /// 绝对路径：技能包目录 或 包内文件
    private func absolutePath(skill: Skill, rel: String?) -> String? {
        guard let rel else { return store.safeJoin(root: store.currentRootPath ?? "", rel: skill.path) }
        return store.rawPath(skillPath: skill.path, relPath: rel)
    }

    /// 记录文件树选中态（点文件/文件夹/技能包时调用，不打开也记录）
    /// `rel` 为 nil 表示选中技能包根目录本身。
    func selectNode(skill: Skill, rel: String?, isDir: Bool) {
        if let abs = absolutePath(skill: skill, rel: rel) {
            selectedNodePath = abs
            selectedNodeIsDir = isDir
        }
    }

    /// 当前打开文件的绝对路径（⌘C 兜底）
    private func absolutePathForActive() -> String? {
        guard let skill = activeSkill, let path = activePath else { return nil }
        return store.rawPath(skillPath: skill.path, relPath: path)
    }

    /// 判断当前焦点是否在应走系统默认 ⌘C/⌘V 的视图内（文本输入框 / 网页正文）。
    /// 网页正文选中文字时，firstResponder 是 WKWebView 内部视图，沿 responder chain 向上能找到 WKWebView。
    func isSystemCopyPasteActive() -> Bool {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder
        while let r = responder {
            if r is WKWebView || r is NSText {
                return true
            }
            responder = r.nextResponder
        }
        return false
    }

    /// 当前焦点是否「确有文字选区」需要走系统复制/剪切：文本框有选中范围，或网页正文（选区由调用方异步判断）。
    /// 仅「文本框获得焦点但无选区」时返回 false，让 ⌘C/⌘X 退化为复制选中的文件——
    /// 避免粘贴后焦点仍停在搜索框（firstResponder 仍是搜索框的 NSTextView），导致 ⌘C 复制了搜索文字而非文件。
    func focusHasTextSelection() -> Bool {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder
        while let r = responder {
            if r is WKWebView {
                return true // 网页选区由调用方用 JS 异步判断
            }
            if let tv = r as? NSTextView {
                return tv.selectedRanges.contains { $0.rangeValue.length > 0 }
            }
            responder = r.nextResponder
        }
        return false
    }

    /// 把编辑类动作（copy/paste/selectAll）转发给当前焦点视图（网页正文或文本输入框）。
    /// 焦点在网页正文时直发 webView；焦点在搜索框等文本框时交给系统沿 responder chain 分派，
    /// 避免右侧 webView 存在时把粘贴动作错发给网页而漏掉文本框。
    func forwardEdit(_ selector: Selector) {
        guard isSystemCopyPasteActive() else { return }
        if focusIsWebView() {
            NSApp.sendAction(selector, to: webView, from: nil)
        } else {
            NSApp.sendAction(selector, to: nil, from: nil)
        }
    }

    /// ⌘X 剪切：焦点在文本输入框 / 网页正文且有文字选区时走系统默认 cut:（剪切选中文字）；
    /// 焦点在网页但无选区（仅点开文件）、或焦点在文件树时，本应用无移动语义，退化为复制文件。
    func cutActive() {
        if focusHasTextSelection() {
            if let wv = webView, focusIsWebView() {
                wv.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                    let text = result as? String ?? ""
                    if text.isEmpty {
                        self.copyActiveFile()
                    } else {
                        self.forwardEdit(#selector(NSText.cut(_:)))
                    }
                }
                return
            }
            forwardEdit(#selector(NSText.cut(_:)))
            return
        }
        // 文件树：无移动/重排能力，剪切退化为复制文件，避免快捷键无响应
        copyActiveFile()
    }

    /// 当前焦点是否落在网页正文（WKWebView）内，区别于搜索框等 NSText 输入框。
    func focusIsWebView() -> Bool {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder
        while let r = responder {
            if r is WKWebView { return true }
            responder = r.nextResponder
        }
        return false
    }

    /// ⌘C 复制文件实体：把选中文件/文件夹作为文件承诺写入剪贴板，
    /// 可粘贴到 Finder、聊天窗口、邮件等支持文件粘贴的目标。
    /// 若焦点在文本输入框或网页正文且确有文字选区，则交给系统默认复制文字。
    func copyActiveFile() {
        if focusHasTextSelection() {
            if let wv = webView, focusIsWebView() {
                // 网页正文：仅有文字选区时才复制网页文字；
                // 若只是点开文件（无选区，焦点落在 webView），退化为复制选中的文件。
                wv.evaluateJavaScript("window.getSelection().toString()") { result, _ in
                    let text = result as? String ?? ""
                    if text.isEmpty {
                        self.copySelectedFile()
                    } else {
                        self.forwardEdit(#selector(NSText.copy(_:)))
                        self.flashToast(L10n.t("已复制", "Copied"))
                    }
                }
            } else {
                // 搜索框等 NSText 输入框：复制交还系统，无需提示
                forwardEdit(#selector(NSText.copy(_:)))
            }
            return
        }

        copySelectedFile()
    }

    /// 复制当前选中的文件 / 文件夹（来自文件树选中态或当前打开的文件）。
    private func copySelectedFile() {
        var url: URL? = nil
        if let ext = externalFile {
            url = ext
        } else if let abs = selectedNodePath, FileManager.default.fileExists(atPath: abs) {
            url = URL(fileURLWithPath: abs)
        } else if let abs = absolutePathForActive() {
            url = URL(fileURLWithPath: abs)
        }

        guard let url else {
            flashToast(L10n.t("复制失败：未选中文件", "Copy failed: no file selected"), isError: true)
            return
        }

        // 目录判断：优先用选中时记录的 isDir（技能包/文件夹在文件树中被点选时），
        // 再回退到真实文件系统属性（兜底外部文件等场景）。
        let isDir: Bool
        if let selectedAbs = selectedNodePath, url.path == selectedAbs {
            isDir = selectedNodeIsDir
        } else {
            isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }

        let pb = NSPasteboard.general
        pb.clearContents()

        if isDir {
            // 文件夹实体多数聊天/对话框不接受粘贴，且按需求只复制文件夹路径（文本），
            // 不写入 fileURL，避免部分目标读到文件夹实体而粘贴失败。
            pb.setString(url.path, forType: .string)
            flashToast(L10n.t("已复制文件夹路径：\(url.lastPathComponent)",
                              "Copied folder path: \(url.lastPathComponent)"))
        } else {
            // 文件：写文件实体（可粘贴到 Finder / 聊天窗口等），并附带路径文本兜底。
            pb.writeObjects([url] as [NSPasteboardWriting])
            pb.setString(url.path, forType: .string)
            flashToast(L10n.t("已复制文件：\(url.lastPathComponent)",
                              "Copied file: \(url.lastPathComponent)"))
        }
    }

    func duplicateItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel),
              let newPath = store.duplicateItem(at: abs) else {
            flashToast(L10n.t("复制失败", "Copy failed"), isError: true)
            return
        }
        let name = (newPath as NSString).lastPathComponent
        flashToast(L10n.t("已复制：\(name)", "Copied: \(name)"))
        refreshAfterFileOp(skill: skill)
    }

    func trashItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else { return }
        let name = (abs as NSString).lastPathComponent
        // 删除前确认（废纸篓可恢复）
        let alert = NSAlert()
        alert.messageText = L10n.t("移入废纸篓", "Move to Trash")
        alert.informativeText = L10n.t("确定将「\(name)」移入废纸篓吗？可从废纸篓恢复。",
                                        "Move \"\(name)\" to Trash? You can recover it from Trash.")
        alert.addButton(withTitle: L10n.t("移入废纸篓", "Move to Trash"))
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            var trashedURL: NSURL? = nil
            guard store.trashItem(at: abs, resultingItemURL: &trashedURL) else {
                flashToast(L10n.t("删除失败", "Delete failed"), isError: true)
                return
            }
            if let url = trashedURL as URL? {
                lastTrashedItem = LastTrashRecord(originalPath: abs, trashedURL: url, skillPath: skill.path, name: name)
            } else {
                lastTrashedItem = nil
            }
            flashToast(L10n.t("已移入废纸篓：\(name)", "Moved to Trash: \(name)"))
            refreshAfterFileOp(skill: skill)
        }
    }

    /// 撤销最后一次删除：从废纸篓把文件移回原路径，并刷新对应 skill 树。
    func undoLastTrash() {
        guard let record = lastTrashedItem else { return }
        guard FileManager.default.fileExists(atPath: record.trashedURL.path) else {
            lastTrashedItem = nil
            flashToast(L10n.t("原文件已不在废纸篓，无法撤销", "Original file is no longer in Trash, cannot undo"), isError: true)
            return
        }
        do {
            // 若原目录已被删除，先重建
            let parent = (record.originalPath as NSString).deletingLastPathComponent
            if !parent.isEmpty && !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: record.trashedURL, to: URL(fileURLWithPath: record.originalPath))
            lastTrashedItem = nil
            flashToast(L10n.t("已撤销删除：\(record.name)", "Undeleted: \(record.name)"))
            if let skill = skills.first(where: { $0.path == record.skillPath }) {
                refreshAfterFileOp(skill: skill)
            }
        } catch {
            flashToast(L10n.t("撤销删除失败", "Undo delete failed"), isError: true)
        }
    }

    func revealItem(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else { return }
        _ = store.revealInFinder(path: abs)
        flashToast(L10n.t("已在 Finder 中定位", "Located in Finder"))
    }

    /// 复制文件名（含扩展名）
    func copyItemName(skill: Skill, rel: String?) {
        let name = rel.flatMap { ($0 as NSString).lastPathComponent } ?? skill.name
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(name, forType: .string)
        flashToast(L10n.t("已复制文件名：\(name)", "Copied filename: \(name)"))
    }

    /// 复制文件绝对路径
    func copyItemPath(skill: Skill, rel: String?) {
        guard let abs = absolutePath(skill: skill, rel: rel) else {
            flashToast(L10n.t("复制失败：无法定位路径", "Copy failed: cannot locate path"), isError: true)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(abs, forType: .string)
        flashToast(L10n.t("已复制路径", "Path copied"))
    }

    // MARK: - 编辑（在系统默认编辑器中打开）+ 分享（Finder 定位 + 复制路径）

    /// 当前文件是否可在系统编辑器中打开（文本类）
    var canEditCurrent: Bool {
        if let ext = externalFile {
            let k = store.classify(ext.lastPathComponent)
            return [.md, .code, .yaml, .json, .toml, .text].contains(k)
        }
        guard let file = currentFile, file.content != nil, !file.tooLarge else { return false }
        switch file.kind {
        case .md, .code, .yaml, .json, .toml, .text: return true
        default: return false
        }
    }

    /// 在系统默认编辑器中打开当前文件（如 TextEdit / VSCode / Typora 等）
    func openInEditor() {
        if let ext = externalFile {
            NSWorkspace.shared.open(ext)
            flashToast(L10n.t("已在系统编辑器打开", "Opened in system editor"))
            return
        }
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: abs))
        flashToast(L10n.t("已在系统编辑器打开", "Opened in system editor"))
    }

    /// 轻量复制：仅把当前文件绝对路径写入剪贴板，不打开 Finder
    func copyActivePath() {
        if let ext = externalFile {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(ext.path, forType: .string)
            flashToast(L10n.t("已复制路径", "Path copied"))
            return
        }
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else {
            flashToast(L10n.t("复制失败：无法定位路径", "Copy failed: cannot locate path"), isError: true)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(abs, forType: .string)
        flashToast(L10n.t("已复制路径", "Path copied"))
    }

    /// 分享：Finder 定位 + 复制路径（无中间文件）
    func shareActive() {
        if let ext = externalFile {
            let abs = ext.path
            NSWorkspace.shared.activateFileViewerSelecting([ext])
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(abs, forType: .string)
            pb.writeObjects([ext] as [NSPasteboardWriting])
            flashToast(L10n.t("已在 Finder 定位 + 已复制路径，可拖入任意目标",
                              "Located in Finder + path copied, drag into any target"))
            return
        }
        guard let skill = activeSkill, let path = activePath,
              let abs = store.rawPath(skillPath: skill.path, relPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: abs)])
        let pb = NSPasteboard.general
        pb.clearContents()
        // 文本路径 + fileURL 双重写入，拖到微信/AirDrop/AI 对话时可直接传文件
        pb.setString(abs, forType: .string)
        pb.writeObjects([URL(fileURLWithPath: abs)] as [NSPasteboardWriting])
        flashToast(L10n.t("已在 Finder 定位 + 已复制路径，可拖入任意目标",
                          "Located in Finder + path copied, drag into any target"))
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
        // 不再全量 reloadSkills()：全量刷新会清空 expandedSkills 与 treeCache，
        // 导致刚展开的技能折叠、刚创建的副本不刷新。只清除当前 skill 的 treeCache，
        // 由 SkillRow 的 .onChange 触发局部重载。
    }

    func backToEntry() {
        guard let skill = activeSkill, let entry = skill.entry,
              activePath != nil, activePath != entry else { return }
        exitExternalMode()
        openFile(skill: skill, path: entry)
    }

    func toggleSourceMode() {
        if let ext = externalFile {
            guard store.classify(ext.lastPathComponent) == .md else { return }
            sourceMode.toggle()
            renderCurrent()
            return
        }
        guard let file = currentFile, file.kind == .md, file.content != nil else { return }
        sourceMode.toggle()
        renderCurrent()
    }

    // MARK: - 渲染

    /// 由 AppDelegate 在 macOS 打开文件事件（右键「打开方式」）时调用
    func handleOpenURL(_ url: URL) {
        guard url.isFileURL else { return }
        if webReady {
            openExternalFile(url)
        } else {
            pendingOpenURL = url
        }
    }

    /// 在「外部文件」模式下打开一个本地文件（脱离 skill 包，直接渲染）
    func openExternalFile(_ url: URL) {
        externalFile = url
        // 自动收起导航栏（需求：右键打开文件时缩小导航栏，把空间让给正文）。
        // 记住进入前的收起状态，退出外部文件模式时恢复，尊重用户选择。
        if sidebarCollapseBeforeExternal == nil {
            sidebarCollapseBeforeExternal = sidebarUserCollapsed
        }
        sidebarUserCollapsed = true
        sidebarTransient = false
        activeSkill = nil
        activePath = nil
        currentFile = nil
        tocItems = []
        activeHeadingID = nil
        activeHeadingText = nil
        expandedSkills = []
        sourceMode = false
        if webReady {
            renderCurrent()
        } else {
            pendingOpenURL = url
        }
    }

    /// 退出「外部文件」模式（回到技能阅读），恢复导航栏到进入前的状态。
    /// 所有导航动作（选技能 / 打开文件 / 返回 / 切根 / 搜结果）统一走这里，避免状态残留。
    private func exitExternalMode() {
        if externalFile != nil {
            externalFile = nil
            if let saved = sidebarCollapseBeforeExternal {
                sidebarUserCollapsed = saved
            }
            sidebarCollapseBeforeExternal = nil
        }
        sidebarTransient = false
    }

    func renderCurrent() {
        guard webReady, let webView else { return }

        // 外部文件模式：直接渲染该文件，不走 skill 包逻辑
        if let ext = externalFile {
            renderExternal(ext)
            return
        }

        // 构建 payload
        var payload: [String: Any] = [:]
        guard let skill = activeSkill, let path = activePath,
              let file = currentFile, let abs = store.rawPath(skillPath: skill.path, relPath: path) else {
            payload["kind"] = "welcome"
            payload["lang"] = L10n.isChinese ? "zh" : "en"
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

    /// 渲染一个「外部文件」：复用现有 render.html 渲染器（md/代码/图片/PDF/纯文本）
    private func renderExternal(_ url: URL) {
        guard webReady, let webView else { return }
        let name = url.lastPathComponent
        let dir = url.deletingLastPathComponent()
        let kind = store.classify(name)

        var sizeStr = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? Int {
            sizeStr = store.humanSize(s)
        }

        var payload: [String: Any] = [:]
        switch kind {
        case .md:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            payload["kind"] = "md"
            payload["name"] = name
            payload["skillName"] = name
            payload["content"] = content
            payload["baseDir"] = dir.absoluteString
            payload["size"] = sizeStr
            if sourceMode { payload["sourceMode"] = true }

        case .code, .yaml, .json, .toml:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            payload["kind"] = kind.rawValue
            payload["name"] = name
            payload["content"] = content
            payload["baseDir"] = dir.absoluteString
            payload["size"] = sizeStr
            if let lang = store.language(for: name) { payload["lang"] = lang }

        case .text:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            payload["kind"] = "text"
            payload["name"] = name
            payload["content"] = content
            payload["baseDir"] = dir.absoluteString
            payload["size"] = sizeStr

        case .img, .pdf:
            payload["kind"] = kind.rawValue
            payload["name"] = name
            payload["path"] = url.absoluteString
            payload["size"] = sizeStr

        default:
            // .bin 等不支持类型
            payload["kind"] = "unsupported"
            payload["name"] = name
            payload["size"] = sizeStr
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

    /// 展开搜索框（ClaudeCode 风格折叠搜索）
    func expandSearch() {
        searchExpanded = true
    }

    /// 折叠搜索框（清空状态并收起）
    func collapseSearch() {
        searchExpanded = false
        searchText = ""
        searchResults = nil
        searchDone = false
    }

    func openSearchResult(_ result: SearchResult) {
        exitExternalMode()
        guard let skill = skills.first(where: { $0.path == result.path }) else { return }
        searchResults = nil
        searchDone = false
        searchText = ""
        searchExpanded = false
        if let entry = skill.entry {
            openFile(skill: skill, path: entry)
        } else {
            selectSkill(skill)
        }
    }

    // MARK: - 正文内查找（find-in-page）

    /// 切换查找栏：打开时正文内触发查找（复用当前 findText），
    /// 关闭时清除高亮并复位计数。
    func toggleFind() {
        findVisible.toggle()
        if findVisible {
            findInPage(findText)
        } else {
            closeFind()
        }
    }

    /// 输入即查找：把当前文字下发到正文 WebView 高亮。
    func findInPage(_ text: String) {
        findText = text
        guard webReady, let webView else { return }
        callJS("window.findInPage(\(jsonString(text)), {})", on: webView)
    }

    func findNext() {
        guard webReady, let webView, findCount > 0 else { return }
        callJS("window.findInPageNext()", on: webView)
    }

    func findPrev() {
        guard webReady, let webView, findCount > 0 else { return }
        callJS("window.findInPagePrev()", on: webView)
    }

    /// 关闭查找栏：复位状态并通知正文清除高亮。
    func closeFind() {
        findVisible = false
        findText = ""
        findCount = 0
        findIndex = -1
        guard webReady, let webView else { return }
        callJS("window.findInPageClose()", on: webView)
    }

    /// 由正文 WebView 回传的查找结果（命中数量 / 当前序号）。
    func updateFindResult(count: Int, index: Int) {
        findCount = count
        findIndex = index
    }

    // MARK: - 根目录

    func switchRoot(id: String) {
        store.setCurrentRootID(id)
        exitExternalMode()
        activeSkill = nil
        activePath = nil
        currentFile = nil
        selectedNodePath = nil
        selectedNodeIsDir = false
        tocItems = []
        // 立即渲染 welcome，避免旧智能体的内容在 reloadSkills 完成前残留
        renderCurrent()
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
