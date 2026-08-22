import Foundation

// MARK: - Agent 配置模型

/// 一个被 SkillReader 管理的 Agent（Claude Code / OpenClaw / WorkBuddy …）
/// `detected` 是运行时探测结果，不写入配置文件（每次载入都重新探测）。
/// 部分 Agent（OpenClaw / QoderWork 等）有多个 skill 目录：托管 / 工作区 / 内置 等，
/// 通过 `extraSkillPaths` 合并参与探测；skillCount 跨路径去重计数。
struct AgentProfile: Identifiable, Codable, Equatable {
    var id: String            // 唯一 ID，也是 ~/.agent/skills 下的符号链接名
    var name: String          // 显示名
    var vendor: String        // 厂商 / 来源
    var iconName: String      // SF Symbol（无官方 logo 时兜底）
    var logo: String?         // 官方 logo 资源名（Resources/logos/xxx.png），nil 用 iconName
    var execPath: String      // Agent 可执行路径（可选，仅展示用）
    var skillPath: String     // 核心 skills 目录绝对路径（也是 ~/.agent/skills 下的 symlink 目标）
    var extraSkillPaths: [String] = []   // 其它 skill 目录（OpenClaw workspace / 内置 / 跨 Agent 共用 等）
    var enabled: Bool         // 是否在 SkillReader 中纳入管理
    var isCustom: Bool        // 是否用户自定义 Agent
    var detected: Bool        // 运行时探测：任一路径存在即为 true（不持久化）

    init(id: String, name: String, vendor: String, iconName: String, logo: String? = nil,
         execPath: String = "", skillPath: String, extraSkillPaths: [String] = [],
         enabled: Bool = false, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.iconName = iconName
        self.logo = logo
        self.execPath = execPath
        self.skillPath = skillPath
        self.extraSkillPaths = extraSkillPaths
        self.enabled = enabled
        self.isCustom = isCustom
        self.detected = AgentProfile.detect(paths: [skillPath] + extraSkillPaths)
    }

