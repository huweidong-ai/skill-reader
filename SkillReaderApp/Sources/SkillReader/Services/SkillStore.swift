import AppKit
import Foundation

// MARK: - 核心数据层（对齐 server.py 逻辑）

@MainActor
final class SkillStore: ObservableObject {
    @Published var roots: [RootInfo] = []
    @Published var currentRootID: String?

    private var rootPathByID: [String: String] = [:]
    private static let currentRootPathKey = "skillreader.currentRootPath"
    private let maxTextSize = 2 * 1024 * 1024
    private let snippetRadius = 80
    private let skipDirs: Set<String> = [".git", ".hg", ".svn", "__pycache__", "node_modules",
                                         ".venv", "venv", "env", ".idea", ".vscode", "dist", "build"]
    private let skipFiles: Set<String> = [".DS_Store"]

    // MARK: - 常量表（对齐 web 版）

    private let imgExts: Set<String> = [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".bmp"]
    private let textExts: Set<String> = [".md", ".markdown", ".mdown", ".txt", ".log", ".csv", ".tsv",
                                         ".json", ".yaml", ".yml", ".toml", ".ini", ".conf", ".cfg",
                                         ".env", ".gitignore", ".gitattributes", ".editorconfig"]
    private let codeLang: [String: String] = [
        ".py": "python", ".sh": "bash", ".bash": "bash", ".zsh": "bash",
        ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript",
        ".ts": "typescript", ".tsx": "typescript",
        ".css": "css", ".scss": "scss", ".less": "less",
        ".html": "html", ".htm": "html", ".xml": "xml", ".svg": "xml",
        ".swift": "swift", ".go": "go", ".rs": "rust",
        ".java": "java", ".kt": "kotlin", ".scala": "scala",
        ".c": "c", ".h": "c", ".cpp": "cpp", ".cc": "cpp", ".hpp": "cpp",
        ".m": "objectivec", ".mm": "objectivec",
        ".sql": "sql", ".rb": "ruby", ".php": "php", ".cs": "csharp",
        ".r": "r", ".pl": "perl", ".lua": "lua", ".diff": "diff",
        ".dockerfile": "dockerfile", ".vb": "vbnet",
    ]

    // MARK: - 根目录

    func loadRoots(extra: [String] = []) {
        var roots: [RootInfo] = []
        var seen = Set<String>()

        // 0. ~/.agent 集中管理中心（symlink 挂载）：每个启用的 Agent 一个独立 root
        //    侧栏顶部的「技能库切换」菜单天然变成「Agent 切换」。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentMount = (home as NSString).appendingPathComponent(".agent/skills")
        let labelMap = AgentRegistry.shared.labelMap()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: agentMount) {
            for name in entries.sorted() {
                let full = (agentMount as NSString).appendingPathComponent(name)
                addRoot(&roots, &seen, full, label: labelMap[name], idPrefix: "a")
            }
        }

        // 0b. ~/.agent/library 中心库（skill 互通分发源）：库内 skill 可分发到各平台。
        // 中心库不显示在顶部 root 切换菜单中，避免与 Agent 技能源并列造成混淆。
        let library = (home as NSString).appendingPathComponent(".agent/library")
        addRoot(&roots, &seen, library, label: L10n.t("中心库", "Library"), idPrefix: "l", isLibrary: true)

