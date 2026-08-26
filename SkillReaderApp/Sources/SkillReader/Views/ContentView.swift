import AppKit
import SwiftUI

// MARK: - 主布局

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            // 内容区永远在 ZStack 第一个子视图位置，只通过 padding 让出导航栏宽度，
            // 切换折叠/外部文件模式时不重建，@State 不丢（见 ui-pitfalls.md §C）。
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, state.sidebarDocked ? state.sidebarWidth : 0)
                .animation(.easeInOut(duration: 0.18), value: state.sidebarDocked)

            // 临时滑出时的遮罩：点空白收回
            if state.sidebarTransient {
                Color.black.opacity(0.05)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { state.sidebarTransient = false }
            }

            // 导航栏浮层：常驻（挤压内容）或临时滑出
            if state.sidebarDocked {
                SidebarView()
                    .frame(width: state.sidebarWidth)
            } else if state.sidebarTransient {
                SidebarView()
                    .frame(width: state.sidebarWidth)
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 3, y: 0)
                    .zIndex(1)
            }

            // 常驻时画一条右缘分隔线
            if state.sidebarDocked {
                Color(nsColor: .separatorColor)
                    .frame(width: 1, height: .infinity)
                    .offset(x: state.sidebarWidth)
                    .zIndex(2)
            }
        }
        .frame(minWidth: state.sidebarDocked ? state.sidebarDockedMinWidth : 700,
               maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .overlay(alignment: .top) { ToastView() }
        // 导航栏切换按钮放窗口标题栏（红绿灯右侧，macOS HIG / Safari 同款位置）
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.toggleSidebar()
                } label: {
                    Image(systemName: state.sidebarVisible ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 14))
                }
                .help(state.sidebarVisible ? "隐藏导航栏" : "显示导航栏")
            }
        }
        .onExitCommand { state.backToEntry() }
        .onAppear { enforceDefaultWidth() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // 窗口成为 key 后再兜底一次（onAppear 时窗口可能尚未 visible，guard 会直接返回）
            enforceDefaultWidth()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            // 过滤最小化代理 / 创建期瞬态零宽，避免把 windowWidth 压成极小值导致误判 autoCollapsed
            if let w = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized && $0.frame.width > 200 }) {
                state.updateWindowWidth(w.frame.width)
            }
        }
        .sheet(isPresented: Binding(
            get: { state.distributeSkillName != nil },
            set: { if !$0 { state.distributeSkillName = nil } }
        )) { DistributeSheet() }
    }

    // MARK: - 内容区（右侧）：面包屑 + 正文 + 可选大纲

    private var detail: some View {
        VStack(spacing: 0) {
            BreadcrumbBar()
            Divider()
            HStack(spacing: 0) {
                DocWebView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.tocVisible {
                    Divider()
                    TocView()
                        .frame(width: 220)
                }
            }
        }
    }

    /// 默认展开兜底：macOS 会记住窗口 frame，adhoc 重新打包后常带回上次窄尺寸，
    /// 导致 autoCollapsed 为真、一开就是折叠态。这里强制拉宽到默认展开态（见 §5）。
    /// 首次执行时窗口可能尚未可见，失败会自动重试最多 5 次。
    private func enforceDefaultWidth(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let candidates = ([NSApp.mainWindow, NSApp.keyWindow] as [NSWindow?]).compactMap { $0 }
                + NSApp.windows
            guard let window = candidates.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
                if attempt < 5 { self.enforceDefaultWidth(attempt: attempt + 1) }
                return
            }
            window.isRestorable = false
            let current = window.frame.width
            state.updateWindowWidth(current)
            // 外部文件（右键打开）模式下：窗口照常拉宽，但导航栏由 openExternalFile 自动收起
            let target = max(state.sidebarDockedMinWidth, 1040)
            let maxW = (window.screen?.visibleFrame.width ?? 1280) - 40
            if current < target, target <= maxW {
                var frame = window.frame
                frame.size.width = target
                frame.size.height = max(frame.size.height, 600)
                window.setFrame(frame, display: true)
                state.updateWindowWidth(frame.size.width)
            }
        }
    }
}

// MARK: - 分发到平台（skill 互通）

struct DistributeSheet: View {
    @EnvironmentObject var state: AppState

