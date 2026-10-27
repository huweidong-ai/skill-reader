import Foundation

// MARK: - Skill 互通分发引擎（B 模式：单一真相源）

/// skill 互通核心：以 `~/.agent/library` 为唯一真相源（中心库），
/// 把库内 skill 以 **符号链接** 分发到启用平台的 skills 目录。
/// 链接即同源：改中心库 = 所有平台立即生效，无需"同步"数据本身。
///
/// ## B 模式（单一真相源）
/// - 纳入某 Agent 时（`adoptAgentToLibrary`），把它所有真实 skill **导入中心库**，
///   并把该 Agent 目录里的真实文件夹 **替换为指向中心库的 symlink**。
///   于是来源 Agent 自己、以及分发到的其它 Agent，全部指向同一份文件。改一处全局生效。
/// - 中心库条目命名 `<ownerAgentId>__<skillName>`（如 `claude-code__ego-browser`），
///   跨 Agent 同名 skill 互不覆盖，各自独立分发。
/// - 原真实目录移动到 `~/.agent/backups/<agentId>/` 可恢复，**绝不删除**。
///
/// ## 分发配置 `~/.agent/distribute.json`
///   { "skills": { "<owner>__<skillName>": ["openclaw", "workbuddy", ...] } }
///   key = 中心库 canonical 名；value = 除 owner 外的目标平台 id 列表。
///
/// ## 安全约定
/// - 分发器只清理「自己建的、指向中心库」的 symlink。
/// - 但 **owner 自己的采纳链接**（指向 `library/<owner>__…`）永远保留，不被清理——
///   否则重新 sync 会丢来源 Agent 的 skills。
/// - 绝不动平台目录里用户自行安装的、不指向中心库的普通目录/其它链接。
@MainActor
final class SkillDistributor {
    static let shared = SkillDistributor()

