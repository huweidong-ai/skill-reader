# 我给 AI Agent 的技能库写了个阅读器，今天开源了

> Agent 的 skill 越攒越多，你却从没打开看过一眼。
> macOS 原生阅读器 · 跨 Agent 共享 · 今日开源

现在谁电脑里还没装几个 AI Agent。

我自己一直在用的就有 Claude Code、WorkBuddy、OpenClaw、ChatGPT（Codex）、OpenCode。而 SkillReader 内置探测支持的 Agent 一共有 12 个——OpenAI 的 Codex CLI、Google 的 Gemini CLI、字节的 Trae、阿里的 QoderWork、月之暗面的 Kimi Code……你装了几个，它就认出几个。

每个 Agent 都在悄悄帮你攒**技能（skill）**。攒得越来越多，然后呢？

**然后就没有然后了。**

没人认真看过它们一眼。这篇文章想干两件事：先把 skill 是什么讲明白（我发现真不少人说不清），再介绍我为它写的一个 macOS 工具——**SkillReader**，今天开源。

---

## PART 01 先说清楚：skill 到底是什么

一句话：**skill 是 Agent 的「能力包」——把一个通用 Agent 变成某个领域的专家 Agent。**

它长得不神秘，就是一个文件夹：

- **`SKILL.md`**（必有）：一份 Markdown 操作手册，开头带 name 和 description；
- **`references/`**：长文档、踩坑记录，按主题拆开；
- **`scripts/`**：可执行脚本；
- **`assets/`**：模板、图标。

关键在它的加载机制，叫**渐进式加载**：平时只有每条 skill 的 description（一段触发场景 + 触发词）常驻在 Agent 的上下文里，成本极低；当你说了匹配的话——比如"帮我写个 skill"——Agent 才把对应的 SKILL.md 正文加载进来，需要细节时再去读 references。

这个设计对 Agent 极其友好。但请注意一件事：

**SKILL.md 默认的读者是 Agent——但你要想不断优化 skill、让 Agent 少走弯路，就得先读懂它。**

你得知道自己的 Agent 装了什么能力、某个 skill 什么时候会被触发、里面到底让它怎么干——不然出了问题你连排查都不知道从哪下手。

问题就在这：**skill 这东西，只对 Agent 友好，对人极不友好。**

---

## PART 02 三个真实的痛点

**痛点一：埋得深，预览和编辑都不方便。**

skill 不在文档目录、不在桌面，而是埋在各 Agent 层层包裹的隐藏目录深处——`~/.claude/skills`、`~/.workbuddy/skills`……有的 Agent（比如 OpenClaw）还有工作区、内置等好几个 skill 目录。想看某个 skill，先得记住路径 `cd` 进去一层层翻；想改两笔，还得先在层层目录里把文件翻出来，再挑个编辑器打开——光「找到它」这一步就够费劲。你永远记不住哪个 skill 在哪个 Agent 手里。

**痛点二：没法读。**

skill 是**文件夹**，不是一个文件。双击打开 SKILL.md，看到的是原始 Markdown 源码——几百行裸文本，代码块没有高亮，目录要肉眼扫，references/ 下的子文档还得自己一层层翻。

**痛点三：没法共享。**

同一个 skill，想让另一个 Agent 也用上？只能复制一份过去。然后你改了这边的，那边还是旧的。两份漂移，越用越乱。而 skill 又特别值得共享——好用的 skill 就该让手里所有 Agent 都有。

---

## PART 03 SkillReader：阅读 + 共享，就做这两件事

所以我写了 SkillReader——一个原生 macOS 应用（SwiftUI + WKWebView），双击即用，没有浏览器、没有后端服务。我只把两件事做到位。

### 📖 第一件事：像读文档站一样读 skill

- **认识 skill 包**：自动识别 skill 目录（含 SKILL.md 的文件夹），左侧树形展示包内结构——references/ 子文档、scripts/ 脚本，主文档带「主」标记，点谁看谁；
- **渲染阅读**：打开即渲染，YAML frontmatter 变成信息卡片，代码带语法高亮，右侧目录大纲跟着滚动走；`⌘/` 一键切回源码模式；
- **页内查找**：`Cmd+F` 输入关键词，命中全部高亮，回车逐条跳转——几百行的 skill 里找一个参数，秒级定位；
- **顺手编辑**：看的过程中想改？`⌘E` 一键在系统默认编辑器中打开（VSCode、Typora 用哪个都行），还能一键在 Finder 中定位；
- **全局搜索**：顶栏搜索框，按技能名、描述、内容全文过滤；
- **不止 Markdown**：脚本带行号看代码，图片、PDF、JSON、YAML 直接预览；主题跟随系统，也能手动切。

