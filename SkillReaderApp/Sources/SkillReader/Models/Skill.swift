import Foundation

// MARK: - 技能库根目录

struct RootInfo: Identifiable, Equatable {
    let id: String
    let path: String
    let label: String?        // 来自 AgentRegistry 的显示名（如 "OpenClaw"）
    let isLibrary: Bool       // 是否为 ~/.agent/library 中心库（不显示在 root 切换菜单）
    var name: String {
        if let label, !label.isEmpty { return label }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

// MARK: - 技能包

enum SkillKind: String {
    case package      // 目录包（含 SKILL.md）
    case standalone   // 独立 .md 文件
}

struct SkillStats: Equatable {
    var md = 0
    var py = 0
    var files = 0
}

struct Skill: Identifiable, Equatable {
    let name: String
    let path: String
    let kind: SkillKind
    let entry: String?
    let description: String
    let stats: SkillStats
    let modified: Int
    var id: String { path }
}

// MARK: - 搜索

struct SearchResult: Identifiable, Equatable {
    let name: String
    let path: String
    let whereHit: String      // "名称/描述" 或 "SKILL.md"
    let snippet: String
    var id: String { path + "|" + whereHit + "|" + snippet.prefix(40) }
}
