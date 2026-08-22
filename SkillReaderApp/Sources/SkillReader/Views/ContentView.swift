import AppKit
import SwiftUI

// MARK: - 主布局

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)

            VStack(spacing: 0) {
                BreadcrumbBar()
                Divider()
                DocWebView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

            if state.tocVisible {
                TocView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            }
        }
        .overlay(alignment: .bottom) { ToastView() }
        .onExitCommand { state.backToEntry() }
    }
}

// MARK: - 面包屑

struct BreadcrumbBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let skill = state.activeSkill {
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
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!state.canEditCurrent)
                .help(state.canEditCurrent ? "在系统编辑器中打开 (⌘E)" : "当前文件不可编辑")

                Button {
                    state.shareActive()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("分享：Finder 定位 + 复制路径 (⇧⌘S)")

                Button {
                    state.revealActiveFile()
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("在 Finder 中定位")
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

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：根目录切换 + 刷新
            HStack(spacing: 6) {
                Menu {
                    ForEach(state.store.roots) { root in
                        Button {
                            state.switchRoot(id: root.id)
                        } label: {
                            HStack {
                                Text(root.name)
                                    .lineLimit(1)
                                if state.store.currentRootID == root.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(rootName)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)

                Spacer()

                Button {
                    state.reloadSkills()
                    state.flashToast("已刷新")
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("刷新技能列表")

                Button {
                    let panel = NSOpenPanel()
                    panel.title = "选择技能库根目录"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "添加"
                    if panel.runModal() == .OK, let url = panel.url {
                        state.store.addRoot(path: url.path)
                        state.switchRoot(id: state.store.currentRootID ?? "")
                        state.flashToast("已添加技能库")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("添加技能库目录")

                Button {
                    state.reopenSetup()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("配置 Agent")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // 搜索框
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("搜索技能名 / 描述，回车全局搜索…", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { state.runSearch() }
                if !state.searchText.isEmpty {
                    Button {
                        state.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // 列表
            if state.searchResults != nil {
                SearchResultList()
            } else {
                SkillList()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                .contextMenu {
                    Button("复制文件名") { state.copyItemName(skill: skill, rel: nil) }
                    Button("复制文件路径") { state.copyItemPath(skill: skill, rel: nil) }
                    Divider()
                    Button("复制副本") { state.duplicateItem(skill: skill, rel: nil) }
                    Button("移入废纸篓") { state.trashItem(skill: skill, rel: nil) }
                    Divider()
                    Button("打开访达") { state.revealItem(skill: skill, rel: nil) }
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
                .contextMenu {
                    Button("复制文件名") { state.copyItemName(skill: skill, rel: nil) }
                    Button("复制文件路径") { state.copyItemPath(skill: skill, rel: nil) }
                    Divider()
                    Button("复制副本") { state.duplicateItem(skill: skill, rel: nil) }
                    Button("移入废纸篓") { state.trashItem(skill: skill, rel: nil) }
                    Divider()
                    Button("打开访达") { state.revealItem(skill: skill, rel: nil) }
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
        if isContextTarget { return Color.accentColor.opacity(0.18) }
        if isActive { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.8) }
        return .clear
    }

    private func badge(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(accent
                    ? Color.accentColor.opacity(0.12)
                    : Color(nsColor: .controlBackgroundColor))
            )
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
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
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
        if isContextTarget { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.8) }
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
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
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
        if isContextTarget { return Color.accentColor.opacity(0.18) }
        if isActive { return Color.accentColor.opacity(0.12) }
        if isHovered { return Color(nsColor: .controlBackgroundColor).opacity(0.8) }
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
                                    .fill(Color.accentColor.opacity(0.06))
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
        s.replacingOccurrences(of: #"\[(.*?)\]\(.*?\)"#, with: "$1", options: .regularExpression)
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
                                .foregroundStyle(isActive(item) ? Color.accentColor : Color.secondary)
                                .padding(.leading, leading(item.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            HStack(spacing: 0) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(isActive(item) ? Color.accentColor : .clear)
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

// MARK: - Toast

struct ToastView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let msg = state.toastMessage {
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(state.toastIsError ? Color.accentColor : Color.black.opacity(0.78))
                )
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
