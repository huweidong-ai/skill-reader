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

    /// 互通分发的目标目录（实际存在才分发；不存在 = 未安装该 Agent，跳过）。
    /// - 常规 Agent：skillPath（如 ~/.claude/skills）
    /// - OpenClaw：真实 skill 存放/读取于 extraSkillPaths（~/.openclaw/workspace/skills），
    ///   其 skillPath（~/.openclaw/skills）默认不被读取，故分发走 extra 路径。
    var distributionPaths: [String] {
        let fm = FileManager.default
        let candidates = id == "openclaw" ? extraSkillPaths : [skillPath] + extraSkillPaths
        var seen = Set<String>()
        var result: [String] = []
        for raw in candidates {
            let path = (raw as NSString).expandingTildeInPath
            let real = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(real).inserted else { continue }
            result.append(path)
        }
        return result
    }

    /// 用于递归探测 skill 根的「基目录」：优先取首个已存在且为目录的安装探针
    /// （排除 `.app` 包与 `cmd:` 命令探针），兜底取首个非 .app、非 cmd: 探针。
    /// - 例：Trae 的探针为 `[~/.trae, /Applications/Trae.app]` → 基目录取 `~/.trae`，
    ///   递归发现 `builtin_skills/`、`builtin/` 下的 skill 根。
    var skillBaseDir: String? {
        let fm = FileManager.default
        // 优先：已存在且为目录的探针
        for raw in installProbes where !raw.hasPrefix("cmd:") && !raw.hasSuffix(".app") {
            let expanded = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return raw
            }
        }
        // 兜底：首个非 .app、非 cmd: 探针
        for raw in installProbes where !raw.hasPrefix("cmd:") && !raw.hasSuffix(".app") {
            return raw
        }
        return nil
    }

    /// 主动递归探测：以基目录递归发现所有 skill 根，更新主路径与额外路径。
    /// 用于「重新检测」按钮与纳入管理时的自动校正（如 Trae 的 skills 分散在
    /// `builtin_skills/`、`builtin/`，单条硬编码 `skills` 路径兜不住）。
    /// - OpenClaw 走专门的 `discoveredOpenClawPaths()`，保持 `~/.agents/skills` 等合并逻辑。
    @MainActor
    mutating func redetectSkillPaths() {
        if id == "openclaw" {
            let discovered = AgentRegistry.discoveredOpenClawPaths()
            if let first = discovered.first {
                skillPath = first
                extraSkillPaths = Array(discovered.dropFirst())
            }
            return
        }
        guard let base = skillBaseDir else { return }
        let (sp, extras) = SkillPathDiscovery.resolveAgentPaths(base: base, persistedExtras: extraSkillPaths)
        skillPath = sp
        extraSkillPaths = extras
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
            // OpenClaw 真实 skill 分散在 ~/.openclaw 下多处（skills、workspace/skills、
            // workspace/<agent>/skills）。启动时递归发现；也包含与 Claude Code 共用的 ~/.agents/skills。
            AgentProfile(id: "openclaw", name: "OpenClaw", vendor: "开源", iconName: "shippingbox",
                         logo: "openclaw", vendorUrl: "https://openclaw.ai",
                         installProbes: [p(".openclaw")], skillPath: p(".openclaw/skills"),
                         extraSkillPaths: AgentRegistry.discoveredOpenClawPaths()),
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
            // 加载后即时持久化并重建挂载点：这样 OpenClaw 动态发现的新 workspace/<agent>/skills
            // 会立刻反映到 ~/.agent/skills，且 symlink 标签随代码升级而更新。
            save(loaded)
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
            guard !agent.isCustom else { return agent }
            var a = agent
            if a.id == "openclaw" {
                a = AgentRegistry.mergeOpenClawPaths(a)
            }
            if let probes = seedProbes[agent.id], !probes.isEmpty, a.installProbes.isEmpty {
                a.installProbes = probes
            }
            return a
        }
    }

    /// OpenClaw 动态路径发现：扫描 ~/.openclaw 下所有 skill 根目录，并始终包含 ~/.agents/skills。
    static func discoveredOpenClawPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = (home as NSString).appendingPathComponent(".openclaw")
        let primary = (home as NSString).appendingPathComponent(".openclaw/skills")
        let shared = (home as NSString).appendingPathComponent(".agents/skills")

        let roots = SkillPathDiscovery.discoverRoots(under: base)
        var extras = roots.filter { ($0 as NSString).standardizingPath != (primary as NSString).standardizingPath }

        var seen = Set(extras.map { ($0 as NSString).standardizingPath })
        seen.insert((primary as NSString).standardizingPath)

        if FileManager.default.fileExists(atPath: shared) {
            let real = (shared as NSString).standardizingPath
            if seen.insert(real).inserted {
                extras.append(shared)
            }
        }

        return extras
    }

    /// 将持久化的 OpenClaw 配置与动态发现的路径合并，保留用户手动添加的额外路径。
    static func mergeOpenClawPaths(_ agent: AgentProfile) -> AgentProfile {
        guard agent.id == "openclaw" else { return agent }
        var a = agent
        let discovered = discoveredOpenClawPaths()
        var seen = Set(discovered.map { ($0 as NSString).standardizingPath })
        var merged = discovered
        for raw in agent.extraSkillPaths {
            let real = ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
            if seen.insert(real).inserted {
                merged.append(raw)
            }
        }
        a.extraSkillPaths = merged
        return a
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
            let all = [(agent.skillPath)] + agent.extraSkillPaths
            for raw in all {
                let path = (raw as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let real = (path as NSString).standardizingPath
                guard seen.insert(real).inserted else { continue }
                let label = symlinkLabel(for: path, agent: agent, usedLabels: sources.map { $0.label })
                sources.append((label, real))
            }
            // 单个源：直接单层 symlink（保持原有读取逻辑不变）
            if sources.count == 1 {
                try? AgentRegistry.linkAgent(link: link, target: sources[0].path)
            } else if sources.count > 1 {
                // 多路径：聚合目录 —— 在 <id>/ 下为每个源建立二级 symlink，
                // 使用相对路径作为标签，保留原始目录结构（如 skills / workspace/skills）。
                try? fm.createDirectory(atPath: link, withIntermediateDirectories: true)
                for (label, path) in sources {
                    let sub = (link as NSString).appendingPathComponent(label)
                    let parent = (sub as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: parent) {
                        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    }
                    try? AgentRegistry.linkAgent(link: sub, target: path)
                }
            }
            // sources.count == 0：本机未安装该 Agent（核心 + 额外路径都不存在），
            // 不建立空挂载点，避免 ~/.agent/skills 出现指向空目录的死链。
        }
    }

    /// 为挂载目录生成人类可读的二级目录名：
    /// - 路径在 Agent 基目录（skillPath 父目录）下时，使用相对路径（如 skills、workspace/skills）；
    /// - 路径在基目录外时，使用路径的简短 slug（如 .agents-skills）。
    private func symlinkLabel(for path: String, agent: AgentProfile, usedLabels: [String]) -> String {
        let fm = FileManager.default
        let expandedSkill = (agent.skillPath as NSString).expandingTildeInPath
        let base = (expandedSkill as NSString).deletingLastPathComponent
        let realPath = (path as NSString).standardizingPath
        let realBase = (base as NSString).standardizingPath

        let label: String
        if realPath.hasPrefix(realBase + "/") {
            let rel = (realPath as NSString).substring(from: realBase.count + 1)
            label = rel
        } else {
            // 路径在基目录外：生成简短 slug。优先用 ~/ 相对路径，去掉开头的 ~ 与尾空，
            // 再把目录分隔符替换成 -，最终形如 "agents-skills"。
            let home = fm.homeDirectoryForCurrentUser.path
            var s = realPath
            if s.hasPrefix(home + "/") {
                s = (s as NSString).substring(from: home.count + 1)
            }
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let safe = s.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." ? Character($0) : "-" }
            label = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        // 保证唯一性
        var candidate = label
        var suffix = 1
        while usedLabels.contains(candidate) {
            suffix += 1
            candidate = "\(label)-\(suffix)"
        }
        return candidate.isEmpty ? "source" : candidate
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
    /// 返回路径在 UI 上的简短标签：
    /// - 在 skillPath 基目录（父目录）下时显示相对路径（如 skills、workspace/skills）；
    /// - 在基目录外时显示 ~/... 缩写；
    /// - 都失败则返回绝对路径。
    func displayLabel(for path: String) -> String {
        let fm = FileManager.default
        let expandedSkill = (skillPath as NSString).expandingTildeInPath
        let base = (expandedSkill as NSString).deletingLastPathComponent
        let expandedPath = (path as NSString).expandingTildeInPath
        let realBase = (base as NSString).standardizingPath
        let realPath = (expandedPath as NSString).standardizingPath

        if realPath.hasPrefix(realBase + "/") {
            let rel = (realPath as NSString).substring(from: realBase.count + 1)
            return rel
        }
        let home = fm.homeDirectoryForCurrentUser.path
        if realPath.hasPrefix(home + "/") {
            return "~" + (realPath as NSString).substring(from: home.count)
        }
        return realPath
    }

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