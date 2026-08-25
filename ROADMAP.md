# 产品计划 · Roadmap

> 本文件记录 SkillReader 的定位演进与阶段目标，便于每次会话对齐「现在做到哪、下一步做什么」。

## 定位演进

1. **阅读器（已完成）**：本地 skill 包浏览与 Markdown 渲染阅读。
2. **管理器 · 共享 skills（当前阶段）**：在「阅读」之上，让纳入管理的 skill 在多个 Agent 之间共享。
3. **管理器 · SkillHub 接入（后续）**：接入 skill 市场，支持 skills 的卸载 / 安装 / 更新 / 新增。

---

## 当前阶段：Agent 之间共享 skills

### 已具备的能力

- **Agent 注册与挂载**：各 Agent 的 skills 目录通过 `~/.agent/skills/<agent-id>` 符号链接聚合，阅读器统一扫描、一处可读所有 Agent 的技能。
- **中心库 + 配置**：`~/.agent/library` 为唯一真相源；`~/.agent/distribute.json` 记录「skill → 目标 Agent 列表」。
- **符号链接分发引擎 `SkillDistributor`**：把 skill 复制进中心库 → 以 symlink 分发到各 Agent 的 skills 目录；改中心库即所有 Agent 立即生效，无需同步数据。
- **安全清理**：只清理「自己建的、指向中心库」的链接，绝不覆盖或删除各 Agent 自装的 skill（纯文件 IO，不 spawn 进程）。
- **UI 闭环**：右键某 skill →「复制到中心库并分发…」→ 勾选目标 Agent（分发到平台面板）→ 保存生效；顶栏「同步」按钮随时重建；启动自动 `syncAll`。
- **自测保障**：数据层 79 项断言覆盖分发、不建目录、OpenClaw 路径、安全清理等。

### 把「共享」做成流畅产品能力（待完善）

- [ ] **批量共享**：选中某 Agent 的全部 skills 一键进入中心库并分发，而非逐条复制
- [ ] **状态总览**：中心库已有哪些 skill、各自共享给哪些 Agent，一处可见、可一键撤销
- [ ] **冲突策略**：同名的 skill 跨 Agent 存在时如何导入（当前 `importToLibrary` 跳过已存在、不覆盖）
- [ ] **纳入即共享**：探索「纳入某 Agent」时其 skills 自动对其他已纳管 Agent 可选共享的体验
- [ ] **反向同步**：Agent 端自行修改后中心库如何感知（当前中心库为唯一真相源，单向分发）

---

## 后续阶段：SkillHub 接入

- 卸载 / 安装 / 更新 / 新增 skills（从市场拉取、版本管理）
- 本阶段暂不动，先夯实「共享」再做市场
