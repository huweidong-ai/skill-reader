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

        // ---- AgentProfile.skillCount 多路径去重计数 ----
        do {
            let base = NSTemporaryDirectory() + "skillreader-multipath-\(UUID().uuidString)"
            let p1 = base + "/root1"
            let p2 = base + "/root2"
            try? FileManager.default.createDirectory(atPath: p1 + "/skill-A", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: p2 + "/skill-B", withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: p2 + "/skill-A", withIntermediateDirectories: true) // 同名 skill-A 与 p1 重复
            try? "x".write(toFile: p1 + "/skill-A/SKILL.md", atomically: true, encoding: .utf8)
            try? "x".write(toFile: p2 + "/skill-A/SKILL.md", atomically: true, encoding: .utf8)
            try? "x".write(toFile: p2 + "/skill-B/SKILL.md", atomically: true, encoding: .utf8)
            // skill-C 不含 SKILL.md，不应被计数
            try? FileManager.default.createDirectory(atPath: p1 + "/skill-C", withIntermediateDirectories: true)
            try? "x".write(toFile: p1 + "/skill-C/readme.md", atomically: true, encoding: .utf8)

            let p = AgentProfile(id: "mp", name: "MultiPath", vendor: "test", iconName: "x",
                                 skillPath: p1, extraSkillPaths: [p2])
            check(p.detected == true, "agent-multi: detected when any path exists")
            check(p.skillCount == 2, "agent-multi: skillCount = 2 (A+B, dedup) got \(p.skillCount)")
            check(p.allSkillPaths.count == 2, "agent-multi: allSkillPaths returns 2 unique existing dirs")

            // 全部路径不存在
            let empty = AgentProfile(id: "mp2", name: "Empty", vendor: "test", iconName: "x",
                                     skillPath: "/tmp/__nope1__", extraSkillPaths: ["/tmp/__nope2__"])
            check(empty.detected == false, "agent-multi: detected=false when no path exists")
            check(empty.skillCount == -1, "agent-multi: skillCount = -1 when no path exists")
            check(empty.allSkillPaths.isEmpty, "agent-multi: allSkillPaths empty when no path exists")

            try? FileManager.default.removeItem(atPath: base)
        }

        // ---- SkillStore.listSkills 聚合层下钻（OpenClaw 多路径挂载场景）----
        do {
            let base = NSTemporaryDirectory() + "skillreader-aggregate-\(UUID().uuidString)"
            let aggregate = base + "/openclaw"          // 模拟 ~/.agent/skills/openclaw
            let core = aggregate + "/core"              // 二级：核心路径（可能为空）
            let ws = aggregate + "/workspace"           // 二级：workspace/skills
            try? FileManager.default.createDirectory(atPath: core, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: ws + "/cam-cap", withIntermediateDirectories: true)
            try? "x".write(toFile: ws + "/cam-cap/SKILL.md", atomically: true, encoding: .utf8)
            try? FileManager.default.createDirectory(atPath: ws + "/screen-cap", withIntermediateDirectories: true)
            try? "x".write(toFile: ws + "/screen-cap/SKILL.md", atomically: true, encoding: .utf8)

            let store = SkillStore()
            store.loadRoots(extra: [aggregate])
            // 切到聚合 root
            if let id = store.roots.first(where: { $0.path == aggregate })?.id {
                store.currentRootID = id
            }
            let skills = store.listSkills()
            let names = skills.map { $0.name }.sorted()
            check(names == ["cam-cap", "screen-cap"],
                  "aggregate: listSkills drills into aggregate layer (got \(names))")

            try? FileManager.default.removeItem(atPath: base)
        }

        // ---- AgentProfile Codable：extraSkillPaths 持久化 + detected 不持久化 ----
        do {
            var p = AgentProfile(id: "x", name: "X Agent", vendor: "v", iconName: "star",
                                 skillPath: "/tmp/__sr_nonexistent_skills__",
                                 extraSkillPaths: ["/tmp/__extra1__", "/tmp/__extra2__"],
                                 enabled: true)
            p.detected = true
            let enc = try? JSONEncoder().encode(p)
            let dec = enc.flatMap { try? JSONDecoder().decode(AgentProfile.self, from: $0) }
            if let dec = dec {
                check(dec.id == "x", "agentprofile: id roundtrip")
                check(dec.name == "X Agent", "agentprofile: name roundtrip")
                check(dec.enabled == true, "agentprofile: enabled roundtrip")
                check(dec.extraSkillPaths == ["/tmp/__extra1__", "/tmp/__extra2__"],
                      "agentprofile: extraSkillPaths roundtrip got \(dec.extraSkillPaths)")
                check(dec.detected == false, "agentprofile: detected NOT persisted (got \(dec.detected))")
            } else {
                check(false, "agentprofile: encode/decode failed")
            }
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

        // ---- Skill 分发引擎（临时目录，不污染真实 ~/.agent）----
        do {
            let base = NSTemporaryDirectory() + "skilldist-test-\(UUID().uuidString)"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: base) }

            let lib = (base as NSString).appendingPathComponent("library")
            let p1 = (base as NSString).appendingPathComponent("platformA")   // Claude Code 模拟
            let p2 = (base as NSString).appendingPathComponent("platformB")   // OpenClaw 模拟
            _ = (base as NSString).appendingPathComponent("platformC")   // 未安装平台模拟（目录不存在）

            // 中心库建两个 skill：skill-a（含 SKILL.md）、skill-b
            let a = (lib as NSString).appendingPathComponent("skill-a")
            try? fm.createDirectory(atPath: (a as NSString).appendingPathComponent("scripts"),
                                    withIntermediateDirectories: true)
            try? "# Skill A\n".write(toFile: (a as NSString).appendingPathComponent("SKILL.md"),
                                     atomically: true, encoding: .utf8)
            try? "print(1)".write(toFile: (a as NSString).appendingPathComponent("scripts/tool.py"),
                                  atomically: true, encoding: .utf8)
            let b = (lib as NSString).appendingPathComponent("skill-b")
            try? fm.createDirectory(atPath: b, withIntermediateDirectories: true)
            try? "# Skill B\n".write(toFile: (b as NSString).appendingPathComponent("SKILL.md"),
                                     atomically: true, encoding: .utf8)

            // 平台目录里已有「用户自装」的普通目录，分发器绝不能动它
            let userOwned = (p1 as NSString).appendingPathComponent("user-skill")
            try? fm.createDirectory(atPath: userOwned, withIntermediateDirectories: true)
            // p1、p2 存在（已安装）；p3 目录不存在（未安装）
            try? fm.createDirectory(atPath: p1, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: p2, withIntermediateDirectories: true)

            let config = SkillDistributor.Config(skills: [
                "skill-a": ["claude", "openclaw", "not-installed"],
                "skill-b": ["claude"],
            ])
            // not-installed 平台目录不存在 → 应跳过且不创建目录
            let dirs: [String: [String]] = [
                "claude": [p1],
                "openclaw": [p2],
                "not-installed": [(base as NSString).appendingPathComponent("ghost")],
            ]

            // 首次同步：3 个链接（not-installed 跳过）
            let n1 = SkillDistributor.sync(library: lib, platformDirs: dirs, config: config)
            check(n1 == 3, "dist: first sync builds 3 links, skips not-installed (got \(n1))")
            check(fm.fileExists(atPath: (p1 as NSString).appendingPathComponent("skill-a")), "dist: skill-a -> p1")
            check(fm.fileExists(atPath: (p2 as NSString).appendingPathComponent("skill-a")), "dist: skill-a -> p2")
            check(fm.fileExists(atPath: (p1 as NSString).appendingPathComponent("skill-b")), "dist: skill-b -> p1")
            // 关键：未安装平台目录不应被创建
            check(!fm.fileExists(atPath: (base as NSString).appendingPathComponent("ghost")),
                  "dist: not-installed platform dir NOT created")

            // 链接确实指向中心库（同源）
            let destA = try? fm.destinationOfSymbolicLink(atPath: (p1 as NSString).appendingPathComponent("skill-a"))
            check(destA?.hasSuffix("/library/skill-a") == true, "dist: link target is library (got \(destA ?? "nil"))")

            // 用户自装的 skill 未被清理
            check(fm.fileExists(atPath: userOwned), "dist: user-owned skill untouched")

            // 幂等：再次同步不炸、不重复建
            let n2 = SkillDistributor.sync(library: lib, platformDirs: dirs, config: config)
            check(n2 == 3, "dist: re-sync idempotent (got \(n2))")

            // 移除分发：skill-b 不再分发
            var cfg2 = config
            cfg2.skills["skill-b"] = nil
            let n3 = SkillDistributor.sync(library: lib, platformDirs: dirs, config: cfg2)
            check(n3 == 2, "dist: after removal builds 2 links (got \(n3))")
            check(!fm.fileExists(atPath: (p1 as NSString).appendingPathComponent("skill-b")), "dist: removed link gone")

            // 用户自装 skill 在二次清理后仍完好
            check(fm.fileExists(atPath: userOwned), "dist: user-owned skill survives re-sync")

            // OpenClaw 分发目标走 extra 路径而非 skillPath
            let oc = AgentProfile(id: "openclaw", name: "OpenClaw", vendor: "开源", iconName: "shippingbox",
                                  skillPath: (base as NSString).appendingPathComponent("oc-core"),
                                  extraSkillPaths: [(base as NSString).appendingPathComponent("oc-workspace")])
            try? fm.createDirectory(atPath: (base as NSString).appendingPathComponent("oc-workspace"),
                                    withIntermediateDirectories: true)
            check(oc.distributionPaths == [(base as NSString).appendingPathComponent("oc-workspace")],
                  "dist: openclaw targets extra path, not skillPath (got \(oc.distributionPaths))")
            // 常规 Agent 分发目标 = skillPath
            let cc = AgentProfile(id: "claude-code", name: "Claude Code", vendor: "Anthropic", iconName: "brain",
                                  skillPath: (base as NSString).appendingPathComponent("cc-skills"))
            try? fm.createDirectory(atPath: (base as NSString).appendingPathComponent("cc-skills"),
                                    withIntermediateDirectories: true)
            check(cc.distributionPaths == [(base as NSString).appendingPathComponent("cc-skills")],
                  "dist: normal agent targets skillPath (got \(cc.distributionPaths))")
        }

        // ---- Skill 互通：B 模式（单一真相源 / 采纳 / 去重 / owner 保留）----
        do {
            let fm = FileManager.default
            let base = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("sr_selftest_b_\(UUID().uuidString)")
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            let lib = (base as NSString).appendingPathComponent("library")
            let backup = (base as NSString).appendingPathComponent("backups")
            let agentX = (base as NSString).appendingPathComponent("agentX-skills")
            let agentY = (base as NSString).appendingPathComponent("agentY-skills")
            let target = (base as NSString).appendingPathComponent("target-skills")
            try? fm.createDirectory(atPath: agentX, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: agentY, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)

            func makeSkill(_ dir: String, _ name: String) {
                let d = (dir as NSString).appendingPathComponent(name)
                try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                try? "x".write(toFile: (d as NSString).appendingPathComponent("SKILL.md"),
                               atomically: true, encoding: .utf8)
            }
            makeSkill(agentX, "skill-a")
            makeSkill(agentX, "skill-b")
            makeSkill(agentY, "skill-a")   // 同名，跨 Agent 重复

            // 1) 采纳 agent X：真实目录 → 中心库 + symlink
            let r1 = SkillDistributor.adopt(agentId: "x", skillDirs: [agentX],
                                            library: lib, backupRoot: backup)
            check(r1.imported == 2 && r1.linked == 2, "b: adopt X imported/linked 2 (got \(r1.imported)/\(r1.linked))")
            check(fm.fileExists(atPath: (lib as NSString).appendingPathComponent("x__skill-a")),
                  "b: library has canonical x__skill-a")
            check(fm.fileExists(atPath: (lib as NSString).appendingPathComponent("x__skill-b")),
                  "b: library has canonical x__skill-b")
            // agentX 原目录变为 symlink 指向中心库
            let linkAX = (agentX as NSString).appendingPathComponent("skill-a")
            let destAX = (try? fm.destinationOfSymbolicLink(atPath: linkAX)) ?? ""
            check(!destAX.isEmpty, "b: agentX/skill-a became symlink")
            check(destAX.hasSuffix("x__skill-a"), "b: symlink points to canonical x__skill-a (got \(destAX))")
            // 备份保留原始真实目录
            check(fm.fileExists(atPath: ((backup as NSString).appendingPathComponent("x/skill-a") as NSString)
                                    .appendingPathComponent("SKILL.md")),
                  "b: backup keeps original skill-a/SKILL.md")

            // 2) 再次采纳幂等：不重复导入/链接
            let r2 = SkillDistributor.adopt(agentId: "x", skillDirs: [agentX],
                                            library: lib, backupRoot: backup)
            check(r2.imported == 0 && r2.linked == 0, "b: re-adopt idempotent (got \(r2.imported)/\(r2.linked))")

            // 3) 跨 Agent 同名去重：Y 的 skill-a 进库为 y__skill-a，不覆盖 x__
            let r3 = SkillDistributor.adopt(agentId: "y", skillDirs: [agentY],
                                            library: lib, backupRoot: backup)
            check(r3.imported == 1, "b: adopt Y imported 1 (got \(r3.imported))")
            check(fm.fileExists(atPath: (lib as NSString).appendingPathComponent("y__skill-a")),
                  "b: library has y__skill-a (no overwrite of x__)")

            // 4) 分发：把 x__skill-a 分发给 target，链接名应为干净 skill-a
            var cfg = SkillDistributor.Config()
            cfg.skills["x__skill-a"] = ["target"]
            let n = SkillDistributor.sync(library: lib, platformDirs: ["target": [target]], config: cfg)
            check(n == 1, "b: sync built 1 link (got \(n))")
            let tLink = (target as NSString).appendingPathComponent("skill-a")
            let tDest = (try? fm.destinationOfSymbolicLink(atPath: tLink)) ?? ""
            check(tDest.hasSuffix("x__skill-a"), "b: target link basename clean skill-a -> x__skill-a (got \(tDest))")

            // 5) owner 自己的采纳链接在 sync 清理中保留（不被误删）
            //    模拟清理 agentX 自己的目录：其 skill-a 指向 library/x__skill-a，owner=x 应保留
            let _ = SkillDistributor.sync(library: lib,
                                          platformDirs: ["x": [agentX], "target": [target]], config: cfg)
            check(fm.fileExists(atPath: linkAX), "b: owner adoption symlink survives re-sync")
            // 而 target 的分发链接重建后仍存在
            check(fm.fileExists(atPath: tLink), "b: target distribution link survives re-sync")
        }

        print("-----------------------------")
        print("SelfTest: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