        // 1. 兜底：尚未配置 ~/.agent 时，沿用原逻辑（保证首次也有数据可读）
        if roots.isEmpty {
            // 1a. 用户级 skills
            let userSkills = (home as NSString).appendingPathComponent(".workbuddy/skills")
            addRoot(&roots, &seen, userSkills)

            // 1b. 工作区 .workbuddy/skills（server.py 同级 .workbuddy/skills）
            let bundle = Bundle.main.bundlePath
            let exe = Bundle.main.executablePath ?? bundle
            let exeDir = (exe as NSString).deletingLastPathComponent
            let wsCandidates = [
                (exeDir as NSString).appendingPathComponent(".workbuddy/skills"),
                (bundle as NSString).appendingPathComponent(".workbuddy/skills"),
            ]
            for ws in wsCandidates where FileManager.default.fileExists(atPath: ws) {
                addRoot(&roots, &seen, ws)
                break
            }

            // 1c. roots.json（与可执行文件同目录, 开发模式退回 bundle 目录）
            var rootsJsonPaths: [String] = []
            if let res = Bundle.main.resourceURL?.appendingPathComponent("roots.json").path {
                rootsJsonPaths.append(res)
            }
            rootsJsonPaths.append((exeDir as NSString).appendingPathComponent("roots.json"))
            for p in rootsJsonPaths where FileManager.default.fileExists(atPath: p) {
                if let lines = try? String(contentsOfFile: p, encoding: .utf8) {
                    for line in lines.split(separator: "\n") {
                        let s = line.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty && !s.hasPrefix("#") {
                            addRoot(&roots, &seen, s)
                        }
                    }
                }
                break
            }
        }

        // 1d. 命令行 --root 追加
        for r in extra where !r.isEmpty {
            addRoot(&roots, &seen, r)
        }

        self.roots = roots

        // 优先恢复上次记住的根目录路径（root ID 每次加载会按顺序重算，不稳定）
        let persistedPath = UserDefaults.standard.string(forKey: Self.currentRootPathKey)
        let target: String?
        if let p = persistedPath,
           let found = roots.first(where: { ($0.path as NSString).standardizingPath == (p as NSString).standardizingPath }) {
            target = found.id
        } else if roots.isEmpty {
            target = nil
        } else {
            target = roots[0].id
        }