    private var platforms: [AgentProfile] {
        AgentRegistry.shared.agents.filter { $0.enabled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("分发到平台")
                .font(.headline)

            if let name = state.distributeSkillName {
                Text("把「\(SkillDistributor.linkBasename(for: name))」以符号链接同步到以下 Agent 的 skills 目录。链接即同源：改中心库，各平台即时生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if platforms.isEmpty {
                        Text("尚未纳入任何 Agent。请先在「配置 Agent」中勾选要管理的平台。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(platforms) { agent in
                            Toggle(isOn: platformBinding(for: agent.id)) {
                                HStack(spacing: 8) {
                                    AgentIcon(agent: agent)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(agent.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Text((agent.skillPath as NSString).expandingTildeInPath)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .frame(height: 190)

            HStack {
                if state.distributePlatforms.isEmpty, state.distributeSkillName != nil {
                    Text("不勾选任何平台 = 取消该 skill 的分发")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("取消") { state.distributeSkillName = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("保存并同步") { state.saveDistribution() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(platforms.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func platformBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { state.distributePlatforms.contains(id) },
            set: { on in
                if on { state.distributePlatforms.insert(id) }
                else { state.distributePlatforms.remove(id) }
            }
        )
    }
}

// MARK: - 面包屑

struct BreadcrumbBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let ext = state.externalFile {
                Image(systemName: "doc")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(ext.lastPathComponent)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            } else if let skill = state.activeSkill {
                Text(skill.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let path = state.activePath, path != skill.entry {
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text(path)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    state.openInEditor()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!state.canEditCurrent)
                .help(state.canEditCurrent ? "在系统编辑器中打开 (⌘E)" : "当前文件不可编辑")

                Button {
                    state.shareActive()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("分享：Finder 定位 + 复制路径 (⇧⌘S)")
            } else {
                Text("Skill Reader")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：折叠态 = 根目录名 + 搜索图标；展开态 = 全宽搜索框（ClaudeCode 风格）
            if state.searchExpanded {
                // 展开态：搜索框占满整行
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    TextField("搜索技能名 / 描述，回车全局搜索…", text: $state.searchText, onCommit: {
                        state.runSearch()
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .focused($searchFocus)
                    .onChange(of: searchFocus) { _, isFocused in
                        // 失焦且文本为空 → 自动折叠（点击空白处收起搜索框）
                        if !isFocused, state.searchText.isEmpty, state.searchResults == nil {
                            state.collapseSearch()
                        }
                    }
                    if !state.searchText.isEmpty {
                        Button {
                            state.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else {
                // 折叠态：左边根目录名，右边搜索图标
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(rootName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.expandSearch()
                        searchFocus = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("搜索 (⌘F)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider()

            // 列表
            if state.searchResults != nil {
                SearchResultList()
            } else {
                SkillList()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // ⌘F 来自菜单栏的搜索通知
        .onReceive(NotificationCenter.default.publisher(for: .skillReaderToggleSearch)) { _ in
            state.expandSearch()
            DispatchQueue.main.async { searchFocus = true }
        }
    }

    private var rootName: String {
        guard let id = state.store.currentRootID,
              let root = state.store.roots.first(where: { $0.id == id }) else {
            return "无技能库"
        }
        return root.name
    }
}

// MARK: - 技能列表（含展开树）

struct SkillList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(state.filteredSkills) { skill in
                    SkillRow(skill: skill)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .overlay {
            if state.filteredSkills.isEmpty {
                VStack(spacing: 8) {
                    Text(state.searchText.isEmpty
                         ? "没有可用的技能库"
                         : "没有匹配的技能")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    if state.searchText.isEmpty {
                        Text("请在「技能库」菜单中添加目录")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }
        }
    }
}

struct SkillRow: View {
    @EnvironmentObject var state: AppState
    let skill: Skill
    @State private var tree: FileNode?
    @State private var isHovered = false

    private var isExpanded: Bool { state.expandedSkills.contains(skill.path) }
    private var isActive: Bool { state.activeSkill?.path == skill.path }
    private var isStandalone: Bool { skill.kind == .standalone }
    private var contextKey: String { "s:" + skill.path }
    private var isContextTarget: Bool { state.contextTarget == contextKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isStandalone {
                // 独立 .md 文件：不渲染成文件夹，直接作为文件项打开
                Button {
                    state.clearContextTarget()
                    state.openFile(skill: skill, path: skill.entry ?? skill.path)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(skill.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                badge("独立", accent: false)
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowBackground)
                )
                .overlay(alignment: .leading) {
                    // 选中 / 右键目标：左侧竖条（参考 NavItem §6 选中态）
                    if isActive || isContextTarget {
                        Capsule()
                            .fill(Color.srAccent)
                            .frame(width: 2.5, height: 17)
                            .offset(x: -3)
                    }
                }
                .contextMenu {
                    Button("复制文件名") { state.copyItemName(skill: skill, rel: nil) }
                    Button("复制文件路径") { state.copyItemPath(skill: skill, rel: nil) }
                    Divider()
                    Button("复制副本") { state.duplicateItem(skill: skill, rel: nil) }
                    Button("移入废纸篓") { state.trashItem(skill: skill, rel: nil) }
                    Divider()
                    Button("打开访达") { state.revealItem(skill: skill, rel: nil) }
                    Divider()
                    Button("互通：复制到中心库并分发…") { state.copySkillToLibrary(skill) }
                }
            } else {
                Button {
                    state.clearContextTarget()
                    state.toggleSkill(skill)
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)
                            .padding(.top, 4)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(skill.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if skill.kind == .package {
                                    badge("包", accent: true)
                                }
                                if skill.stats.py > 0 {
                                    badge("py \(skill.stats.py)")
                                }
                                if skill.stats.md > 1 {
                                    badge("md \(skill.stats.md)")
                                }
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowBackground)
                )
                .overlay(alignment: .leading) {
                    // 选中 / 右键目标：左侧竖条（参考 NavItem §6 选中态）
                    if isActive || isContextTarget {
                        Capsule()
                            .fill(Color.srAccent)
                            .frame(width: 2.5, height: 17)
                            .offset(x: -3)
                    }
                }
                .contextMenu {
                    Button("复制文件名") { state.copyItemName(skill: skill, rel: nil) }
                    Button("复制文件路径") { state.copyItemPath(skill: skill, rel: nil) }
                    Divider()
                    Button("复制副本") { state.duplicateItem(skill: skill, rel: nil) }
                    Button("移入废纸篓") { state.trashItem(skill: skill, rel: nil) }
                    Divider()
                    Button("打开访达") { state.revealItem(skill: skill, rel: nil) }
                    Divider()
                    Button("互通：复制到中心库并分发…") { state.copySkillToLibrary(skill) }
                }

                if isExpanded {
                    if let tree {
                        FileTreeView(node: tree, skill: skill)
                            .padding(.leading, 14)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 30)
                            .padding(.vertical, 4)
                            .onAppear { loadTree() }
                    }
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { state.contextTarget = contextKey }
        }
    }

    private var rowBackground: Color {
        if isContextTarget { return Color.srAccentSoft }
        if isActive { return Color.srAccentSoft }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.9) }
        return .clear
    }

    private func badge(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(accent
                    ? Color.srAccent.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(accent ? Color.srAccent : Color.secondary)
    }

    private func loadTree() {
        if let cached = state.treeCache[skill.path] {
            tree = cached
            return
        }
        let node = state.store.tree(for: skill.path)
        if let node {
            node.children.forEach { markEntry($0, entry: skill.entry) }
            state.treeCache[skill.path] = node
        }
        tree = node
    }

    private func markEntry(_ node: FileNode, entry: String?) {
        if !node.isDir && node.path == entry {
            node.isEntry = true
        }
        node.children.forEach { markEntry($0, entry: entry) }
    }
}

// MARK: - 文件树

struct FileTreeView: View {
    @EnvironmentObject var state: AppState
    let node: FileNode
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(node.children) { child in
                if child.isDir {
                    DirNodeView(node: child, skill: skill)
                } else {
                    FileRowView(node: child, skill: skill)
                }
            }
        }
    }
}

struct DirNodeView: View {
    @EnvironmentObject var state: AppState
    let node: FileNode
    let skill: Skill
    @State private var expanded = false
    @State private var isHovered = false

    private var contextKey: String { "f:" + skill.path + "|" + node.path }
    private var isContextTarget: Bool { state.contextTarget == contextKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                state.clearContextTarget()
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 8)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(node.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(rowBackground)
            )
            .contextMenu {
                Button("复制文件名") { state.copyItemName(skill: skill, rel: node.path) }
                Button("复制文件路径") { state.copyItemPath(skill: skill, rel: node.path) }
                Divider()
                Button("复制副本") { state.duplicateItem(skill: skill, rel: node.path) }
                Button("移入废纸篓") { state.trashItem(skill: skill, rel: node.path) }
                Divider()
                Button("打开访达") { state.revealItem(skill: skill, rel: node.path) }
            }
            .onHover { hovering in
                isHovered = hovering
                if hovering { state.contextTarget = contextKey }
            }

            if expanded {
                FileTreeView(node: node, skill: skill)
                    .padding(.leading, 14)
            }
        }
    }

    private var rowBackground: Color {
        if isContextTarget { return Color.srAccentSoft }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.9) }
        return .clear
    }
}

struct FileRowView: View {
    @EnvironmentObject var state: AppState
    let node: FileNode
    let skill: Skill
    @State private var isHovered = false

    private var isActive: Bool {
        state.activePath == node.path && state.activeSkill?.path == skill.path
    }
    private var contextKey: String { "f:" + skill.path + "|" + node.path }
    private var isContextTarget: Bool { state.contextTarget == contextKey }

    var body: some View {
        Button {
            state.clearContextTarget()
            state.openFile(skill: skill, path: node.path)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: node.kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(node.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if node.isEntry {
                    Text("主")
                        .font(.system(size: 8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.srAccent.opacity(0.15)))
                        .foregroundStyle(Color.srAccent)
                }
                Spacer(minLength: 0)
                if !node.sizeHuman.isEmpty {
                    Text(node.sizeHuman)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
        .overlay(alignment: .leading) {
            // 选中 / 右键目标：左侧竖条（参考 NavItem §6 选中态）
            if isActive || isContextTarget {
                Capsule()
                    .fill(Color.srAccent)
                    .frame(width: 2.5, height: 15)
                    .offset(x: -3)
            }
        }
        .contextMenu {
            Button("复制文件名") { state.copyItemName(skill: skill, rel: node.path) }
            Button("复制文件路径") { state.copyItemPath(skill: skill, rel: node.path) }
            Divider()
            Button("复制副本") { state.duplicateItem(skill: skill, rel: node.path) }
            Button("移入废纸篓") { state.trashItem(skill: skill, rel: node.path) }
            Divider()
            Button("打开访达") { state.revealItem(skill: skill, rel: node.path) }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { state.contextTarget = contextKey }
        }
    }

    private var rowBackground: Color {
        if isContextTarget { return Color.srAccentSoft }
        if isActive { return Color.srAccentSoft }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.9) }
        return .clear
    }
}

// MARK: - 搜索结果

struct SearchResultList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if state.isSearching {
                    ProgressView().controlSize(.small).padding()
                } else if let results = state.searchResults {
                    if results.isEmpty {
                        Text("没有匹配的结果")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding()
                    } else {
                        ForEach(results) { result in
                            Button {
                                state.openSearchResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(result.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text(result.whereHit)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    if !result.snippet.isEmpty {
                                        Text(snippetText(result.snippet))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.srAccent.opacity(0.06))
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func snippetText(_ s: String) -> String {
        // 去掉 markdown 链接语法，保留可读文本
        s.replacingOccurrences(of: #"\[(.*?)\]\(.*?)"#, with: "$1", options: .regularExpression)
    }
}

// MARK: - TOC

struct TocView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("目录")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.tocItems) { item in
                        Button {
                            state.scrollToHeading(id: item.id)
                            state.activeHeadingID = item.id
                            state.activeHeadingText = item.text
                        } label: {
                            Text(item.text)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .foregroundStyle(isActive(item) ? Color.srAccent : Color.secondary)
                                .padding(.leading, leading(item.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            HStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(isActive(item) ? Color.srAccent : .clear)
                                    .frame(width: 2)
                                Spacer()
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func isActive(_ item: TocItem) -> Bool {
        state.activeHeadingID == item.id || state.activeHeadingText == item.text
    }

    private func leading(_ level: Int) -> CGFloat {
        switch level {
        case 2: return 16
        case 3: return 28
        default: return 6
        }
    }
}

// MARK: - 主题切换菜单（已挪到顶部菜单栏「技能库 → 主题」）

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var state: AppState

    /// 成功 / 提示态用绿色，错误态用红色；两者均为完全不透明填充，
    /// 在浅色与深色（含纯黑）背景下都清晰可读，不再出现「黑底黑 toast 看不见」的问题。
    private var fill: Color {
        state.toastIsError ? Color(nsColor: .systemRed) : Color.srSuccess
    }

    var body: some View {
        if let msg = state.toastMessage {
            Text(msg)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(fill)
                        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
                )
                // 细描边高光，让 toast 在任意背景上都能与底色分离
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
                )
                // 移到窗口顶部区域，避开底边；留出间距使其不压住面包屑栏
                .padding(.top, 56)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
