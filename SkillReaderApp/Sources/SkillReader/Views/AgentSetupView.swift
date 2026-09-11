import SwiftUI
import UniformTypeIdentifiers

// MARK: - 首次启动：Agent 配置页

/// 在 App 真正进入阅读器之前，让用户选择要纳入管理的 Agent，
/// 并允许自定义每个 Agent 的 skills 目录路径。
struct AgentSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var agents: [AgentProfile]
    @State private var showCustomForm = false
    @State private var segment: SetupSegment = .managed
    @State private var expandedID: String? = nil
    @State private var layout: SetupLayout = .grid
    @State private var isDropTarget = false

    /// 顶部分段：已管理 / 候选 / 自定义（互斥分区，避免同一 Agent 重复出现）。
    /// - 已管理：已启用纳入 SkillReader 管理的 Agent；
    /// - 候选：尚未启用、但已安装或可被配置的 Agent，等待用户决定是否纳入管理；
    /// - 自定义：用户手动添加的技能源目录。
    private enum SetupSegment: String, CaseIterable, Identifiable {
        case managed, candidates, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .managed:    return L10n.t("已管理", "Managed")
            case .candidates: return L10n.t("候选", "Candidates")
            case .custom:     return L10n.t("自定义", "Custom")
            }
        }
    }

    /// 列表 / 卡片 两种排布，解决宽屏下中间留白过多的问题
    private enum SetupLayout: String, CaseIterable, Identifiable {
        case list, grid
        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: return L10n.t("列表", "List")
            case .grid: return L10n.t("卡片", "Cards")
            }
        }
    }

    init() {
        let current = AgentRegistry.shared.agents
        // 首次启动（agents.json 不存在）时，用内置候选作为初始 seed
        if current.isEmpty {
            _agents = State(initialValue: AgentRegistry.candidates())
        } else {
            _agents = State(initialValue: current)
        }
    }

    /// 当前分段下应展示的 Agent（与另外两段互斥）。
    /// - 已管理：已启用纳入管理的 Agent；
    /// - 候选：未启用、但可作为技能源被管理的 Agent（含已安装未启用与未安装但可配置的内置候选）；
    /// - 自定义：用户手动添加的技能源目录。
    private var visibleAgents: [AgentProfile] {
        agents.filter { a in
            switch segment {
            case .managed:    return !a.isCustom && a.enabled
            case .candidates: return !a.isCustom && !a.enabled
            case .custom:     return a.isCustom
            }
        }
    }

    private var visibleIDs: Set<String> { Set(visibleAgents.map { $0.id }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // ── 分段切换 + 视图切换 ──
            HStack(spacing: 12) {
                Picker("", selection: $segment) {
                    ForEach(SetupSegment.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                Picker("", selection: $layout) {
                    Image(systemName: "list.bullet").tag(SetupLayout.list)
                    Image(systemName: "square.grid.2x2").tag(SetupLayout.grid)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help(L10n.t("切换列表 / 卡片视图", "Switch list / card view"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    if visibleAgents.isEmpty {
                        emptyHint
                            .padding(.horizontal, 16)
                            .id("listTop")
                    } else if layout == .grid {
                        // 卡片视图：自适应两列平铺，路径编辑常驻，横向空间不再浪费
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: 16)],
                            spacing: 16
                        ) {
                            ForEach($agents) { $agent in
                                if visibleIDs.contains(agent.id) {
                                    AgentCard(
                                        agent: $agent,
                                        onBrowse: { pickFolder(for: $agent) },
                                        onRemove: agent.isCustom ? { removeCustom(agent) } : nil
                                    )
                                    .id(agent.id)
                                }
                            }
                        }
                        .padding(16)
                        .id("listTop")
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach($agents) { $agent in
                                if visibleIDs.contains(agent.id) {
                                    AgentRow(
                                        agent: $agent,
                                        expanded: expandedID == agent.id,
                                        onToggleExpand: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                expandedID = expandedID == agent.id ? nil : agent.id
                                            }
                                        },
                                        onBrowse: { pickFolder(for: $agent) },
                                        onRemove: agent.isCustom ? { removeCustom(agent) } : nil
                                    )
                                    .id(agent.id)
                                }
                            }
                        }
                        .padding(16)
                        .id("listTop")
                    }

                    // 拖拽添加自定义 Agent 的落点提示区，只在「自定义」分段出现（含空状态）
                    if segment == .custom {
                        dropZone
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }

                    // 候选段：提供「添加 Agent」入口（复用自定义添加流程，递归发现 skill 根）
                    if segment == .candidates {
                        HStack {
                            Button {
                                showCustomForm = true
                            } label: {
                                Label(L10n.t("添加 Agent", "Add Agent"), systemImage: "plus")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
                .onChange(of: segment) { _, _ in
                    expandedID = nil
                    // 切换分段后回到列表顶部，避免旧滚动位置错位
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation { proxy.scrollTo("listTop", anchor: .top) }
                    }
                }
                .onChange(of: layout) { _, _ in
                    expandedID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation { proxy.scrollTo("listTop", anchor: .top) }
                    }
                }
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCustomForm) { customSheet }
    }

    private var emptyHint: some View {
        Text(hintText)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
            .padding(.horizontal, 4)
    }

    private var hintText: String {
        switch segment {
        case .managed:  return L10n.t("还没有纳入管理的 skill 源。可切到「候选」选择已安装的 Agent，或切到「自定义」手动添加目录。",
                                      "No managed skill sources yet. Switch to \"Candidates\" to enable installed Agents, or to \"Custom\" to add a directory manually.")
        case .candidates: return L10n.t("没有可配置的候选 skill 源。", "No candidate skill sources available.")
        case .custom:     return L10n.t("还没有自定义 skill 源，把文件夹拖到下方，或点虚线框选择文件夹自动添加。",
                                        "No custom skill source yet. Drag a folder below, or click the dashed box to pick a folder to add automatically.")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundStyle(isDropTarget ? Color.srAccent : Color.secondary)
        Text(L10n.t("拖文件夹到此，或点此选择文件夹，自动添加为自定义 Agent",
                    "Drop a folder here, or click to pick a folder to add as a custom Agent automatically"))
            .font(.system(size: 12))
            .foregroundStyle(isDropTarget ? Color.srAccent : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTarget ? Color.srAccent : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .onTapGesture { tapAddCustomFromPanel() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in handleDrop(providers) }
    }

    /// 点击拖拽区：弹出文件选择面板，选目录后自动创建自定义 Agent
    private func tapAddCustomFromPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择 Skills 目录", "Choose Skills Directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("选择", "Choose")
        if panel.runModal() == .OK, let url = panel.url, url.hasDirectoryPath {
            addCustomFromDrop(url: url)
        }
    }

    // MARK: 顶部说明

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("配置 skill 源", "Configure Skill Sources"))
                .font(.system(size: 18, weight: .bold))
            HStack(spacing: 0) {
                Text(L10n.t("选择你要管理的 skill 来源，SkillReader 会挂载到 ",
                            "Choose the skill sources you want to manage; SkillReader mounts them to "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    openSkillsMount()
                } label: {
                    Text("~/.agent/skills")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.srAccent)
                        .underline()
                }
                .buttonStyle(.plain)
                Text(L10n.t(" 下统一查看与管理。未自动识别的路径可手动修改。",
                            " for unified browsing and management. Paths not auto-detected can be edited manually."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button(L10n.t("稍后配置", "Configure Later")) {
                state.skipSetup()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.bordered)

            Button(L10n.t("完成配置", "Finish Setup")) {
                state.finishSetup(agents)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(agents.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 底部摘要：已管理 N 个，候选 M 个，共 X 个 skill
    private var summary: String {
        let enabled = agents.filter { $0.enabled }.count
        let candidates = agents.filter { !$0.isCustom && !$0.enabled }.count
        let totalSkills = agents.filter { $0.enabled }.reduce(0) { $0 + max($1.skillCount, 0) }
        return L10n.t("已管理 \(enabled) 个 · 候选 \(candidates) 个 · 共 \(totalSkills) 个 skill",
                       "\(enabled) managed · \(candidates) candidates · \(totalSkills) skills total")
    }

    // MARK: 自定义 Agent 表单

    @State private var customPath = ""
    @State private var customName = ""
    @State private var customId = ""

    private var customSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("添加自定义 Agent", "Add Custom Agent")).font(.headline)

            Text(L10n.t("必填：选择 Skills 目录。名称默认取上一级文件夹名，可手动修改。",
                        "Required: choose the Skills directory. The name defaults to the parent folder name and can be edited."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Skills 目录", "Skills Directory")).font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    TextField(L10n.t("例如 ~/.myagent/skills", "e.g. ~/.myagent/skills"), text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: customPath) { _, _ in syncDerivedFields() }
                    Button(L10n.t("浏览…", "Browse…")) { pickCustomFolder() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Agent 名称", "Agent Name")).font(.system(size: 12, weight: .medium))
                TextField(L10n.t("默认取上一级文件夹名", "Defaults to parent folder name"), text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text(L10n.t("ID：\(customId.isEmpty ? "—" : customId)", "ID: \(customId.isEmpty ? "—" : customId)"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(L10n.t("取消", "Cancel")) { resetCustomForm(); showCustomForm = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L10n.t("添加", "Add")) { confirmAddCustom() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(customPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .textFieldStyle(.roundedBorder)
        .onAppear { syncDerivedFields() }
    }

    /// 选目录后：派生名称 = 上一级文件夹名；派生 ID = 目录名 lowercase 化
    private func syncDerivedFields() {
        let path = customPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            customName = ""
            customId = ""
            return
        }
        let name = derivedName(from: path)
        if customName.isEmpty || customName == derivedName(from: customPath) {
            customName = name
        }
        customId = derivedID(from: name)
    }

    private func derivedName(from path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let name = url.lastPathComponent
        return name.isEmpty ? L10n.t("自定义", "Custom") : name
    }

    private func derivedID(from name: String) -> String {
        let lower = name.lowercased()
        let allowed = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        var s = String(allowed)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func pickCustomFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择 Skills 目录", "Choose Skills Directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("选择", "Choose")
        if !customPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            syncDerivedFields()
        }
    }

    private func resetCustomForm() {
        customPath = ""
        customName = ""
        customId = ""
    }

    private func confirmAddCustom() {
        let path = customPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        let id = customId.trimmingCharacters(in: .whitespaces).isEmpty
            ? derivedID(from: derivedName(from: path))
            : customId
        let name = customName.trimmingCharacters(in: .whitespaces).isEmpty
            ? derivedName(from: path)
            : customName

        // 递归发现用户所选目录下的所有 skill 根目录，自动填充主路径与额外路径。
        let (skillPath, extras) = SkillPathDiscovery.resolveAgentPaths(base: path)
        let agent = AgentProfile(
            id: id, name: name, vendor: L10n.t("自定义", "Custom"),
            iconName: "puzzlepiece.extension", skillPath: skillPath,
            extraSkillPaths: extras, enabled: true, isCustom: true
        )
        if !agents.contains(where: { $0.id == agent.id }) {
            agents.append(agent)
        }
        resetCustomForm()
        showCustomForm = false
        // 添加后自动跳到「自定义」段并展开新行，让用户立刻看到路径
        segment = .custom
        expandedID = agent.id
    }

    // MARK: 拖拽文件夹自动创建自定义 Agent

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-URL", options: nil) { item, _ in
            var url: URL?
            if let u = item as? URL { url = u }
            else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            guard let url, url.hasDirectoryPath else { return }
            DispatchQueue.main.async { self.addCustomFromDrop(url: url) }
        }
        return true
    }

    private func addCustomFromDrop(url: URL) {
        let path = url.path
        let name = derivedName(from: path)
        let id = derivedID(from: name)

        // 拖拽目录时同样递归发现其下所有 skill 根目录。
        let (skillPath, extras) = SkillPathDiscovery.resolveAgentPaths(base: path)
        let agent = AgentProfile(
            id: id, name: name, vendor: L10n.t("自定义", "Custom"),
            iconName: "puzzlepiece.extension", skillPath: skillPath,
            extraSkillPaths: extras, enabled: true, isCustom: true
        )
        if !agents.contains(where: { $0.id == agent.id }) {
            agents.append(agent)
        }
        // 拖入后自动跳到「自定义」段并展开新行
        segment = .custom
        expandedID = agent.id
    }

    // MARK: 自定义 Agent 删除（取消添加）

    private func removeCustom(_ agent: AgentProfile) {
        // 二次确认：删除的是配置项与挂载点，不会动你原目录里的 skills 文件
        let alert = NSAlert()
        alert.messageText = L10n.t("删除自定义 Agent", "Delete Custom Agent")
        alert.informativeText = L10n.t("确定删除「\(agent.name)」吗？它将从 SkillReader 管理中移除（仅移除配置与挂载，不会删除你原目录里的 skills 文件）。",
                                        "Delete \"\(agent.name)\"? It will be removed from SkillReader management (only config and mount are removed; the skills files in your original directory are untouched).")
        alert.addButton(withTitle: L10n.t("删除", "Delete"))
        alert.addButton(withTitle: L10n.t("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // 从列表移除；保存时 save() 会整体重建 ~/.agent/skills，对应符号链接自动清理
        if let idx = agents.firstIndex(where: { $0.id == agent.id }) {
            agents.remove(at: idx)
        }
        if expandedID == agent.id { expandedID = nil }
    }

    // MARK: 目录选择（内置 Agent 行展开后用）

    private func openSkillsMount() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AgentRegistry.shared.skillsMount))
    }

    private func pickFolder(for agent: Binding<AgentProfile>) {        let panel = NSOpenPanel()
        panel.title = L10n.t("选择 Skills 目录", "Choose Skills Directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("选择", "Choose")
        let current = agent.wrappedValue.skillPath
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            agent.wrappedValue.skillPath = url.path
        }
    }
}

// MARK: - 单个 Agent 行（行式 + 手风琴展开）

struct AgentRow: View {
    @Binding var agent: AgentProfile
    var expanded: Bool
    var onToggleExpand: () -> Void
    var onBrowse: () -> Void
    var onRemove: (() -> Void)? = nil   // 仅自定义 Agent 提供删除回调

    private var installed: Bool { agent.isInstalled }
    private var manageable: Bool { installed || agent.isCustom }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主行：点击整行任意空白处展开/收起；开关、去官网 互不干扰
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    AgentIcon(agent: agent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(.system(size: 14, weight: .medium))
                        HStack(spacing: 5) {
                            Circle()
                                .fill(installed ? Color.green : (agent.isCustom ? Color.blue.opacity(0.6) : Color.gray.opacity(0.5)))
                                .frame(width: 6, height: 6)
                            Text(installed ? L10n.t("已安装", "Installed") : (agent.isCustom ? L10n.t("自定义", "Custom") : L10n.t("未安装", "Not installed")))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if installed {
                                let count = agent.skillCount
                                Text(count > 0 ? L10n.t("· \(count) 个 skill", "· \(count) skill(s)") : L10n.t("· 暂无 skill", "· No skill yet"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(count > 0 ? .secondary : .tertiary)
                                if agent.extraSkillPaths.count > 0 {
                                    Text(L10n.t("· 多路径", "· Multi-path"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Spacer()

                // 候选（未安装、非自定义）：给出明确动作「去官网」
                if !manageable, let urlStr = agent.vendorUrl, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        Text(L10n.t("去官网", "Visit Site"))
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.srAccent, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // 可管理的才显示开关（未安装的内置候选无开关意义）
                if manageable {
                    if agent.isCustom {
                        // 自定义 Agent：提供删除入口（取消添加）
                        Button {
                            onRemove?()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("删除此自定义 Agent（取消添加）", "Delete this custom Agent (undo add)"))
                    }

                    Text(L10n.t("纳入管理", "Include in Management"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $agent.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: agent.enabled) { _, newVal in
                            // 首次纳入管理且原路径未命中任何 skill 时，自动递归检测，
                            // 让 Trae 这类非标准布局的 Agent 开箱即用；已手动改过的路径不会被覆盖。
                            if newVal && !agent.isCustom && agent.allSkillPaths.isEmpty {
                                agent.redetectSkillPaths()
                            }
                        }
                }

                // 展开箭头
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleExpand() }
            )

            // 展开区：路径编辑（手风琴，按需展开，主列表保持清爽）
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(agent.enabled
                         ? L10n.t("已纳入 SkillReader 管理，会挂载到 ~/.agent/skills 统一查看。",
                                 "Included in SkillReader management; mounted to ~/.agent/skills for unified browsing.")
                         : L10n.t("未纳入管理：关闭后该 Agent 的 skills 不会被读取。",
                                 "Not managed: with it off, this Agent's skills won't be read."))
                        .font(.system(size: 11))
                        .foregroundStyle(agent.enabled ? .secondary : .tertiary)
                    if !agent.isCustom {
                        Text(L10n.t("Skills 目录", "Skills Directory")).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        TextField("", text: $agent.skillPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button(L10n.t("浏览", "Browse"), action: onBrowse)
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        if !agent.isCustom && manageable {
                            Button {
                                agent.redetectSkillPaths()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("递归检测该 Agent 目录下的所有 skill 路径",
                                         "Recursively detect all skill paths under this Agent's directory"))
                        }
                    }
                    // 额外 skill 路径：可增删（修改），应对多目录 / 非标准布局
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(L10n.t("额外 skill 路径", "Extra Skill Paths"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button { pickExtraFolder() } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.t("添加额外 skill 路径", "Add extra skill path"))
                        }
                        ForEach(agent.extraSkillPaths, id: \.self) { p in
                            HStack(spacing: 4) {
                                Image(systemName: "link")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(agent.displayLabel(for: p))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(p)
                                Spacer()
                                Button {
                                    agent.extraSkillPaths.removeAll { $0 == p }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.t("移除该路径", "Remove this path"))
                            }
                        }
                        if agent.extraSkillPaths.isEmpty {
                            Text(L10n.t("暂无额外路径", "No extra paths"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 2)
                    if agent.isCustom {
                        HStack(spacing: 4) {
                            TextField(L10n.t("显示名称", "Display Name"), text: $agent.name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 140)
                            TextField(L10n.t("ID", "ID"), text: $agent.id)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .disabled(true)
                                .frame(width: 90)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.leading, 38) // 对齐到文字（图标 28 + 间距 10）
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(manageable && agent.enabled ? Color.srAccent.opacity(0.35)
                        : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    /// 浏览并追加一条额外 skill 路径（修改能力）：去重后写入 extraSkillPaths。
    private func pickExtraFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("添加额外 Skill 路径", "Add Extra Skill Path")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("添加", "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let real = (path as NSString).standardizingPath
        let existing = (agent.extraSkillPaths + [agent.skillPath]).map {
            (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        if !existing.contains(real) {
            agent.extraSkillPaths.append(path)
        }
    }
}

// MARK: - 单个 Agent 卡片（卡片 / 网格视图）

/// 与 AgentRow 信息等价，但以卡片形式平铺两列，解决宽屏中间留白。
/// 路径编辑常驻可见（不再手风琴收起），契合「卡片自己站得住」的目标。
struct AgentCard: View {
    @Binding var agent: AgentProfile
    var onBrowse: () -> Void
    var onRemove: (() -> Void)? = nil   // 仅自定义 Agent 提供删除回调

    @State private var showExtras: Bool = false

    private var installed: Bool { agent.isInstalled }
    private var manageable: Bool { installed || agent.isCustom }

    private var statusColor: Color {
        installed ? Color.green : (agent.isCustom ? Color.blue.opacity(0.6) : Color.gray.opacity(0.5))
    }

    private var statusText: String {
        if !installed {
            return agent.isCustom ? L10n.t("自定义", "Custom") : L10n.t("未安装", "Not installed")
        }
        let count = agent.skillCount
        var parts = [L10n.t("已安装", "Installed")]
        if count > 0 {
            parts.append(L10n.t("\(count) 个 skill", "\(count) skill(s)"))
        } else {
            parts.append(L10n.t("暂无 skill", "No skill yet"))
        }
        if agent.extraSkillPaths.count > 0 {
            parts.append(L10n.t("多路径", "Multi-path"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AgentIcon(agent: agent, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // 候选（未安装、非自定义）：给出明确动作「去官网」
                if !manageable, let urlStr = agent.vendorUrl, let url = URL(string: urlStr) {
                    Link(destination: url) {
                        Text(L10n.t("去官网", "Visit Site"))
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.srAccent, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // 可管理的才显示开关与（自定义）删除
                if manageable {
                    if agent.isCustom {
                        Button {
                            onRemove?()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("删除此自定义 Agent（取消添加）", "Delete this custom Agent (undo add)"))
                    }

                    Text(L10n.t("纳入管理", "Include"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $agent.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: agent.enabled) { _, newVal in
                            if newVal && !agent.isCustom && agent.allSkillPaths.isEmpty {
                                agent.redetectSkillPaths()
                            }
                        }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)

            // 路径区常驻：卡片视图下直接编辑；额外路径默认折叠，点击展开保持卡片对齐
            VStack(alignment: .leading, spacing: 4) {
                if !agent.isCustom {
                    Text(L10n.t("Skills 目录", "Skills Directory"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 4) {
                    TextField("", text: $agent.skillPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button(L10n.t("浏览", "Browse"), action: onBrowse)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    if !agent.isCustom {
                        Button {
                            agent.redetectSkillPaths()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t("递归检测该 Agent 目录下的所有 skill 路径",
                                     "Recursively detect all skill paths under this Agent's directory"))
                    }
                }
                // 额外 skill 路径：可增删（修改），应对多目录 / 非标准布局
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(L10n.t("额外 skill 路径", "Extra Skill Paths"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button { pickExtraFolder() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.t("添加额外 skill 路径", "Add extra skill path"))
                    }
                    if !agent.extraSkillPaths.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showExtras.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showExtras ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                Image(systemName: "link")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(L10n.t("额外 \(agent.extraSkillPaths.count) 个路径", "\(agent.extraSkillPaths.count) extra path(s)"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if showExtras {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(agent.extraSkillPaths, id: \.self) { p in
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder.badge.plus")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.tertiary)
                                        Text(agent.displayLabel(for: p))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(p)
                                        Spacer()
                                        Button {
                                            agent.extraSkillPaths.removeAll { $0 == p }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(L10n.t("移除该路径", "Remove this path"))
                                    }
                                    .padding(.leading, 14)
                                }
                            }
                        }
                    } else {
                        Text(L10n.t("暂无额外路径", "No extra paths"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(manageable && agent.enabled ? Color.srAccent.opacity(0.35)
                        : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    /// 浏览并追加一条额外 skill 路径（修改能力）：去重后写入 extraSkillPaths。
    private func pickExtraFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("添加额外 Skill 路径", "Add Extra Skill Path")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("添加", "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let real = (path as NSString).standardizingPath
        let existing = (agent.extraSkillPaths + [agent.skillPath]).map {
            (($0 as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        if !existing.contains(real) {
            agent.extraSkillPaths.append(path)
        }
    }
}

// MARK: - Agent 图标（优先官方 logo，兜底 SF Symbol）

struct AgentIcon: View {
    let agent: AgentProfile
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let logo = agent.logo,
               let img = AgentLogo.image(named: logo) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.214, style: .continuous))
            } else {
                Image(systemName: agent.iconName)
                    .font(.system(size: size * 0.71))
                    .foregroundStyle(agent.enabled ? Color.srAccent : Color.secondary)
                    .frame(width: size)
            }
        }
    }
}

/// 从 app 资源加载 Agent 官方 logo（Resources/logos/ 下）
enum AgentLogo {
    /// 归一化尺寸：把所有 logo 裁掉透明边、等比放大到内切、居中到统一画布，
    /// 保证不同来源（32~512px、留白各异）的图标视觉大小一致。
    private static let normalizedSize = 128

    static func image(named name: String) -> NSImage? {
        let fm = FileManager.default
        var srcURL: URL?
        // 1. .app 打包: Contents/Resources/logos/
        if let res = Bundle.main.resourceURL {
            let cand = res.appendingPathComponent("logos").appendingPathComponent("\(name).png")
            if fm.fileExists(atPath: cand.path) { srcURL = cand }
        }
        // 2. 裸可执行调试: 可执行文件同级 ../Sources/SkillReader/Resources/logos/
        if srcURL == nil, let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<4 { dir = dir.deletingLastPathComponent() } // 上溯到项目根
            let cand = dir.appendingPathComponent("Sources/SkillReader/Resources/logos").appendingPathComponent("\(name).png")
            if fm.fileExists(atPath: cand.path) { srcURL = cand }
        }
        guard let url = srcURL, let raw = NSImage(contentsOf: url) else { return nil }
        return AgentLogo.normalizedImage(from: raw)
    }

    /// 把任意尺寸/留白的 PNG 归一化为统一画布：去透明边 → 等比缩放到内切 → 居中。
    private static func normalizedImage(from img: NSImage) -> NSImage {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            return img
        }
        let srcW = CGFloat(rep.pixelsWide)
        let srcH = CGFloat(rep.pixelsHigh)
        guard srcW > 0, srcH > 0 else { return img }

        // 计算非透明区域的 bounding box（去透明边）
        var minX = Int(srcW), minY = Int(srcH), maxX = 0, maxY = 0
        let dpi = cg.width > 0 ? CGFloat(rep.pixelsWide) / CGFloat(cg.width) : 1
        let _ = dpi
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if a > 0.01 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        let contentW = max(maxX - minX + 1, 1)
        let contentH = max(maxY - minY + 1, 1)

        // 等比缩放到「内切」归一化画布（留 8% 边距，避免贴边）
        let target = CGFloat(normalizedSize)
        let margin = target * 0.08
        let scale = (target - margin * 2) / max(CGFloat(contentW), CGFloat(contentH))
        let drawW = CGFloat(contentW) * scale
        let drawH = CGFloat(contentH) * scale
        let drawX = (target - drawW) / 2
        let drawY = (target - drawH) / 2

        let out = NSImage(size: NSSize(width: target, height: target))
        out.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: target, height: target).fill()
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.interpolationQuality = .high
        // 按 bounding box 裁剪出内容（坐标系与 CGContext 一致，无需翻转），居中绘制
        let cropRect = NSRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(contentW), height: CGFloat(contentH))
        if let cropped = cg.cropping(to: cropRect) {
            ctx?.draw(cropped, in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
        }
        out.unlockFocus()
        out.isTemplate = false
        return out
    }
}
