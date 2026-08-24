import SwiftUI
import UniformTypeIdentifiers

// MARK: - 首次启动：Agent 配置页

/// 在 App 真正进入阅读器之前，让用户选择要纳入管理的 Agent，
/// 并允许自定义每个 Agent 的 skills 目录路径。
struct AgentSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var agents: [AgentProfile]
    @State private var showCustomForm = false
    @State private var segment: SetupSegment = .installed
    @State private var expandedID: String? = nil
    @State private var isDropTarget = false

    /// 顶部分段：已安装 / 候选 / 自定义（互斥分区，避免同一 Agent 重复出现）
    private enum SetupSegment: String, CaseIterable, Identifiable {
        case installed, candidates, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed:  return "已安装"
            case .candidates: return "候选"
            case .custom:     return "自定义"
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
    /// 已安装/候选以「强安装探测 isInstalled」为准，而非仅看 skills 子目录是否存在——
    /// 残留空文件夹不再误判为已安装。
    private var visibleAgents: [AgentProfile] {
        agents.filter { a in
            switch segment {
            case .installed:  return !a.isCustom && a.isInstalled
            case .candidates: return !a.isCustom && !a.isInstalled
            case .custom:     return a.isCustom
            }
        }
    }

    private var visibleIDs: Set<String> { Set(visibleAgents.map { $0.id }) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // ── 分段切换：已安装 / 候选 / 自定义 ──
            Picker("", selection: $segment) {
                ForEach(SetupSegment.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if visibleAgents.isEmpty {
                            emptyHint
                        } else {
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

                        // 拖拽添加自定义 Agent 的落点提示区，只在「自定义」分段出现
                        if segment == .custom {
                            dropZone
                        }
                    }
                    .padding(16)
                    .id("listTop")
                }
                .onChange(of: segment) { _, _ in
                    expandedID = nil
                    // 切换分段后回到列表顶部，避免旧滚动位置错位
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
        case .installed:  return "本机尚未检测到已安装的 Agent。可切到「候选」手动指定路径，或切到「自定义」添加。"
        case .candidates: return "没有未配置的候选 Agent。"
        case .custom:     return "还没有自定义 Agent，把文件夹拖到下方，或点虚线框选择文件夹自动添加。"
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)
            Text("拖文件夹到此，或点此选择文件夹，自动添加为自定义 Agent")
                .font(.system(size: 12))
                .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isDropTarget ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .onTapGesture { tapAddCustomFromPanel() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in handleDrop(providers) }
    }

    /// 点击拖拽区：弹出文件选择面板，选目录后自动创建自定义 Agent
    private func tapAddCustomFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Skills 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url, url.hasDirectoryPath {
            addCustomFromDrop(url: url)
        }
    }

    // MARK: 顶部说明

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配置要管理的 Agent")
                .font(.system(size: 18, weight: .bold))
            HStack(spacing: 0) {
                Text("勾选你本机安装的 Agent，SkillReader 会把它们的 skills 目录集中挂载到 ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button {
                    openSkillsMount()
                } label: {
                    Text("~/.agent/skills")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .underline()
                }
                .buttonStyle(.plain)
                Text(" 下统一查看与管理。未自动识别的路径可手动修改。")
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

            Button("稍后配置") {
                state.skipSetup()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.bordered)

            Button("完成配置") {
                state.finishSetup(agents)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(agents.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 底部摘要：已选 N 个，本机已安装 M 个
    private var summary: String {
        let enabled = agents.filter { $0.enabled }.count
        let installed = agents.filter { $0.isInstalled }.count
        let totalSkills = agents.filter { $0.enabled }.reduce(0) { $0 + max($1.skillCount, 0) }
        return "已选 \(enabled) / \(agents.count) 个 Agent · 本机已安装 \(installed) 个 · 共 \(totalSkills) 个 skill"
    }

    // MARK: 自定义 Agent 表单

    @State private var customPath = ""
    @State private var customName = ""
    @State private var customId = ""

    private var customSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义 Agent").font(.headline)

            Text("必填：选择 Skills 目录。名称默认取上一级文件夹名，可手动修改。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Skills 目录").font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    TextField("例如 ~/.myagent/skills", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: customPath) { _, _ in syncDerivedFields() }
                    Button("浏览…") { pickCustomFolder() }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 名称").font(.system(size: 12, weight: .medium))
                TextField("默认取上一级文件夹名", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("ID：\(customId.isEmpty ? "—" : customId)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("取消") { resetCustomForm(); showCustomForm = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("添加") { confirmAddCustom() }
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
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let parentName = url.deletingLastPathComponent().lastPathComponent
        if customName.isEmpty || customName == derivedName(from: customPath) {
            customName = parentName.isEmpty ? "自定义" : parentName
        }
        customId = derivedID(from: parentName)
    }

    private func derivedName(from path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return url.deletingLastPathComponent().lastPathComponent
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
        panel.title = "选择 Skills 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
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
        let agent = AgentProfile(
            id: id, name: name, vendor: "自定义",
            iconName: "puzzlepiece.extension", skillPath: path,
            enabled: true, isCustom: true
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
        let parentName = url.deletingLastPathComponent().lastPathComponent
        let name = parentName.isEmpty ? "自定义" : parentName
        let id = derivedID(from: name)
        let agent = AgentProfile(
            id: id, name: name, vendor: "自定义",
            iconName: "puzzlepiece.extension", skillPath: path,
            enabled: true, isCustom: true
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
        alert.messageText = "删除自定义 Agent"
        alert.informativeText = "确定删除「\(agent.name)」吗？它将从 SkillReader 管理中移除（仅移除配置与挂载，不会删除你原目录里的 skills 文件）。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
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
        panel.title = "选择 Skills 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
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
                            Text(installed ? "已安装" : (agent.isCustom ? "自定义" : "未安装"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if installed {
                                let count = agent.skillCount
                                Text(count > 0 ? "· \(count) 个 skill" : "· 暂无 skill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(count > 0 ? .secondary : .tertiary)
                                if agent.extraSkillPaths.count > 0 {
                                    Text("· 多路径")
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
                        Text("去官网")
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor, lineWidth: 0.5)
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
                        .help("删除此自定义 Agent（取消添加）")
                    }

                    Text("纳入管理")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $agent.enabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
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
                         ? "已纳入 SkillReader 管理，会挂载到 ~/.agent/skills 统一查看。"
                         : "未纳入管理：关闭后该 Agent 的 skills 不会被读取。")
                        .font(.system(size: 11))
                        .foregroundStyle(agent.enabled ? .secondary : .tertiary)
                    if !agent.isCustom {
                        Text("Skills 目录").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        TextField("", text: $agent.skillPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Button("浏览", action: onBrowse)
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                    }
                    if !agent.extraSkillPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("额外 skill 路径")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            ForEach(agent.extraSkillPaths, id: \.self) { p in
                                HStack(spacing: 4) {
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Text(p)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                    if agent.isCustom {
                        HStack(spacing: 4) {
                            TextField("显示名称", text: $agent.name)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .frame(width: 140)
                            TextField("ID", text: $agent.id)
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
                .stroke(manageable && agent.enabled ? Color.accentColor.opacity(0.35)
                        : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Agent 图标（优先官方 logo，兜底 SF Symbol）

struct AgentIcon: View {
    let agent: AgentProfile

    var body: some View {
        Group {
            if let logo = agent.logo,
               let img = AgentLogo.image(named: logo) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: agent.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(agent.enabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
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
        // 源图坐标 y 轴翻转，按 bounding box 截取并绘制到居中位置
        let cropRect = NSRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(contentW), height: CGFloat(contentH))
        if let cropped = cg.cropping(to: cropRect) {
            ctx?.saveGState()
            ctx?.translateBy(x: 0, y: target)
            ctx?.scaleBy(x: 1, y: -1)
            ctx?.draw(cropped, in: NSRect(x: drawX, y: drawY, width: drawW, height: drawH))
            ctx?.restoreGState()
        }
        out.unlockFocus()
        out.isTemplate = false
        return out
    }
}