    private static func detect(paths: [String]) -> Bool {
        let fm = FileManager.default
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return true }
        }
        return false
    }

    // detected 不参与持久化：CodingKeys 不含它，解码后由 init(from:) 重新探测。
    enum CodingKeys: String, CodingKey {
        case id, name, vendor, iconName, logo, execPath, skillPath, extraSkillPaths, enabled, isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(String.self, forKey: .vendor)
        iconName = try c.decode(String.self, forKey: .iconName)
        logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? nil
        execPath = try c.decodeIfPresent(String.self, forKey: .execPath) ?? ""
        skillPath = try c.decode(String.self, forKey: .skillPath)
        extraSkillPaths = try c.decodeIfPresent([String].self, forKey: .extraSkillPaths) ?? []
        enabled = try c.decode(Bool.self, forKey: .enabled)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        // 解码后即时重新探测真实存在性
        detected = AgentProfile.detect(paths: [skillPath] + extraSkillPaths)
    }

    /// 全部 skill 目录（核心 + 额外），已展开 ~；重复路径去重
    var allSkillPaths: [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for raw in [skillPath] + extraSkillPaths {
            let expanded = (raw as NSString).expandingTildeInPath
            let real = (expanded as NSString).standardizingPath
            if seen.insert(real).inserted {
                result.append(expanded)
            }
        }
        // 过滤掉不存在的，避免 UI 噪音
        return result.filter { fm.fileExists(atPath: $0) }
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

    // MARK: 内置候选（国际在前：Codex / Claude Code / OpenClaw / OpenCode / Hermes，
    //       国产在后：WorkBuddy / Trae / Qoder / CodeBuddy / Kimi …）
    // 官方 logo 放 Resources/logos/（来源：GitHub org avatar / 官网 favicon），
    // 无 logo 的用 SF Symbol 兜底。

    static func candidates() -> [AgentProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = { (sub: String) -> String in (home as NSString).appendingPathComponent(sub) }
        return [
            // ── 国际 ──
            AgentProfile(id: "codex", name: "Codex CLI", vendor: "OpenAI", iconName: "terminal",
                         logo: "codex", skillPath: p(".codex/skills")),
            AgentProfile(id: "claude-code", name: "Claude Code", vendor: "Anthropic", iconName: "brain",
                         logo: "claude-code", skillPath: p(".claude/skills")),
            // OpenClaw 真实 skill 在 workspace/skills，~/.openclaw/skills 多数为空
            // 也共用 ~/.agents/skills（与 Claude Code 共享）
            AgentProfile(id: "openclaw", name: "OpenClaw", vendor: "开源", iconName: "shippingbox",
                         logo: "openclaw", skillPath: p(".openclaw/skills"),
                         extraSkillPaths: [p(".openclaw/workspace/skills"), p(".agents/skills")]),
            AgentProfile(id: "opencode", name: "OpenCode", vendor: "Anomaly", iconName: "curlybraces",
                         logo: "opencode", skillPath: p(".config/opencode/skills")),
            AgentProfile(id: "hermes", name: "Hermes Agent", vendor: "Nous Research", iconName: "wind",
                         logo: "hermes", skillPath: p(".hermes/skills")),
            AgentProfile(id: "gemini-cli", name: "Gemini CLI", vendor: "Google", iconName: "sparkle",
                         skillPath: p(".gemini/skills")),
            // ── 国产 ──
            AgentProfile(id: "workbuddy", name: "WorkBuddy", vendor: "腾讯", iconName: "bubble.left.and.text.bubble.right",
                         logo: "workbuddy", skillPath: p(".workbuddy/skills")),
            AgentProfile(id: "trae", name: "Trae", vendor: "字节", iconName: "globe",
                         logo: "trae", skillPath: p(".trae/skills")),
            AgentProfile(id: "qoderwork", name: "QoderWork", vendor: "阿里", iconName: "qrcode.viewfinder",
                         logo: "qoderwork", skillPath: p(".qoderwork/skills")),
            AgentProfile(id: "codebuddy", name: "CodeBuddy", vendor: "腾讯", iconName: "hammer",
                         logo: "codebuddy", skillPath: p(".codebuddy/skills")),
            AgentProfile(id: "kimi-code", name: "Kimi Code", vendor: "月之暗面", iconName: "moon.stars",
                         logo: "kimi", skillPath: p(".kimi/skills")),
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
        let fm = FileManager.default
        // ~/.agent/skills 是本工具的专属集中管理目录，整体重建
        if let existing = try? fm.contentsOfDirectory(atPath: skillsMount) {
            for name in existing {
                let pth = (skillsMount as NSString).appendingPathComponent(name)
                try? fm.removeItem(atPath: pth)
            }
        }
        for agent in agents where agent.enabled {
            let link = (skillsMount as NSString).appendingPathComponent(agent.id)
            // 收集所有「存在」的源路径（核心 + 额外），按稳定顺序去重
            var seen = Set<String>()
            var sources: [(label: String, path: String)] = []
            let all = [("core", agent.skillPath)] + agent.extraSkillPaths.enumerated().map { ("extra\($0)", $1) }
            for (label, raw) in all {
                let path = (raw as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let real = (path as NSString).standardizingPath
                if seen.insert(real).inserted {
                    sources.append((label, real))
                }
            }
            // 单个源：直接单层 symlink（保持原有读取逻辑不变）
            if sources.count == 1 {
                try? AgentRegistry.linkAgent(link: link, target: sources[0].path)
            } else if sources.count > 1 {
                // 多路径：聚合目录 —— 在 <id>/ 下为每个源建立二级 symlink，
                // 让 SkillStore 下钻一层即可读到所有来源的 skill（OpenClaw 多路径场景）。
                try? fm.createDirectory(atPath: link, withIntermediateDirectories: true)
                for (label, path) in sources {
                    let sub = (link as NSString).appendingPathComponent(label)
                    try? AgentRegistry.linkAgent(link: sub, target: path)
                }
            } else {
                // 没有任何源存在：仍建立空挂载点，保证切换菜单项可用
                try? fm.createDirectory(atPath: link, withIntermediateDirectories: true)
            }
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
    /// 探测 skill 数量：遍历所有 skillPath + extraSkillPaths，去重计数含 SKILL.md 的目录。
    /// 返回 -1 表示所有路径都不存在。
    var skillCount: Int {
        let paths = [skillPath] + extraSkillPaths
        var seen = Set<String>()
        var count = 0
        var anyExists = false
        for raw in paths {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            anyExists = true
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for name in entries where !name.hasPrefix(".") {
                var subIsDir: ObjCBool = false
                let sub = (path as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: sub, isDirectory: &subIsDir),
                   subIsDir.boolValue {
                    let skillMD = (sub as NSString).appendingPathComponent("SKILL.md")
                    if FileManager.default.fileExists(atPath: skillMD),
                       seen.insert(name).inserted {
                        count += 1
                    }
                }
            }
        }
        return anyExists ? count : -1
    }
}