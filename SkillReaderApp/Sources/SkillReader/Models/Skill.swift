import Foundation

// MARK: - 技能库根目录

struct RootInfo: Identifiable, Equatable {
    let id: String
    let path: String
    var name: String { (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent }
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
