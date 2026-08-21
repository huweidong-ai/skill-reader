import SwiftUI

// MARK: - 首次启动：Agent 配置页（仿 CC Switch 风格）

/// 在 App 真正进入阅读器之前，让用户选择要纳入管理的 Agent，
/// 并允许自定义每个 Agent 的 skills 目录路径。
struct AgentSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var agents: [AgentProfile]
    @State private var showCustomForm = false
    @State private var customName = ""
    @State private var customId = ""
    @State private var customPath = ""

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

    // MARK: 顶部说明 + chip 行

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置要管理的 Agent")
                .font(.system(size: 18, weight: .bold))
            Text("勾选你本机安装的 Agent，SkillReader 会把它们的 skills 目录集中挂载到 ")
                + Text("~/.agent/skills").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.accentColor)
                + Text(" 下统一查看与管理。未自动识别的路径可手动修改。")

            // 工具栏（CC Switch 风格：操作集合）
            HStack(spacing: 8) {
                Button {} label: {
                    Label("检查更新", systemImage: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .help("检查已添加的 Agent 是否有新版本（待实现）")

                Button {} label: {
                    Label("从 ZIP 安装", systemImage: "square.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .help("从本地 ZIP 安装新 skill 包（待实现）")

                Button {} label: {
                    Label("发现技能", systemImage: "magnifyingglass").font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .help("打开技能市场浏览（待实现）")

                Spacer()
            }

            // Agent chip 横排（CC Switch 风格：Agent 名 + 数量）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(agents) { agent in
                        AgentChip(agent: agent)
                    }
                }
                .padding(.horizontal, 2)
            }
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

    private var customSheet: some View {
        VStack(spacing: 12) {
            Text("添加自定义 Agent").font(.headline)
            HStack {
                Text("名称").frame(width: 56, alignment: .trailing)
                TextField("显示名称", text: $customName)
            }
            HStack {
                Text("ID").frame(width: 56, alignment: .trailing)
                TextField("英文唯一，如 my-agent", text: $customId)
            }
            HStack {
                Text("目录").frame(width: 56, alignment: .trailing)
                TextField("Skills 目录路径", text: $customPath)
                Button("浏览") { pickCustomFolder() }
            }
            HStack {
                Spacer()
                Button("取消") { showCustomForm = false }
                Button("添加") {
                    let id = customId.trimmingCharacters(in: .whitespaces)
                        .lowercased()
                        .replacingOccurrences(of: " ", with: "-")
                    guard !id.isEmpty, !customName.isEmpty, !customPath.isEmpty else {
                        state.flashToast("请填写名称、ID 与目录", isError: true)
                        return
                    }
                    let agent = AgentProfile(id: id, name: customName, vendor: "自定义",
                                             iconName: "puzzlepiece", skillPath: customPath,
                                             enabled: true, isCustom: true)
                    agents.append(agent)
                    customName = ""; customId = ""; customPath = ""
                    showCustomForm = false
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 440)
        .textFieldStyle(.roundedBorder)
    }

    // MARK: 目录选择

    private func pickFolder(for agent: Binding<AgentProfile>) {
        guard let url = openDirPanel() else { return }
        agent.skillPath.wrappedValue = url.path
    }

    private func pickCustomFolder() {
        guard let url = openDirPanel() else { return }
        customPath = url.path
    }

    private func openDirPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 Skills 目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - 单个 Agent 卡片

struct AgentCard: View {
    @Binding var agent: AgentProfile
    var onBrowse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agent.iconName)
                    .font(.system(size: 20))
                    .foregroundStyle(agent.enabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.system(size: 14, weight: .semibold))
                    Text(agent.vendor).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: $agent.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
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

// MARK: - Agent chip（顶部横排：Agent 名 + skill 数）

struct AgentChip: View {
    let agent: AgentProfile

    var body: some View {
        let count = agent.skillCount
        let total = count > 0 ? count : 0
        HStack(spacing: 4) {
            Image(systemName: agent.iconName)
                .font(.system(size: 10))
            Text(agent.name)
                .font(.system(size: 11, weight: .medium))
            Text("\(total)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(agent.detected ? .accentColor : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(agent.detected ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1))
                .overlay(
                    Capsule().stroke(agent.detected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        )
        .foregroundStyle(.primary)
        .help("\(agent.skillPath)\n含 SKILL.md 的目录数: \(count < 0 ? "路径不存在" : "\(count)")")
    }
}