import Foundation

// MARK: - Skill 互通分发引擎

/// skill 互通核心：以 `~/.agent/library` 为唯一真相源（中心库），
/// 把库内 skill 以 **符号链接** 分发到启用平台的 skills 目录。
/// 链接即同源：改中心库 = 所有平台立即生效，无需"同步"数据本身。
///
/// 配置 `~/.agent/distribute.json`：
///   { "skills": { "<skill目录名>": ["claude-code", "openclaw", ...] } }
///
/// 安全约定：分发器只清理「自己建的、指向中心库」的 symlink，
/// 绝不动平台目录里用户自行安装的 skill（普通目录/其他来源链接）。
@MainActor
final class SkillDistributor {
    static let shared = SkillDistributor()

    let libraryDir: String       // 中心库：skill 真实存放处
    let configPath: String       // 分发配置

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        libraryDir = (home as NSString).appendingPathComponent(".agent/library")
        configPath = (home as NSString).appendingPathComponent(".agent/distribute.json")
    }

    // MARK: 配置

    /// 确保中心库目录存在（阅读器 root 挂载点 + 分发源）。
    @discardableResult
    func ensureLibrary() -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    struct Config: Codable {
        var skills: [String: [String]] = [:]   // skill 目录名 -> 平台 id 列表
    }

    func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    func saveConfig(_ config: Config) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// 某 skill 已启用的平台 id 列表
    func enabledPlatforms(for skillName: String) -> [String] {
        loadConfig().skills[skillName] ?? []
    }

    // MARK: 分发同步

    /// 全量重建：对每个已纳入管理的 Agent 平台目录，
    /// 先清掉「我们管理的、指向中心库的」symlink，再按配置重建。
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
    /// - 清理：各平台目录中指向中心库的旧 symlink（幂等，不碰用户自装的 skill）
    /// - 重建：按配置为每个 skill 建 `平台目录/<skill名>` → `中心库/<skill名>`
    /// 平台目录不存在时直接跳过（未安装该 Agent，不做任何创建）。
    static func sync(library: String, platformDirs: [String: [String]], config: Config) -> Int {
        let fm = FileManager.default

        // 1. 清理旧链接
        for dirs in platformDirs.values {
            for dir in dirs {
                cleanupManagedLinks(in: dir, library: library, fm: fm)
            }
        }

        // 2. 按配置重建
        var count = 0
        for (skillName, platformIDs) in config.skills {
            let source = (library as NSString).appendingPathComponent(skillName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { continue }
            for pid in platformIDs {
                guard let dirs = platformDirs[pid] else { continue }
                for dir in dirs {
                    var targetIsDir: ObjCBool = false
                    // 平台目录不存在 = 未安装，跳过且不创建
                    guard fm.fileExists(atPath: dir, isDirectory: &targetIsDir), targetIsDir.boolValue else { continue }
                    let link = (dir as NSString).appendingPathComponent(skillName)
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
    @discardableResult
    func importToLibrary(from sourceDir: String, skillName: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: libraryDir, withIntermediateDirectories: true)
        let dest = (libraryDir as NSString).appendingPathComponent(skillName)
        if fm.fileExists(atPath: dest) { return dest }   // 已存在，不覆盖
        do {
            try fm.copyItem(atPath: sourceDir, toPath: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 移除某 skill 的分发配置（全部平台），并清理已建链接。
    func removeDistribution(for skillName: String) {
        var config = loadConfig()
        config.skills[skillName] = nil
        saveConfig(config)
        _ = syncAll()
    }

    // MARK: 私有

    /// 只清理「符号链接且目标在中心库内」的项——用户自装的普通目录/其它链接不受影响。
    private static func cleanupManagedLinks(in dir: String, library: String, fm: FileManager) {
        let libReal = ((library as NSString).expandingTildeInPath as NSString).standardizingPath
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in entries {
            let link = (dir as NSString).appendingPathComponent(name)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
            let destReal = ((dest as NSString).expandingTildeInPath as NSString).standardizingPath
            if destReal == libReal || destReal.hasPrefix(libReal + "/") {
                try? fm.removeItem(atPath: link)
            }
        }
    }
}
