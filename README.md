# Skill Reader · 技能阅读器

一个本地优先的 **skill 包阅读器**，用于浏览本机技能库（SKILL.md + references/ + scripts/），阅读体验参考 Typora：Markdown 渲染阅读、YAML frontmatter 卡片、目录大纲，以及**Python 等脚本的语法高亮 + 行号查看**——弥补 Typora 对 py 脚本展示的不足。

零第三方依赖（后端纯 Python 标准库，前端依赖库已内置本地，可离线使用）。

## 能做什么

- 浏览技能库根目录，识别每个 skill 包（含 `SKILL.md` 的目录，或独立 `.md` 文件），显示描述与 md/py 文件统计
- 树形浏览 skill 包内部结构：`references/` 子文档、`scripts/` 脚本、`assets/` 资源，主文档带「主」标记
- Markdown 渲染阅读：YAML frontmatter 解析为信息卡片、代码块高亮、右侧目录大纲（滚动跟随）
- **脚本高亮查看**：`.py` 等代码文件带语法高亮、行号、一键复制（Typora 的短板）
- 图片 / PDF / JSON / YAML 等类型直接预览，其他类型提供原始文件入口
- 阅读 / 源码模式切换（`Ctrl+/`，同 Typora 的「源代码模式」）
- 技能名/描述/内容全局搜索；一键在 Finder 中定位文件

## 安装与启动

无需安装依赖，直接启动：

```bash
cd skill-reader
python3 server.py
```

启动后浏览器访问 **http://127.0.0.1:8666**。

| 参数 | 说明 |
| --- | --- |
| `--port 9000` | 自定义端口（默认 8666） |
| `--root /path/to/skills` | 追加技能库根目录，可多次指定 |
| `--host 0.0.0.0` | 允许局域网访问 |

### 技能库根目录的确定顺序

1. `~/.workbuddy/skills`（用户级技能，默认）
2. `skill-reader/.workbuddy/skills`（项目级技能，若存在）
3. `roots.json` 中列出的绝对路径（每行一个，`#` 开头为注释，需与 server.py 同目录）
4. 命令行 `--root` 追加的路径

## 使用

1. 顶栏右上角可切换技能库根目录（多个根时）
2. 左侧点击技能名展开文件树，自动打开 `SKILL.md`；点击任一文件切换查看
3. 顶栏搜索框：输入即过滤技能列表，回车进行内容全局搜索
4. `☰` 按钮开关右侧目录大纲；`阅读/源码` 按钮切换 Markdown 渲染模式
5. 代码文件右上角「复制代码」一键复制全文；「定位文件」在 Finder 中显示
6. `Esc` 从子文件快速返回当前技能的主文档

## API

| 接口 | 说明 |
| --- | --- |
| `GET /api/roots` | 可用根目录列表 |
| `GET /api/skills?root=<id>` | 技能包列表（含描述与统计） |
| `GET /api/tree?root=<id>&path=<rel>` | 技能包文件树 |
| `GET /api/file?root=<id>&path=<rel>` | 文本文件内容 |
| `GET /api/raw?root=<id>&path=<rel>` | 原始字节（图片/PDF 等） |
| `GET /api/search?root=<id>&q=<kw>` | 名称/描述/SKILL.md 内容搜索 |
| `POST /api/reveal` | 在 Finder 中定位（macOS） |

所有路径访问均做越界校验，只允许读取配置的根目录。

## 项目结构

```
skill-reader/
├── server.py          # 本地后端（Python 标准库）
├── roots.json         # （可选）追加技能库根目录
└── static/
    ├── index.html     # 页面骨架
    ├── style.css      # Typora 风格样式
    ├── app.js         # 前端逻辑
    └── vendor/        # 内置依赖：marked / highlight.js / DOMPurify
```
