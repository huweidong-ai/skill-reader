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
    var vendorUrl: String? = nil   // 厂商官网（候选行「去官网」按钮用，缺失则不显示）
    var installProbes: [String] = []  // 强安装探测：任一路径存在即视为真已安装（配置/数据目录或 .app 包）

    init(id: String, name: String, vendor: String, iconName: String, logo: String? = nil,
         vendorUrl: String? = nil, installProbes: [String] = [], execPath: String = "", skillPath: String, extraSkillPaths: [String] = [],
         enabled: Bool = false, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.iconName = iconName
        self.logo = logo
        self.vendorUrl = vendorUrl
        self.installProbes = installProbes
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
        case id, name, vendor, iconName, logo, vendorUrl, installProbes, execPath, skillPath, extraSkillPaths, enabled, isCustom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vendor = try c.decode(String.self, forKey: .vendor)
        iconName = try c.decode(String.self, forKey: .iconName)
        logo = try c.decodeIfPresent(String.self, forKey: .logo) ?? nil
        vendorUrl = try c.decodeIfPresent(String.self, forKey: .vendorUrl) ?? nil
        installProbes = try c.decodeIfPresent([String].self, forKey: .installProbes) ?? []
        execPath = try c.decodeIfPresent(String.self, forKey: .execPath) ?? ""
        skillPath = try c.decode(String.self, forKey: .skillPath)
        extraSkillPaths = try c.decodeIfPresent([String].self, forKey: .extraSkillPaths) ?? []
        enabled = try c.decode(Bool.self, forKey: .enabled)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        // 解码后即时重新探测真实存在性
        detected = AgentProfile.detect(paths: [skillPath] + extraSkillPaths)
    }

    /// 强安装探测：任一 installProbe 命中即视为真正安装。
    /// - 普通路径：文件/目录存在（目录或 .app 包）。
    /// - `cmd:<name>`：该命令在 PATH 中可用——**仅做文件存在检查**（遍历 $PATH 目录找可执行文件），
    ///   严禁在渲染期 spawn 子进程（which/Process），否则 AttributeGraph 布局期阻塞会直接崩溃。
    /// 比「仅 skills 子目录存在」更可靠，可区分真安装 / 残留空文件夹 / 手建目录。
    /// 纯文件 IO，无进程 spawn，SwiftUI body 渲染期调用安全。
    var isInstalled: Bool {
        let fm = FileManager.default
        return installProbes.contains { raw in
            if raw.hasPrefix("cmd:") {
                return Self.commandExists(String(raw.dropFirst(4)))
            }
            return fm.fileExists(atPath: (raw as NSString).expandingTildeInPath)
        }
    }

    /// 纯文件检查：遍历 PATH 环境变量里的目录，看 <name> 是否作为可执行文件存在。
    /// 不 spawn 任何进程，渲染期安全。
    private static func commandExists(_ name: String) -> Bool {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return false }
        let fm = FileManager.default
        for dir in pathEnv.split(separator: ":") {
            let candidate = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                if fm.isExecutableFile(atPath: candidate) { return true }
            }
        }
        return false
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

    // MARK: 内置候选（国际在前：Codex / Claude Code / OpenClaw / OpenCode / Hermes /
    //       Gemini CLI / Grok Build，国产在后：WorkBuddy / Trae / Qoder / CodeBuddy / Kimi …）
    // 官方 logo 放 Resources/logos/（来源：GitHub org avatar / 官网 favicon），
    // 无 logo 的用 SF Symbol 兜底。

    static func candidates() -> [AgentProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = { (sub: String) -> String in (home as NSString).appendingPathComponent(sub) }
        return [
            // ── 国际 ──
            AgentProfile(id: "codex", name: "Codex CLI", vendor: "OpenAI", iconName: "terminal",
                         logo: "codex", vendorUrl: "https://chatgpt.com/codex",
                         installProbes: [p(".codex")], skillPath: p(".codex/skills")),
            AgentProfile(id: "claude-code", name: "Claude Code", vendor: "Anthropic", iconName: "brain",
                         logo: "claude-code", vendorUrl: "https://claude.com/product/claude-code",
                         installProbes: [p(".claude.json"), p(".claude")], skillPath: p(".claude/skills")),
            // OpenClaw 真实 skill 在 workspace/skills，~/.openclaw/skills 多数为空
            // 也共用 ~/.agents/skills（与 Claude Code 共享）
            AgentProfile(id: "openclaw", name: "OpenClaw", vendor: "开源", iconName: "shippingbox",
                         logo: "openclaw", vendorUrl: "https://openclaw.ai",
                         installProbes: [p(".openclaw")], skillPath: p(".openclaw/skills"),
                         extraSkillPaths: [p(".openclaw/workspace/skills"), p(".agents/skills")]),
            AgentProfile(id: "opencode", name: "OpenCode", vendor: "Anomaly", iconName: "curlybraces",
                         logo: "opencode", vendorUrl: "https://opencode.ai",
                         installProbes: [p(".config/opencode")], skillPath: p(".config/opencode/skills")),
            AgentProfile(id: "hermes", name: "Hermes Agent", vendor: "Nous Research", iconName: "wind",
                         logo: "hermes", vendorUrl: "https://hermes-agent.nousresearch.com/docs",
                         installProbes: [p(".hermes")], skillPath: p(".hermes/skills")),
            AgentProfile(id: "gemini-cli", name: "Gemini CLI", vendor: "Google", iconName: "sparkle",
                         logo: "gemini-cli", vendorUrl: "https://github.com/google-gemini/gemini-cli",
                         installProbes: [p(".gemini")], skillPath: p(".gemini/skills")),
            AgentProfile(id: "grok", name: "Grok Build", vendor: "xAI", iconName: "bolt.fill",
                         logo: "grok", vendorUrl: "https://grok.com",
                         installProbes: ["cmd:grok", p(".grok/auth.json")], skillPath: p(".agents/skills")),
            // ── 国产（GUI 类除配置目录外，同时探测 .app 包）──
            AgentProfile(id: "workbuddy", name: "WorkBuddy", vendor: "腾讯", iconName: "bubble.left.and.text.bubble.right",
                         logo: "workbuddy", vendorUrl: "https://www.workbuddy.cn",
                         installProbes: [p(".workbuddy"), "/Applications/WorkBuddy.app", p("Applications/WorkBuddy.app")],
                         skillPath: p(".workbuddy/skills")),
            AgentProfile(id: "trae", name: "Trae", vendor: "字节", iconName: "globe",
                         logo: "trae", vendorUrl: "https://www.trae.com",
                         installProbes: [p(".trae"), "/Applications/Trae.app", p("Applications/Trae.app")],
                         skillPath: p(".trae/skills")),
            AgentProfile(id: "qoderwork", name: "QoderWork", vendor: "阿里", iconName: "qrcode.viewfinder",
                         logo: "qoderwork", vendorUrl: "https://qoder.com",
                         installProbes: [p(".qoderwork"), "/Applications/QoderWork.app", p("Applications/QoderWork.app")],
                         skillPath: p(".qoderwork/skills")),
            AgentProfile(id: "codebuddy", name: "CodeBuddy", vendor: "腾讯", iconName: "hammer",
                         logo: "codebuddy", vendorUrl: "https://www.codebuddy.cn",
                         installProbes: [p(".codebuddy"), "/Applications/CodeBuddy.app", p("Applications/CodeBuddy.app")],
                         skillPath: p(".codebuddy/skills")),
            AgentProfile(id: "kimi-code", name: "Kimi Code", vendor: "月之暗面", iconName: "moon.stars",
                         logo: "kimi", vendorUrl: "https://kimi.moonshot.cn",
                         installProbes: [p(".kimi-code"), p(".kimi-code/bin/kimi")], skillPath: p(".kimi-code/skills"),
                         extraSkillPaths: [p(".agents/skills")]),
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
        // 旧配置（升级前写入）可能缺少 installProbes 字段，加载后用内置种子补齐，
        // 避免「已安装」强探测失效、所有内置 Agent 全掉进候选区。
        // 仅对内置 Agent 按 id 补 installProbes；自定义 Agent 保持原样。
        let seedProbes = Dictionary(uniqueKeysWithValues: AgentRegistry.candidates().map { ($0.id, $0.installProbes) })
        return arr.map { agent in
            guard !agent.isCustom, let probes = seedProbes[agent.id], !probes.isEmpty else { return agent }
            var a = agent
            if a.installProbes.isEmpty { a.installProbes = probes }
            return a
        }
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
            }
            // sources.count == 0：本机未安装该 Agent（核心 + 额外路径都不存在），
            // 不建立空挂载点，避免 ~/.agent/skills 出现指向空目录的死链。
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