import Foundation

// MARK: - Agent 配置模型

/// 一个被 SkillReader 管理的 Agent（Claude Code / OpenClaw / WorkBuddy …）
/// `detected` 是运行时探测结果，不写入配置文件（每次载入都重新探测）。
struct AgentProfile: Identifiable, Codable, Equatable {
    var id: String            // 唯一 ID，也是 ~/.agent/skills 下的符号链接名
    var name: String          // 显示名
    var vendor: String        // 厂商 / 来源
    var iconName: String      // SF Symbol
    var execPath: String      // Agent 可执行路径（可选，仅展示用）
    var skillPath: String     // skills 目录绝对路径（核心）
    var enabled: Bool         // 是否在 SkillReader 中纳入管理
    var isCustom: Bool        // 是否用户自定义 Agent
    var detected: Bool        // 运行时探测：skillPath 是否存在

    init(id: String, name: String, vendor: String, iconName: String,
         execPath: String = "", skillPath: String, enabled: Bool = false,
         isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.iconName = iconName
        self.execPath = execPath
        self.skillPath = skillPath
        self.enabled = enabled
        self.isCustom = isCustom
        self.detected = FileManager.default.fileExists(
            atPath: (skillPath as NSString).expandingTildeInPath)
    }

    // detected 不参与持久化：CodingKeys 不含它，解码后由 init(from:) 重新探测。
    enum CodingKeys: String, CodingKey {
        case id, name, vendor, iconName, execPath, skillPath, enabled, isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(String.self, forKey: .vendor)
        iconName = try c.decode(String.self, forKey: .iconName)
        execPath = try c.decodeIfPresent(String.self, forKey: .execPath) ?? ""
        skillPath = try c.decode(String.self, forKey: .skillPath)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        // 解码后即时重新探测真实存在性
        detected = FileManager.default.fileExists(
            atPath: (skillPath as NSString).expandingTildeInPath)
    }
}

// MARK: - Agent 注册中心（读写 ~/.agent 集中管理）

@MainActor
final class AgentRegistry: ObservableObject {
    static let shared = AgentRegistry()

    let agentsDir: String
    let skillsMount: String
    let configPath: String

    @Published var agents: [AgentProfile] = []

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        agentsDir = (home as NSString).appendingPathComponent(".agent")
        skillsMount = (agentsDir as NSString).appendingPathComponent("skills")
        configPath = (agentsDir as NSString).appendingPathComponent("agents.json")
        loadOrSeed()
    }

    // MARK: 内置候选（用户点名 + 国内常见 Agent）

    static func candidates() -> [AgentProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = { (sub: String) -> String in (home as NSString).appendingPathComponent(sub) }
        return [
            AgentProfile(id: "workbuddy", name: "WorkBuddy", vendor: "腾讯", iconName: "bubble.left.and.text.bubble.right",
                         skillPath: p(".workbuddy/skills")),
            AgentProfile(id: "codebuddy", name: "CodeBuddy", vendor: "腾讯", iconName: "hammer",
                         skillPath: p(".codebuddy/skills")),
            AgentProfile(id: "openclaw", name: "OpenClaw", vendor: "开源", iconName: "shippingbox",
                         skillPath: p(".openclaw/skills")),
            AgentProfile(id: "claude-code", name: "Claude Code", vendor: "Anthropic", iconName: "brain",
                         skillPath: p(".claude/skills")),
            AgentProfile(id: "codex", name: "Codex CLI", vendor: "OpenAI", iconName: "terminal",
                         skillPath: p(".codex/skills")),
            AgentProfile(id: "gemini-cli", name: "Gemini CLI", vendor: "Google", iconName: "sparkle",
                         skillPath: p(".gemini/skills")),
            AgentProfile(id: "opencode", name: "OpenCode", vendor: "Anomaly", iconName: "curlybraces",
                         skillPath: p(".config/opencode/skills")),
            AgentProfile(id: "hermes", name: "Hermes Agent", vendor: "Nous Research", iconName: "wind",
                         skillPath: p(".hermes/skills")),
            AgentProfile(id: "qoderwork", name: "QoderWork", vendor: "阿里", iconName: "qrcode.viewfinder",
                         skillPath: p(".qoderwork/skills")),
            AgentProfile(id: "trae", name: "Trae", vendor: "字节", iconName: "globe",
                         skillPath: p(".trae/skills")),
            AgentProfile(id: "kimi-code", name: "Kimi Code", vendor: "月之暗面", iconName: "moon.stars",
                         skillPath: p(".kimi/skills")),
        ]
    }

    // MARK: 载入或播种

    func loadOrSeed() {
        if let loaded = load() {
            agents = loaded
        } else {
            // 首次启动：保持 agents 为空，让 needsSetup == true，显示 Agent 配置页
            agents = []
        }
    }

    func load() -> [AgentProfile]? {
        guard FileManager.default.fileExists(atPath: configPath) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let arr = try? JSONDecoder().decode([AgentProfile].self, from: data) else { return nil }
        return arr
    }

    /// id -> 显示名，供 SkillStore 在扫描 ~/.agent/skills 时给 root 打标签
    func labelMap() -> [String: String] {
        Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
    }

    // MARK: 持久化 + 建立符号链接

    func save(_ list: [AgentProfile]) {
        agents = list
        let fm = FileManager.default
        try? fm.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: skillsMount, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(agents) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }

        rebuildSymlinks()
    }

    private func rebuildSymlinks() {
        // ~/.agent/skills 是本工具的专属集中管理目录，整体重建
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: skillsMount) {
            for name in existing {
                let pth = (skillsMount as NSString).appendingPathComponent(name)
                try? FileManager.default.removeItem(atPath: pth)
            }
        }
        for agent in agents where agent.enabled {
            let target = (agent.skillPath as NSString).expandingTildeInPath
            let link = (skillsMount as NSString).appendingPathComponent(agent.id)
            try? AgentRegistry.linkAgent(link: link, target: target)
        }
    }

    /// 建立/重建单个 Agent 的符号链接（供测试与 rebuildSymlinks 复用）
    /// 目标不存在时自动创建目录，保证挂载点始终可用。
    static func linkAgent(link: String, target: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: link)
        if !fm.fileExists(atPath: target) {
            try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
    }

    /// 是否需要首次配置（无配置 或 没有任何 Agent 被纳入管理）
    var needsSetup: Bool {
        agents.isEmpty || agents.allSatisfy { !$0.enabled }
    }
}

// MARK: - 运行时辅助

extension AgentProfile {
    /// 探测 skillPath 下 skill 数量（仅统计包含 SKILL.md 的目录，过滤隐藏文件）
    /// 供 UI 展示「N 个技能」标签使用；返回 -1 表示路径不存在。
    var skillCount: Int {
        let path = (skillPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return -1
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        var count = 0
        for name in entries where !name.hasPrefix(".") {
            var subIsDir: ObjCBool = false
            let sub = (path as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: sub, isDirectory: &subIsDir),
               subIsDir.boolValue {
                // 含 SKILL.md 才算真正的 skill 包
                let skillMD = (sub as NSString).appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: skillMD) {
                    count += 1
                }
            }
        }
        return count
    }
}
