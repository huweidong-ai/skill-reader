import Foundation

// MARK: - Skill 根目录递归发现

/// 递归发现某个目录下的所有「skill 根目录」：
/// - 直接子目录中包含 SKILL.md 的目录（即 skill 包）时，该目录视为 skill 根；
/// - 同层级同时存在 references 目录与 skill 包时，整个目录也视为 skill 根；
/// - 发现 skill 根后不再继续下钻，避免把 skill 包内部的子目录误判为新根。
struct SkillPathDiscovery {

    /// 默认最大递归深度。OpenClaw workspace 常见结构 ~/.openclaw/workspace/<agent>/skills
    /// 深度约为 4（openclaw → workspace → <agent> → skills）。
    static let defaultMaxDepth = 5

    /// 判断一个目录是否直接包含 skill 包（子目录含 SKILL.md）或 references 目录。
    private static func isSkillRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }

        let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        var hasSkillPackage = false

        for name in entries where !name.hasPrefix(".") {
            let sub = (path as NSString).appendingPathComponent(name)
            var subIsDir: ObjCBool = false
            guard fm.fileExists(atPath: sub, isDirectory: &subIsDir), subIsDir.boolValue else { continue }

            let skillMD = (sub as NSString).appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillMD) {
                hasSkillPackage = true
                break
            }
        }

        // 直接包含 skill 包即视为根；同层的 references 目录会随根一起被挂载，自然可见。
        return hasSkillPackage
    }

    /// 递归发现 `base` 下的所有 skill 根目录，返回绝对路径（已展开 ~，按发现顺序）。
    /// - Parameters:
    ///   - base: 起始目录（如 ~/.openclaw）
    ///   - maxDepth: 最大递归深度
    static func discoverRoots(under base: String, maxDepth: Int = defaultMaxDepth) -> [String] {
        let fm = FileManager.default
        let expanded = (base as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { return [] }

        // BFS 按层级遍历，保证先发现浅层根；遇到 skill 根即停止下钻。
        var queue: [(path: String, depth: Int)] = [(expanded, 0)]
        var roots: [String] = []
        var seen = Set<String>()

        while !queue.isEmpty {
            let (path, depth) = queue.removeFirst()
            let real = (path as NSString).standardizingPath
            guard seen.insert(real).inserted else { continue }

            if depth > maxDepth { continue }

            if isSkillRoot(path) {
                roots.append(path)
                continue
            }

            guard depth < maxDepth else { continue }
            let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            for name in entries where !name.hasPrefix(".") {
                let sub = (path as NSString).appendingPathComponent(name)
                var subIsDir: ObjCBool = false
                guard fm.fileExists(atPath: sub, isDirectory: &subIsDir), subIsDir.boolValue else { continue }
                queue.append((sub, depth + 1))
            }
        }

        return roots
    }

    /// 为某个 Agent 生成「主路径 + 额外路径」：
    /// - 若 `base` 本身是 skill 根，则主路径为 base，额外路径为其下其它根；
    /// - 否则主路径取离 base 最近的根，其余为额外路径。
    /// 返回的 path 使用原始传入形式（保留 ~），便于持久化与展示。
    static func resolveAgentPaths(base: String, persistedExtras: [String] = []) -> (skillPath: String, extras: [String]) {
        let roots = discoverRoots(under: base)
        guard !roots.isEmpty else {
            // 未发现任何 skill 根时，仍以 base 为主路径，让用户可后续手动调整。
            return (base, persistedExtras)
        }

        let expandedBase = (base as NSString).expandingTildeInPath

        // 按与 base 的相对深度排序，选最近的那个作为主路径。
        let sorted = roots.sorted {
            let depthA = relativeDepth(root: $0, base: expandedBase)
            let depthB = relativeDepth(root: $1, base: expandedBase)
            if depthA != depthB { return depthA < depthB }
            return $0 < $1
        }

        var main = sorted[0]
        var extras = Array(sorted.dropFirst())

        // 合并持久化的额外路径（去重）。
        for raw in persistedExtras {
            let p = (raw as NSString).expandingTildeInPath
            let real = (p as NSString).standardizingPath
            let already = (([main] + extras).map { ($0 as NSString).standardizingPath }).contains(real)
            if !already {
                extras.append(p)
            }
        }

        // 把路径还原为带 ~ 的简短形式（若在原 base 下）。
        main = compactPath(main, base: base)
        extras = extras.map { compactPath($0, base: base) }

        return (main, extras)
    }

    /// 计算 root 相对 base 的目录深度；root 不在 base 下时返回一个较大值，使其排在后面。
    private static func relativeDepth(root: String, base: String) -> Int {
        let r = (root as NSString).standardizingPath
        let b = (base as NSString).standardizingPath
        guard r.hasPrefix(b + "/") || r == b else { return Int.max }
        let rel = (r as NSString).substring(from: b.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return rel.isEmpty ? 0 : rel.components(separatedBy: "/").count
    }

    /// 若路径在 base 下，用 ~ 或相对路径缩短；否则返回绝对路径。
    private static func compactPath(_ path: String, base: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedBase = (base as NSString).expandingTildeInPath
        let realPath = (path as NSString).standardizingPath
        let realBase = (expandedBase as NSString).standardizingPath

        if realPath.hasPrefix(realBase + "/") {
            let rel = (realPath as NSString).substring(from: realBase.count + 1)
            if expandedBase.hasPrefix(home + "/") {
                let homeRel = (expandedBase as NSString).substring(from: home.count + 1)
                return "~\(homeRel)/\(rel)"
            }
            return "\(expandedBase)/\(rel)"
        }

        // 尝试还原为 ~/xxx 形式
        if realPath.hasPrefix(home + "/") {
            return "~\((realPath as NSString).substring(from: home.count))"
        }
        return realPath
    }
}
