# Skill Reader · 技能阅读器

[🇨🇳 中文](README.md) · [🇺🇸 English](README.en.md)

一个本地优先的 **skill 包阅读器**：浏览本机技能库（`SKILL.md` + `references/` + `scripts/`），Markdown 渲染阅读、frontmatter 卡片、目录大纲、Python 等脚本语法高亮 + 行号查看——弥补 Typora 对脚本展示的不足。

原生 macOS 桌面应用（SwiftUI + WKWebView），双击即用，无需浏览器与后端服务。

![screenshot](docs/screenshots/main.png)

## 能做什么

- 识别 skill 包（含 `SKILL.md` 的目录，或独立 `.md` 文件），显示描述与 md/py 文件统计
- 树形浏览包内结构：`references/` 子文档、`scripts/` 脚本、`assets/` 资源，主文档带「主」标记
- Markdown 渲染阅读：YAML frontmatter 卡片、代码高亮、右侧目录大纲（滚动跟随）
- 脚本高亮查看：`.py` 等代码文件带行号、一键复制
- 图片 / PDF / JSON / YAML 直接预览
- 阅读 / 源码模式切换（`⌘/`）
- 技能名/描述/内容全局搜索；一键在 Finder 中定位文件
- **现代靛蓝主题**：美观大气的科技感设计，跟随系统自动切换浅色 / 深色模式
  - 桌面版与 Web 版共用同一套设计语言；代码块在浅色模式下也呈现深色高亮，阅读更聚焦

## 安装

### 方式一：直接下载 .app

构建产物为 `SkillReader.app`，拖入「应用程序」文件夹，双击即可使用（首次启动右键 → 打开）。

### 方式二：源码构建

```bash
cd SkillReaderApp
./scripts/build_app.sh
open ~/Applications/SkillReader.app
```

构建依赖：macOS 14+，Xcode Command Line Tools（含 Swift 6）。

## 使用

1. 启动后自动扫描 `~/.workbuddy/skills`（用户级技能库）；通过「技能库」菜单可添加其他目录
2. 左侧点击技能名展开文件树，自动打开 `SKILL.md`；点击任一文件切换查看
3. 顶栏搜索框：输入即过滤技能列表，回车进行内容全局搜索
4. 「技能库」菜单 → 显示大纲（`⇧⌘O`）开关右侧目录大纲；`⌘/` 切换阅读 / 源码模式
5. 代码文件右上角「复制代码」一键复制全文；「定位文件」在 Finder 中显示
6. `Esc` 从子文件快速返回当前技能的主文档

## 数据安全

应用只读技能库目录，不写回任何文件；可随时用「技能库」菜单移除已添加目录。

## 开发

```bash
cd SkillReaderApp
swift build                          # 编译
.build/debug/SkillReader --self-test # 数据层自测（42 项断言）
.build/debug/SkillReader --render-smoke  # 渲染链路自测
```

> web 版（`server.py` + `static/`）已保留在仓库中，作为无 Swift 环境时的备用方案；桌面版为新主推形态。

## License

MIT
