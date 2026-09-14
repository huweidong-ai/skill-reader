# 产品计划 · Roadmap

> 本文件记录 SkillReader 的定位演进与阶段目标，便于每次会话对齐「现在做到哪、下一步做什么」。

## 定位演进

1. **阅读器（已完成）**：本地 skill 包浏览与 Markdown 渲染阅读。
2. **管理器 · 共享 skills（当前阶段）**：在「阅读」之上，让纳入管理的 skill 在多个 Agent 之间共享。
3. **管理器 · SkillHub 接入（后续）**：接入 skill 市场，支持 skills 的卸载 / 安装 / 更新 / 新增。

---

## 当前阶段：Agent 之间共享 skills

### 架构决策（2026-08-25 确定）

选定 **B 模式：彻底单一真相源（single source of truth）**。

- 纳入某 Agent 时（`adoptAgentToLibrary`），把它所有真实 skill **导入中心库** `~/.agent/library`，
  并把该 Agent 目录里的真实文件夹 **替换为指向中心库的 symlink**。
  于是来源 Agent 自己、以及分发到的其它 Agent，**全部指向同一份文件**——改一处、全局生效。
- 中心库条目命名 `<ownerAgentId>__<skillName>`（如 `claude-code__ego-browser`）：
  跨 Agent 同名 skill 互不覆盖，各自独立分发。（已验证：你机器上 `ego-browser` 同时存在于 workbuddy 与 qoderwork，会分别成为 `workbuddy__ego-browser` / `qoderwork__ego-browser`。）
- 分发到目标 Agent 的链接名仍是**干净 skill 名**（`ego-browser`），对 Agent 透明、不污染目录。
- 采纳前，Agent 原真实目录整体移动到 `~/.agent/backups/<agentId>/` **可恢复，绝不删除**。
- sync 清理时**保留 owner 自己的采纳链接**（指向 `library/<owner>__…`），避免重新同步后丢来源 Agent 的 skills。

> 备选 A（来源 Agent 留原样、中心库仅作对外分享副本）被否决：A 下「改中心库」来源 Agent 不生效、改来源中心库不生效，存在两份漂移。
> B 更「互通」，代价是来源 Agent 目录不再是普通目录（均为 symlink）。此代价已确认接受。

### 已具备的能力

- **Agent 注册与挂载**：各 Agent 的 skills 目录通过 `~/.agent/skills/<agent-id>` 符号链接聚合，阅读器统一扫描、一处可读所有 Agent 的技能。
- **中心库 + 配置**：`~/.agent/library` 为唯一真相源；`~/.agent/distribute.json` 记录「canonical → 目标 Agent 列表」。
- **符号链接分发引擎 `SkillDistributor`**：
  - `adopt`：纳入即共享，真实目录 → 中心库 + symlink（带备份，幂等）。
  - `sync`：按配置把 canonical 分发给目标 Agent 的 skills 目录（干净链接名）；owner 采纳链接不被清理。
  - `importToLibrary`：任意 root 的 skill 以 canonical 命名导入中心库。
- **安全清理**：只清理「自己建的、指向中心库」的链接，绝不覆盖/删除各 Agent 自装的 skill（纯文件 IO，不 spawn 进程）。
- **UI 闭环**：右键某 skill →「复制到中心库并分发…」→ 勾选目标 Agent → 保存生效；顶栏「同步」按钮随时重建；启动自动 `syncAll` + 对已经纳入的 Agent 自动 `adopt`。
- **自测保障**：数据层 92 项断言，含 B 模式采纳、跨 Agent 去重、owner 链接保留、分发干净链接名等。

### 把「共享」做成流畅产品能力（待完善）

- [x] **冲突策略（B 模式）**：`<owner>__<skill>` 命名去重，跨 Agent 同名独立分发。
- [x] **单一真相源（B 模式）**：纳入即共享，所有 Agent 指向同一份。
- [ ] **批量共享**：选中某 Agent 的全部 skills，一键进中心库并分发；
- [ ] **状态总览**：中心库里有哪些 skill、各自共享给了哪些 Agent，一处可见、可撤销；

---

## 后续阶段：SkillHub 接入

- **SkillHub 接入**：从 skill 市场直接安装 / 更新 / 卸载 skills；
- 本阶段暂不动，先夯实「共享」再做市场
