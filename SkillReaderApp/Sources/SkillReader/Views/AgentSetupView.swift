import SwiftUI

// MARK: - 首次启动：Agent 配置页

/// 在 App 真正进入阅读器之前，让用户选择要纳入管理的 Agent，
/// 并允许自定义每个 Agent 的 skills 目录路径。
struct AgentSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var agents: [AgentProfile]
    @State private var showCustomForm = false

    init() {
        let current = AgentRegistry.shared.agents
        // 首次启动（agents.json 不存在）时，用内置候选作为初始 seed
        if current.isEmpty {
            let seeded = AgentRegistry.candidates()
            _agents = State(initialValue: seeded)
        } else {
            _agents = State(initialValue: current)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach($agents) { $agent in
                        AgentCard(agent: $agent) { pickFolder(for: $agent) }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCustomForm) { customSheet }
    }

    // MARK: 顶部说明（简洁，不再抄 CC Switch 的不相关工具栏）

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("配置要管理的 Agent")
                .font(.system(size: 18, weight: .bold))
            Text("勾选你本机安装的 Agent，SkillReader 会把它们的 skills 目录集中挂载到 ")
                + Text("~/.agent/skills").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.accentColor)
                + Text(" 下统一查看与管理。未自动识别的路径可手动修改。")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack {
            Button {
                showCustomForm = true
            } label: {
                Label("添加自定义 Agent", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)

            // 统计摘要
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("稍后配置") {
                state.finishSetup(agents)
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
        let detected = agents.filter { $0.detected }.count
        let totalSkills = agents.filter { $0.enabled }.reduce(0) { $0 + max($1.skillCount, 0) }
        return "已选 \(enabled) / \(agents.count) 个 Agent · 本机已探测 \(detected) 个 · 共 \(totalSkills) 个 skill"
    }

    // MARK: 自定义 Agent 表单
    //
    // 设计原则：
    //   1) 必填项只有 Skills 目录（核心），目录选定后再派生其他字段
    //   2) Agent 名称默认 = 上一级目录名（用户可手动覆盖）
    //   3) ID 用目录名派生（自动）

    @State private var customPath = ""
    @State private var customName = ""
    @State private var customId = ""

    private var customSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加自定义 Agent").font(.headline)

            Text("必填：选择 Skills 目录。名称默认取上一级文件夹名，可手动修改。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            // 1. Skills 目录（必填）
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills 目录").font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    TextField("例如 ~/.myagent/skills", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onChange(of: customPath) { _ in syncDerivedFields() }
                    Button("浏览…") { pickCustomFolder() }
                }
            }

            // 2. Agent 名称（默认 = 上一级目录名，可编辑）
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
        agents.append(agent)
        resetCustomForm()
        showCustomForm = false
    }

    // MARK: 目录选择（内置 Agent 卡片用）

    private func pickFolder(for agent: Binding<AgentProfile>) {
        let panel = NSOpenPanel()
        panel.title = "选择 Skills 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            agent.wrappedValue.skillPath = url.path
        }
    }
}

// MARK: - 单个 Agent 卡片

struct AgentCard: View {
    @Binding var agent: AgentProfile
    var onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AgentIcon(agent: agent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.system(size: 14, weight: .semibold))
                    Text(agent.vendor).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $agent.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .help("开启后，该 Agent 的 skills 目录会挂载到 ~/.agent/skills，统一纳入 SkillReader 管理")
            }

            // 状态行：探测状态 + skill 数量
            HStack(spacing: 6) {
                Circle()
                    .fill(agent.detected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(agent.detected ? "已就绪" : "未安装 / 路径待确认")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if agent.detected {
                    Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                    let count = agent.skillCount
                    Text("\(count) 个 skill")
                        .font(.system(size: 10))
                        .foregroundStyle(count > 0 ? .primary : .tertiary)
                    if agent.extraSkillPaths.count > 0 {
                        Text("· 多路径").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            if agent.enabled {
                VStack(alignment: .leading, spacing: 4) {
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
                    // 额外路径（仅在有内容时显示）：合并的 skill 根目录
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
                                .frame(width: 120)
                            TextField("ID", text: $agent.id)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .disabled(true)
                                .frame(width: 90)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(agent.enabled ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
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
    static func image(named name: String) -> NSImage? {
        let fm = FileManager.default
        // 1. .app 打包: Contents/Resources/logos/
        if let res = Bundle.main.resourceURL {
            let cand = res.appendingPathComponent("logos").appendingPathComponent("\(name).png")
            if fm.fileExists(atPath: cand.path), let img = NSImage(contentsOf: cand) {
                return img
            }
        }
        // 2. 裸可执行调试: 可执行文件同级 ../Sources/SkillReader/Resources/logos/
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<4 { dir = dir.deletingLastPathComponent() } // 上溯到项目根
            let cand = dir.appendingPathComponent("Sources/SkillReader/Resources/logos").appendingPathComponent("\(name).png")
            if fm.fileExists(atPath: cand.path), let img = NSImage(contentsOf: cand) {
                return img
            }
        }
        return nil
    }
}