        // 中心库作为后台分发源，不显示在顶部 root 切换菜单中，
        // 因此也不应成为默认/记住的当前 root。
        if let target = target,
           let targetRoot = roots.first(where: { $0.id == target }),
           targetRoot.isLibrary,
           let firstVisible = roots.first(where: { !$0.isLibrary }) {
            setCurrentRootID(firstVisible.id)
        } else {
            self.currentRootID = target
        }
    }

    /// UI 切换根目录时调用：既设置 currentRootID，又把对应路径持久化到 UserDefaults
    func setCurrentRootID(_ id: String?) {
        currentRootID = id
        if let id = id, let path = roots.first(where: { $0.id == id })?.path {
            UserDefaults.standard.set(path, forKey: Self.currentRootPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.currentRootPathKey)
        }
    }

    private func addRoot(_ roots: inout [RootInfo], _ seen: inout Set<String>, _ path: String,
                         label: String? = nil, idPrefix: String = "r", isLibrary: Bool = false) {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { return }
        let real = (expanded as NSString).standardizingPath
        guard !seen.contains(real) else { return }
        seen.insert(real)
        let id = "\(idPrefix)\(roots.count)"
        roots.append(RootInfo(id: id, path: real, label: label, isLibrary: isLibrary))
        rootPathByID[id] = real
    }

    var currentRootPath: String? {
        guard let id = currentRootID else { return nil }
        return rootPathByID[id] ?? roots.first(where: { $0.id == id })?.path
    }

    // MARK: - 技能发现

    func listSkills() -> [Skill] {
        guard let root = currentRootPath else { return [] }
        var collected: [Skill] = []
        // 收集 root 下所有 skill；遇到「聚合层」（目录本身不是 skill 包，
        // 用于容纳多路径 symlink，如 OpenClaw 的 core/extra0/extra1）则下钻，
        // 并保留相对 root 的完整路径（如 extra0/mac-camera-capture）。
        collectSkills(in: root, relToRoot: "", into: &collected)
        return dedupeSkills(collected)
    }

    private func collectSkills(in dir: String, relToRoot: String, into collected: inout [Skill]) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir).sorted()) ?? []
        for name in entries {
            if name.hasPrefix(".") || skipDirs.contains(name) { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            let rel = relToRoot.isEmpty ? name : (relToRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if isBareGit(full) { continue }
                // 自身是 skill 包（含 SKILL.md）
                let entryPath = (full as NSString).appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: entryPath) {
                    collected.append(scanPackage(root: dir, name: name, relPath: rel, full: full))
                } else {
                    // 聚合层（如 OpenClaw 多路径挂载）：先判断是不是「无 SKILL.md 的 skill 包」；
                    // 否则下钻一层继续找 skill。
                    if hasDirectSkillFiles(full) {
                        collected.append(scanPackage(root: dir, name: name, relPath: rel, full: full))
                    } else {
                        collectSkills(in: full, relToRoot: rel, into: &collected)
                    }
                }
            } else if name.lowercased().hasSuffix(".md") || name.lowercased().hasSuffix(".markdown") {
                collected.append(scanStandalone(root: dir, name: name, relPath: rel, full: full))
            }
        }
    }

    /// 判断目录是否直接包含 skill 相关文件（.md/.py），用于区分「无 SKILL.md 的 skill 包」与「聚合层目录」。
    private func hasDirectSkillFiles(_ dir: String) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        for name in entries {
            if name.hasPrefix(".") { continue }
            let full = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let lower = name.lowercased()
            if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".py") {
                return true
            }
        }
        return false
    }

    private func dedupeSkills(_ list: [Skill]) -> [Skill] {
        var seen = Set<String>()
        var result: [Skill] = []
        for s in list {
            // 同名 skill 在多路径中可能出现，保留先遇到的
            if seen.contains(s.name) { continue }
            seen.insert(s.name)
            result.append(s)
        }
        return result
    }

    private func isBareGit(_ full: String) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: (full as NSString).appendingPathComponent("SKILL.md")) else { return false }
        return fm.fileExists(atPath: (full as NSString).appendingPathComponent("HEAD"))
            && fm.fileExists(atPath: (full as NSString).appendingPathComponent("config"))
            && fm.fileExists(atPath: (full as NSString).appendingPathComponent("objects"))
    }

    private func scanPackage(root: String, name: String, relPath: String, full: String) -> Skill {
        let entryPath = (full as NSString).appendingPathComponent("SKILL.md")
        var desc = ""
        if FileManager.default.fileExists(atPath: entryPath) {
            if let content = try? String(contentsOfFile: entryPath, encoding: .utf8) {
                let fm = Frontmatter.parse(content)
                if let d = fm.dict["description"] ?? fm.dict["summary"] {
                    desc = d.stringValue
                }
            }
        }
        let stats = statDir(full)
        var mtime = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
           let t = attrs[.modificationDate] as? Date {
            mtime = Int(t.timeIntervalSince1970)
        }
        return Skill(name: name, path: relPath, kind: .package,
                     entry: FileManager.default.fileExists(atPath: entryPath) ? "SKILL.md" : nil,
                     description: desc, stats: stats, modified: mtime)
    }

    private func scanStandalone(root: String, name: String, relPath: String, full: String) -> Skill {
        var desc = ""
        if let content = try? String(contentsOfFile: full, encoding: .utf8) {
            let fm = Frontmatter.parse(content)
            if let d = fm.dict["description"] ?? fm.dict["summary"] {
                desc = d.stringValue
            }
        }
        return Skill(name: name, path: relPath, kind: .standalone, entry: name,
                     description: desc,
                     stats: SkillStats(md: 1, py: 0, files: 1), modified: 0)
    }

    private func statDir(_ d: String) -> SkillStats {
        var stats = SkillStats()
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: d) else { return stats }
        for case let f as String in en {
            if skipFiles.contains(f) || f.hasSuffix(".pyc") { continue }
            stats.files += 1
            let lower = f.lowercased()
            if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { stats.md += 1 }
            if lower.hasSuffix(".py") { stats.py += 1 }
        }
        return stats
    }

    // MARK: - 文件树

    func tree(for skillPath: String) -> FileNode? {
        guard let root = currentRootPath else { return nil }
        let full = (root as NSString).appendingPathComponent(skillPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { return nil }
        let node = buildTree(absDir: full, rootPath: root, relDir: "")
        // 根节点 path 用技能包路径（相对 root）；子节点 path 相对技能包
        node.path = skillPath
        return node
    }

    private func buildTree(absDir: String, rootPath: String, relDir: String) -> FileNode {
        let node = FileNode(name: (absDir as NSString).lastPathComponent,
                            path: relDir, isDir: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: absDir)) ?? []
        let sorted = entries.sorted { a, b in
            let aDir = dirFlag(absDir, a), bDir = dirFlag(absDir, b)
            if aDir != bDir { return aDir }
            return a.lowercased() < b.lowercased()
        }
        for name in sorted {
            if name.hasPrefix(".") && name != ".gitkeep" { continue }
            if skipDirs.contains(name) || skipFiles.contains(name) { continue }
            let full = (absDir as NSString).appendingPathComponent(name)
            let rel = relDir.isEmpty ? name : (relDir as NSString).appendingPathComponent(name)
            if dirFlag(absDir, name) {
                node.children.append(buildTree(absDir: full, rootPath: rootPath, relDir: rel))
            } else {
                let kind = classify(name)
                var size = 0
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let s = attrs[.size] as? Int {
                    size = s
                }
                let child = FileNode(name: name, path: rel, isDir: false, kind: kind,
                                     size: size, sizeHuman: humanSize(size),
                                     lang: codeLang[(name as NSString).pathExtension.lowercased().isEmpty
                                                    ? name : "." + (name as NSString).pathExtension.lowercased()])
                node.children.append(child)
            }
        }
        return node
    }

    /// 由扩展名推断代码高亮语言（供外部文件渲染复用）
    func language(for name: String) -> String? {
        let ext = "." + (name as NSString).pathExtension.lowercased()
        return codeLang[ext]
    }

    private func dirFlag(_ dir: String, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name),
                                       isDirectory: &isDir)
        return isDir.boolValue
    }

    func classify(_ name: String) -> FileKind {
        let ext = "." + (name as NSString).pathExtension.lowercased()
        if imgExts.contains(ext) { return .img }
        if [".md", ".markdown", ".mdown"].contains(ext) { return .md }
        if codeLang[ext] != nil { return .code }
        if ext == ".yaml" || ext == ".yml" { return .yaml }
        if ext == ".json" { return .json }
        if ext == ".toml" { return .toml }
        if ext == ".pdf" { return .pdf }
        if textExts.contains(ext) { return .text }
        return .bin
    }

    // MARK: - 读取文件

    func readFile(skillPath: String, relPath: String) -> FileContent? {
        guard let root = currentRootPath else { return nil }
        // standalone 技能：skillPath 本身即文件，直接读；package 技能：skillPath/relPath
        let skillAbs = (root as NSString).appendingPathComponent(skillPath)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: skillAbs, isDirectory: &isDir)
        let rel = isDir.boolValue
            ? (skillPath as NSString).appendingPathComponent(relPath)
            : skillPath
        let full = safeJoin(root: root, rel: rel)
        guard let full, FileManager.default.fileExists(atPath: full) else { return nil }
        let name = (full as NSString).lastPathComponent
        let kind = classify(name)
        var size = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
           let s = attrs[.size] as? Int {
            size = s
        }
        let sizeH = humanSize(size)
        switch kind {
        case .img, .pdf, .bin:
            return FileContent(name: name, path: relPath, kind: kind, size: size,
                               sizeHuman: sizeH, lang: nil, content: nil, tooLarge: false)
        default:
            if size > maxTextSize {
                return FileContent(name: name, path: relPath, kind: kind, size: size,
                                   sizeHuman: sizeH, lang: codeLang[extOf(name)], content: nil, tooLarge: true)
            }
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else {
                return FileContent(name: name, path: relPath, kind: kind, size: size,
                                   sizeHuman: sizeH, lang: nil, content: nil, tooLarge: false)
            }
            return FileContent(name: name, path: relPath, kind: kind, size: size,
                               sizeHuman: sizeH, lang: codeLang[extOf(name)], content: content, tooLarge: false)
        }
    }

    /// 原始文件绝对路径（图片/PDF/在 Finder 中显示）
    func rawPath(skillPath: String, relPath: String) -> String? {
        guard let root = currentRootPath else { return nil }
        let skillAbs = (root as NSString).appendingPathComponent(skillPath)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: skillAbs, isDirectory: &isDir)
        let rel = isDir.boolValue
            ? (skillPath as NSString).appendingPathComponent(relPath)
            : skillPath
        return safeJoin(root: root, rel: rel)
    }

    private func extOf(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "" : "." + e
    }

    // MARK: - 安全路径

    func safeJoin(root: String, rel: String) -> String? {
        guard !rel.hasPrefix("/") else { return nil }
        let base = (root as NSString).standardizingPath
        let target = ((base as NSString).appendingPathComponent(rel) as NSString).standardizingPath
        guard target == base || target.hasPrefix(base + "/") else { return nil }
        return target
    }

    // MARK: - 搜索

    func search(_ q: String) -> [SearchResult] {
        guard let root = currentRootPath else { return [] }
        let kw = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !kw.isEmpty else { return [] }
        var results: [SearchResult] = []
        let skills = listSkills()
        for skill in skills {
            let haystack = (skill.name + "\n" + skill.description).lowercased()
            if haystack.contains(kw) {
                results.append(SearchResult(name: skill.name, path: skill.path, whereHit: L10n.t("名称/描述", "Name/Desc"), snippet: ""))
                continue
            }
            let target: String
            if skill.kind == .standalone {
                target = (root as NSString).appendingPathComponent(skill.path)
            } else {
                target = ((root as NSString).appendingPathComponent(skill.path) as NSString)
                    .appendingPathComponent(skill.entry ?? "SKILL.md")
            }
            guard FileManager.default.fileExists(atPath: target),
                  let text = try? String(contentsOfFile: target, encoding: .utf8) else { continue }
            let lower = text.lowercased()
            if let idx = lower.range(of: kw) {
                let start = lower.index(lower.startIndex, offsetBy: max(0, lower.distance(from: lower.startIndex, to: idx.lowerBound) - snippetRadius))
                let end = lower.index(lower.startIndex, offsetBy: min(lower.count, lower.distance(from: lower.startIndex, to: idx.lowerBound) + kw.count + snippetRadius))
                let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                results.append(SearchResult(name: skill.name, path: skill.path, whereHit: "SKILL.md", snippet: snippet))
            }
            if results.count >= 50 { break }
        }
        return results
    }

    // MARK: - 工具

    func humanSize(_ n: Int) -> String {
        var n = Double(n)
        for unit in ["B", "KB", "MB", "GB"] {
            if n < 1024 {
                return unit == "B" ? "\(Int(n))B" : String(format: "%.1f%@", n, unit)
            }
            n /= 1024
        }
        return String(format: "%.1fTB", n)
    }

    func revealInFinder(path: String) -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    // MARK: - 文件操作（右键菜单）

    /// 复制一份副本（Duplicate 语义：同目录生成「xxx 副本」），返回新路径
    func duplicateItem(at path: String) -> String? {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let extPart = ext.isEmpty ? "" : ".\(ext)"

        var candidate = (dir as NSString).appendingPathComponent("\(stem) 副本\(extPart)")
        var i = 2
        while fm.fileExists(atPath: candidate) {
            candidate = (dir as NSString).appendingPathComponent("\(stem) 副本 \(i)\(extPart)")
            i += 1
        }
        do {
            try fm.copyItem(atPath: path, toPath: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    /// 移入废纸篓（可恢复，非永久删除）
    func trashItem(at path: String) -> Bool {
        var url: NSURL? = nil
        return trashItem(at: path, resultingItemURL: &url)
    }

    /// 移入废纸篓，并通过 AutoreleasingUnsafeMutablePointer 返回废纸篓中的实际 URL，用于「撤销删除」。
    func trashItem(at path: String, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) -> Bool {
        let fm = FileManager.default
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: resultingItemURL)
            return true
        } catch {
            return false
        }
    }

    /// 追加自定义技能库根目录（菜单）
    func addRoot(path: String) {
        var existing = roots
        var seen = Set(roots.map { ($0.path as NSString).standardizingPath })
        addRoot(&existing, &seen, path)
        if existing.count != roots.count {
            roots = existing
            setCurrentRootID(roots.last?.id)
        }
    }

    func removeRoot(id: String) {
        roots.removeAll { $0.id == id }
        rootPathByID[id] = nil
        if currentRootID == id {
            setCurrentRootID(roots.first?.id)
        }
    }
}
