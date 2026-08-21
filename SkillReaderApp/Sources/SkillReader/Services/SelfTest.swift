import Foundation

// MARK: - 内置自测（macOS 26 + Swift 6.3.3 下 swift test 不可用，用 --self-test）

enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        var failed = 0
        var passed = 0

        func check(_ cond: Bool, _ name: String) {
            if cond { passed += 1 }
            else {
                failed += 1
                print("FAIL: \(name)")
            }
        }

        // ---- Frontmatter ----
        do {
            let r = Frontmatter.parse("---\ntitle: My Skill\ndescription: \"A test skill\"\nversion: 1.5\ntags:\n  - a\n  - b\nenabled: true\n---\n\n# Body\n")
            check(r.dict["title"]?.stringValue == "My Skill", "fm: title")
            check(r.dict["description"]?.stringValue == "A test skill", "fm: quoted string")
            check(r.dict["version"]?.stringValue == "1.5", "fm: numeric")
            check(r.dict["tags"]?.stringValue == "、a、b", "fm: list")
            check(r.dict["enabled"]?.stringValue == "true", "fm: bool")
            check(r.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# Body"), "fm: body extraction")
        }
        do {
            let r = Frontmatter.parse("# No frontmatter\n")
            check(r.dict.isEmpty, "fm: no frontmatter -> empty dict")
            check(r.body.hasPrefix("# No frontmatter"), "fm: no frontmatter -> full body")
        }

        // ---- classify ----
        do {
            let store = SkillStore()
            check(store.classify("SKILL.md") == .md, "classify: md")
            check(store.classify("main.py") == .code, "classify: py code")
            check(store.classify("config.yaml") == .yaml, "classify: yaml")
            check(store.classify("logo.png") == .img, "classify: img")
            check(store.classify("doc.pdf") == .pdf, "classify: pdf")
            check(store.classify("notes.txt") == .text, "classify: text")
            check(store.classify("README.markdown") == .md, "classify: markdown")
            check(store.classify("archive.tar.gz") == .bin, "classify: bin")
        }

        // ---- humanSize ----
        do {
            let store = SkillStore()
            check(store.humanSize(500) == "500B", "size: B")
            check(store.humanSize(2048) == "2.0KB", "size: KB")
            check(store.humanSize(5 * 1024 * 1024) == "5.0MB", "size: MB")
        }

        // ---- safeJoin ----
        do {
            let store = SkillStore()
            check(store.safeJoin(root: "/tmp/root", rel: "a/b.md") != nil, "join: normal")
            check(store.safeJoin(root: "/tmp/root", rel: "../escape.md") == nil, "join: traversal blocked")
            check(store.safeJoin(root: "/tmp/root", rel: "/abs/path") == nil, "join: absolute blocked")
            check(store.safeJoin(root: "/tmp/root", rel: "sub/../../x") == nil, "join: deep traversal blocked")
        }

        // ---- AgentProfile Codable（detected 不应持久化）----
        do {
            var p = AgentProfile(id: "x", name: "X Agent", vendor: "v", iconName: "star",
                                 skillPath: "/tmp/__sr_nonexistent_skills__", enabled: true)
            p.detected = true
            let enc = try? JSONEncoder().encode(p)
            let dec = enc.flatMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
            if let dec = dec {
                check(dec.id == "x", "agentprofile: id roundtrip")
                check(dec.name == "X Agent", "agentprofile: name roundtrip")
                check(dec.enabled == true, "agentprofile: enabled roundtrip")
                check(dec.detected == false, "agentprofile: detected NOT persisted (got \(dec.detected))")
            } else {
                check(false, "agentprofile: encode/decode failed")
            }
        }

        // ---- AgentRegistry：符号链接（使用临时目录，不触碰 ~/.agent）----
        do {
            let base = NSTemporaryDirectory() + "skillreader-agent-\(UUID().uuidString)"
            let target = base + "/real/skills"
            let link = base + "/mount/myagent"
            try? FileManager.default.createDirectory(atPath: (link as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? AgentRegistry.linkAgent(link: link, target: target)
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: link, isDirectory: &isDir)
            check(ok, "agent: symlink created")
            check(isDir.boolValue, "agent: symlink resolves to dir")

            // 目标不存在时应自动创建
            let target2 = base + "/real2/skills"
            let link2 = base + "/mount/agent2"
            try? FileManager.default.createDirectory(atPath: (link2 as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            try? AgentRegistry.linkAgent(link: link2, target: target2)
            check(FileManager.default.fileExists(atPath: target2), "agent: missing target auto-created")

            // 重建应覆盖旧的（指向不同目标）
            let target3 = base + "/real3/skills"
            try? AgentRegistry.linkAgent(link: link2, target: target3)
            let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: link2)
            check(resolved == target3, "agent: relink points to new target (got \(resolved ?? "nil"))")

            try? FileManager.default.removeItem(atPath: base)
        }

        // ---- 临时目录扫描 + 搜索 + 树 ----
        do {
            let tmp = NSTemporaryDirectory() + "skillreader-selftest-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmp + "/demo-skill/references",
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: tmp + "/demo-skill/scripts",
                                                     withIntermediateDirectories: true)
            try? """
            ---
            name: demo-skill
            description: 一个自测用技能
            ---
            # Demo

            ```python
            print("hi")
            ```
            """.write(toFile: tmp + "/demo-skill/SKILL.md", atomically: true, encoding: .utf8)
            try? "print('x')\n".write(toFile: tmp + "/demo-skill/scripts/tool.py", atomically: true, encoding: .utf8)
            try? "ref\n".write(toFile: tmp + "/demo-skill/references/guide.md", atomically: true, encoding: .utf8)
            try? "---\ndescription: 独立技能\n---\n# Standalone\n".write(toFile: tmp + "/standalone.md", atomically: true, encoding: .utf8)

            let store = SkillStore()
            store.loadRoots(extra: [tmp])
            check(store.roots.count >= 1, "roots: loaded")
            store.currentRootID = store.roots.last?.id

            let skills = store.listSkills()
            check(skills.count == 2, "skills: found 2 (got \(skills.count))")
            let demo = skills.first(where: { $0.name == "demo-skill" })
            check(demo != nil, "skills: demo-skill found")
            check(demo?.entry == "SKILL.md", "skills: entry")
            check(demo?.description == "一个自测用技能", "skills: description parsed")
            check(demo?.stats.md == 2, "skills: md count 2 (got \(demo?.stats.md ?? -1))")
            check(demo?.stats.py == 1, "skills: py count 1")

            let standalone = skills.first(where: { $0.name == "standalone.md" })
            check(standalone != nil, "skills: standalone found")
            check(standalone?.description == "独立技能", "skills: standalone description")
            // standalone 技能是文件，readFile 应直接读文件本身（不拼包前缀）
            let standaloneFile = store.readFile(skillPath: "standalone.md", relPath: "standalone.md")
            check(standaloneFile?.content?.contains("# Standalone") == true,
                  "read: standalone file content (got \(standaloneFile?.content?.prefix(40) ?? "nil"))")

            // 树
            let tree = store.tree(for: "demo-skill")
            check(tree != nil, "tree: built")
            check(tree?.children.contains(where: { $0.name == "references" }) == true, "tree: has references")
            check(tree?.children.contains(where: { $0.name == "scripts" }) == true, "tree: has scripts")
            // 子节点路径必须是相对技能包的（openFile 用它拼接）
            let refChild = tree?.children.first(where: { $0.name == "references" })
            let refFile = refChild?.children.first
            check(refFile?.path.hasPrefix("demo-skill/") != true, "tree: child path is relative to skill (got \(refFile?.path ?? "nil"))")

            // 读文件（树里点击同一路径应可读）
            if let refFile {
                let viaTree = store.readFile(skillPath: "demo-skill", relPath: refFile.path)
                check(viaTree?.content?.contains("ref") == true, "read: via tree path (got \(refFile.path))")
            } else {
                check(false, "read: via tree path (references child missing)")
            }

            // 读文件
            let file = store.readFile(skillPath: "demo-skill", relPath: "SKILL.md")
            check(file?.kind == .md, "read: md kind")
            check(file?.content?.contains("# Demo") == true, "read: content")
            let py = store.readFile(skillPath: "demo-skill", relPath: "scripts/tool.py")
            check(py?.kind == .code, "read: py kind")
            check(py?.lang == "python", "read: py lang")

            // 越界读
            check(store.readFile(skillPath: "demo-skill", relPath: "../../etc/passwd") == nil, "read: traversal blocked")

            // 搜索
            let res = store.search("自测")
            check(res.contains(where: { $0.path == "demo-skill" }), "search: description hit")
            let res2 = store.search("Demo")
            check(res2.contains(where: { $0.path == "demo-skill" }), "search: content hit")

            // 右键操作：复制副本 / 移入废纸篓
            let dupPath = store.duplicateItem(at: (tmp as NSString).appendingPathComponent("demo-skill"))
            check(dupPath != nil && FileManager.default.fileExists(atPath: dupPath!),
                  "dup: created \(dupPath ?? "nil")")
            check(dupPath?.hasSuffix("demo-skill 副本") == true, "dup: name suffix")
            // 副本可被识别为新技能包
            let dupName = (dupPath as NSString?)?.lastPathComponent ?? ""
            check(store.listSkills().contains(where: { $0.name == dupName }),
                  "dup: discoverable as skill")
            // 清理副本
            if let dupPath { try? FileManager.default.removeItem(atPath: dupPath) }
            // 移入废纸篓后原文件不存在
            let trashTest = (tmp as NSString).appendingPathComponent("trash-me.txt")
            try? "x".write(toFile: trashTest, atomically: true, encoding: .utf8)
            check(store.trashItem(at: trashTest), "trash: ok")
            check(!FileManager.default.fileExists(atPath: trashTest), "trash: gone from origin")

            try? FileManager.default.removeItem(atPath: tmp)
        }

        print("-----------------------------")
        print("SelfTest: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