    let libraryDir: String       // 中心库：skill 真实存放处（唯一真相源）
    let configPath: String       // 分发配置
    let backupDir: String        // 采纳前原真实目录备份（可恢复）

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        libraryDir = (home as NSString).appendingPathComponent(".agent/library")
        backupDir = (home as NSString).appendingPathComponent(".agent/backups")
        configPath = (home as NSString).appendingPathComponent(".agent/distribute.json")
    }

    // MARK: 命名工具

    /// 中心库条目名：`<ownerAgentId>__<skillName>`
    static func canonical(owner: String, skill: String) -> String {
        return "\(owner)__\(skill)"
    }

    /// 从 canonical 还原「分发给目标 Agent 时使用的干净链接名」（即真实 skill 目录名）
    static func linkBasename(for canonicalName: String) -> String {
        if let r = canonicalName.range(of: "__") {
            return String(canonicalName[r.upperBound...])
        }
        return canonicalName
    }

    // MARK: 配置

    /// 确保中心库 + 备份目录存在
    @discardableResult
    func ensureLibrary() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    struct Config: Codable {
        var skills: [String: [String]] = [:]   // canonical -> 目标平台 id 列表（不含 owner）
    }

    func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func saveConfig(_ config: Config) {
        // 改动前自动快照旧配置（可回滚）
        Self.snapshotConfig(configPath: configPath, backupDir: backupDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// 某 canonical skill 已启用的目标平台 id 列表（不含 owner）
    func enabledPlatforms(for canonical: String) -> [String] {
        loadConfig().skills[canonical] ?? []
    }

    // MARK: 分发同步

    /// 全量重建：对每个已纳入管理的 Agent 平台目录，
    /// 先清掉「我们管理的、指向中心库的」分发链接（保留 owner 自己的采纳链接），再按配置重建。
    /// 返回本次建立的链接数。
    /// 分发目标 = Agent.distributionPaths（实际存在才分发；不存在 = 未安装，跳过且不创建目录）。
    @discardableResult
    func syncAll() -> Int {
        let platforms = AgentRegistry.shared.agents.filter { $0.enabled }
        let platformDirs = Dictionary(uniqueKeysWithValues: platforms.map {
            ($0.id, $0.distributionPaths)
        })
        return Self.sync(library: libraryDir, platformDirs: platformDirs, config: loadConfig())
    }

    /// 核心同步逻辑（纯文件 IO，可注入路径便于测试）。
    /// - 清理：各平台目录中指向中心库的旧 symlink（幂等，不碰用户自装的 skill）；
    ///         但 **owner 自己的采纳链接**（`library/<owner>__…`）不清理，避免丢来源。
    /// - 重建：按配置为每个 canonical 建 `平台目录/<干净skill名>` → `中心库/<canonical>`
    /// 平台目录不存在时直接跳过（未安装该 Agent，不做任何创建）。
    static func sync(library: String, platformDirs: [String: [String]], config: Config) -> Int {
        let fm = FileManager.default

        // 1. 清理旧链接（按 owner 区分采纳链接与分发链接）
        for (pid, dirs) in platformDirs {
            for dir in dirs {
                cleanupManagedLinks(in: dir, library: library, ownerId: pid, fm: fm)
            }
        }

        // 2. 按配置重建
        var count = 0
        for (canonical, platformIDs) in config.skills {
            let source = (library as NSString).appendingPathComponent(canonical)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { continue }
            let linkName = Self.linkBasename(for: canonical)
            for pid in platformIDs {
                guard let dirs = platformDirs[pid] else { continue }
                for dir in dirs {
                    var targetIsDir: ObjCBool = false
                    // 平台目录不存在 = 未安装，跳过且不创建
                    guard fm.fileExists(atPath: dir, isDirectory: &targetIsDir), targetIsDir.boolValue else { continue }
                    let link = (dir as NSString).appendingPathComponent(linkName)
                    try? fm.removeItem(atPath: link)
                    do {
                        try fm.createSymbolicLink(atPath: link, withDestinationPath: source)
                        count += 1
                    } catch { /* 平台目录不可写等，跳过 */ }
                }
            }
        }
        return count
    }

    /// 把指定 skill 复制进中心库（若已存在则跳过），返回中心库中的目录路径。
    /// `skillName` 调用方应传入 canonical（`<owner>__<skill>`）。
    @discardableResult
    func importToLibrary(from sourceDir: String, skillName: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
        let dest = (libraryDir as NSString).appendingPathComponent(skillName)
        if fm.fileExists(atPath: dest) { return dest }   // 已存在，不覆盖（去重）
        do {
            try fm.copyItem(atPath: sourceDir, toPath: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 移除某 skill 的分发配置（全部平台），并清理已建链接。
    func removeDistribution(for canonical: String) {
        var config = loadConfig()
        config.skills[canonical] = nil
        saveConfig(config)
        _ = syncAll()
    }

    // MARK: - 采纳（纳入即共享，单一真相源）

    /// 把某 Agent 的真实 skills 全部导入中心库，并把该 Agent 目录中的真实文件夹
    /// 替换为指向中心库的 symlink。所有人（含来源 Agent）指向同一份。
    /// - 仅处理真实目录；已是 symlink（已采纳/已分发）的跳过，幂等。
    /// - 原始真实目录移动到 `backupDir/<agentId>/` 可恢复，不删除。
    func adoptAgentToLibrary(_ agent: AgentProfile) -> (imported: Int, linked: Int) {
        return Self.adopt(agentId: agent.id,
                          skillDirs: agent.allSkillPaths,
                          library: libraryDir,
                          backupRoot: backupDir)
    }

    /// 纯文件 IO 版，可注入路径便于测试。
    static func adopt(agentId: String, skillDirs: [String], library: String, backupRoot: String)
        -> (imported: Int, linked: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: library, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: backupRoot, withIntermediateDirectories: true)
        var imported = 0, linked = 0
        for dir in skillDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where !name.hasPrefix(".") {
                let real = (dir as NSString).appendingPathComponent(name)
                var subIsDir: ObjCBool = false
                guard fm.fileExists(atPath: real, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
                // 已是 symlink（已采纳/已分发）→ 跳过，幂等
                if (try? fm.destinationOfSymbolicLink(atPath: real)) != nil { continue }
                let canonical = Self.canonical(owner: agentId, skill: name)
                // 1) 导入中心库（已存在则跳过）
                let dest = (library as NSString).appendingPathComponent(canonical)
                if !fm.fileExists(atPath: dest) {
                    do { try fm.copyItem(atPath: real, toPath: dest); imported += 1 }
                    catch { continue }
                }
                // 2) 备份原真实目录（可恢复，不删除）
                let backup = ((backupRoot as NSString)
                    .appendingPathComponent(agentId) as NSString)
                    .appendingPathComponent(name)
                try? fm.createDirectory(atPath: (backup as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                try? fm.moveItem(atPath: real, toPath: backup)
                // 3) 替换为指向中心库的 symlink
                do {
                    try fm.createSymbolicLink(atPath: real, withDestinationPath: dest)
                    linked += 1
                } catch { /* 极少数情况下无法建链接，保留备份，原目录已被移走，需要手动恢复 */ }
            }
        }
        return (imported, linked)
    }

    // MARK: - 快照与恢复

    /// 把当前 distribute.json 快照到 `backups/config-history/`，只保留最近 20 份。
    /// 纯文件 IO，路径可注入便于自测。
    static func snapshotConfig(configPath: String, backupDir: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configPath) else { return }
        let dir = (backupDir as NSString).appendingPathComponent("config-history")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent("distribute-\(timestamp()).json")
        try? fm.removeItem(atPath: dest)
        try? fm.copyItem(atPath: configPath, toPath: dest)
        // 只保留最近 20 份（文件名含时间戳，字典序即时间序）
        let files = configSnapshots(backupDir: backupDir)
        if files.count > 20 {
            for f in files.dropFirst(20) { try? fm.removeItem(atPath: f) }
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }

    /// 配置快照列表（新 → 旧）
    static func configSnapshots(backupDir: String) -> [String] {
        let dir = (backupDir as NSString).appendingPathComponent("config-history")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { $0.hasPrefix("distribute-") && $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    /// 恢复某份配置快照并重新同步分发
    @discardableResult
    func restoreConfigSnapshot(atPath path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return false }
        // 恢复前把当前配置也快照一份，可再撤销恢复
        Self.snapshotConfig(configPath: configPath, backupDir: backupDir)
        do {
            try? fm.removeItem(atPath: configPath)
            try fm.copyItem(atPath: path, toPath: configPath)
        } catch { return false }
        _ = syncAll()
        return true
    }

    /// 中心库全部条目（canonical 名，排序）
    func libraryEntries() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: libraryDir) else { return [] }
        return entries.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 某采纳 skill 的原始备份路径（不存在返回 nil = 不可恢复）
    func backupPath(agentId: String, skillName: String) -> String? {
        let p = ((backupDir as NSString).appendingPathComponent(agentId) as NSString)
            .appendingPathComponent(skillName)
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) ? p : nil
    }

    /// 撤销采纳：移除采纳链接 → 恢复原始目录 → 清除分发配置 → 重新同步。
    @discardableResult
    func unadopt(agentId: String, skillName: String, skillDirs: [String]) -> Bool {
        Self.unadopt(agentId: agentId, skillName: skillName, skillDirs: skillDirs,
                     library: libraryDir, backupRoot: backupDir, configPath: configPath,
                     sync: { [weak self] in self?.syncAll() ?? 0 })
    }

    /// 撤销采纳核心（路径可注入便于自测）。
    /// 流程：确认采纳链接存在且指向库内条目 → 确认原始备份存在（否则拒绝，避免丢数据）→
    /// 清除分发配置 → 删链接 → 备份目录 move 回原位 → 删除中心库条目 → 重新同步。
    static func unadopt(agentId: String, skillName: String, skillDirs: [String],
                        library: String, backupRoot: String, configPath: String,
                        sync: (() -> Int)? = nil) -> Bool {
        let fm = FileManager.default
        let canonical = Self.canonical(owner: agentId, skill: skillName)
        let libCanonical = (library as NSString).appendingPathComponent(canonical)
        for dir in skillDirs {
            let link = (dir as NSString).appendingPathComponent(skillName)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
            let destStd = ((dest as NSString).expandingTildeInPath as NSString).standardizingPath
            let libStd = (libCanonical as NSString).standardizingPath
            guard destStd == libStd else { continue }
            // 1) 原始备份必须存在，否则不动（绝不丢数据）
            let backup = ((backupRoot as NSString).appendingPathComponent(agentId) as NSString)
                .appendingPathComponent(skillName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: backup, isDirectory: &isDir), isDir.boolValue else { return false }
            // 2) 清除分发配置
            if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
               var cfg = try? JSONDecoder().decode(Config.self, from: data) {
                cfg.skills[canonical] = nil
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let out = try? enc.encode(cfg) {
                    try? out.write(to: URL(fileURLWithPath: configPath))
                }
            }
            // 3) 移除采纳链接并恢复原始目录；恢复失败则重建链接避免条目悬空
            try? fm.removeItem(atPath: link)
            do {
                try fm.moveItem(atPath: backup, toPath: link)
            } catch {
                try? fm.createSymbolicLink(atPath: link, withDestinationPath: dest)
                return false
            }
            // 4) 移除中心库条目（canonical 由 owner 唯一确定，不会误删其它 Agent 的同名 skill）
            try? fm.removeItem(atPath: libCanonical)
            _ = sync?()
            return true
        }
        return false
    }

    // MARK: 私有

    /// 只清理「符号链接且目标在中心库内」的项——用户自装的普通目录/其它链接不受影响。
    /// 但 owner 自己的采纳链接（指向 `library/<owner>__…`）**保留**，不清理。
    private static func cleanupManagedLinks(in dir: String, library: String, ownerId: String, fm: FileManager) {
        let libReal = ((library as NSString).expandingTildeInPath as NSString).standardizingPath
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in entries {
            let link = (dir as NSString).appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
            let destReal = ((dest as NSString).expandingTildeInPath as NSString).standardizingPath
            guard destReal == libReal || destReal.hasPrefix(libReal + "/") else { continue }
            // owner 自己的采纳链接：指向 library/<owner>__…，保留
            let canonical = (destReal as NSString).lastPathComponent
            let owner = canonical.components(separatedBy: "__").first ?? ""
            if owner == ownerId { continue }
            try? fm.removeItem(atPath: link)
        }
    }
}