![主界面：左侧 skill 包列表，中间渲染后的 SKILL.md，右侧目录大纲](docs/screenshots/skillreader-main.jpg)

![页内查找：关键词高亮，逐条跳转](docs/screenshots/skillreader-find.jpg)

### 🔗 第二件事：让 skill 在 Agent 之间真正共享

这是我觉得最有价值的部分，稿子必须说清楚——它不是"聚合显示"，是**单一真相源**：

- 勾选纳入某个 Agent 时，它全部真实 skill 会"采纳"进中心库 `~/.agent/library`，原目录替换为指向中心库的符号链接（symlink）；
- 之后来源 Agent 自己、以及分发到的其它 Agent，**全部指向同一份文件——改一处，全局生效**；
- 中心库按 `Agent名__技能名` 命名，跨 Agent 同名 skill 互不覆盖。我机器上 WorkBuddy 和 QoderWork 就各有一个 `ego-browser`，分别独立、互不打架；
- 也可以右键某个 skill →「复制到中心库并分发…」，勾选要共享给哪些 Agent；顶栏「同步」按钮随时重建分发。

**数据安全是我最在意的**：采纳前，Agent 原目录会整体移进备份目录，可恢复、绝不删除；除此之外应用只清理「自己建的、指向中心库」的链接，**绝不碰各 Agent 自行安装的 skill**。纯文件操作，不起任何进程。

![配置页：自动探测本机已安装的 Agent，勾选纳入管理](docs/screenshots/skillreader-setup.jpg)

---

## PART 04 和直接用编辑器打开，差在哪

| | 编辑器 / 浏览器打开 .md | SkillReader |
| --- | --- | --- |
| 看到的是什么 | 一个裸文件 | 整个 skill 包：树形结构 + 主文档 + 子文档 |
| 打开效果 | Markdown 源码 | 渲染阅读：目录、代码高亮、frontmatter 卡片 |
| 找 skill | 记住路径，自己翻 | 12 个 Agent 的技能库一处挂载 |
| 跨 Agent 共享 | 复制粘贴，两份漂移 | 中心库 + symlink，改一处全局生效 |

---

## PART 05 怎么拿到

- **GitHub（源码 + 说明）**：`https://github.com/huweidong-ai/skill-reader`，MIT 协议，随便用随便改；
- **直接下载**：仓库 **Releases** 页面拿 `SkillReader-1.0.0.dmg`，拖进「应用程序」即可。

⚠️ 目前是 **Apple Silicon（arm64）** 版本，需要 **macOS 14 及以上**。个人开发者 ad-hoc 签名、没上架没公证，首次打开若提示「无法验证开发者」，右键点 App → 打开，或终端执行 `xattr -cr /Applications/SkillReader.app` 解除隔离后再开，属正常现象。

---

## PART 06 接下来想做的

- **批量共享**：选中某个 Agent 的全部 skills，一键进中心库并分发；
- **状态总览**：中心库里有哪些 skill、各自共享给了哪些 Agent，一处可见、可撤销；
- **SkillHub 接入**：从 skill 市场直接安装 / 更新 / 卸载。

欢迎提 Issue 和 PR。想参与开发、或者想聊聊怎么用的，直接公众号留言或后台私信，我都会认真看。

---

## 写在最后

skill 是 AI 时代一种新的"文档形态"：写给 Agent 看的操作手册。

但 Agent 的能力归 Agent，**知情的权利应该留在人手里**。你总得能看清楚：它在什么时候、会被什么话触发、拿什么流程干活。

SkillReader 就干这个——把散落在十几个目录里的技能，集中、舒服地读起来，顺便让它们跨 Agent 流动。

觉得有用，点个 **Star** ⭐ 是最好的鼓励。

—— 胡卫东
