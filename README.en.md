# Skill Reader · Skill Reader & Manager

[🇨🇳 中文](README.md) · [🇺🇸 English](README.en.md)

A local-first **skill package reader and manager**: browse your local skill libraries
(`SKILL.md` + `references/` + `scripts/`) with rendered Markdown, and share managed skills
across multiple Agents (Claude Code / OpenClaw / WorkBuddy …).

A native macOS desktop app (SwiftUI + WKWebView). Double-click to launch — no browser or backend service needed.

## What it does

**Reading**
- Detects skill packages (directories with `SKILL.md`, or standalone `.md` files), showing descriptions and md/py file stats
- Tree browsing of package internals: `references/` docs, `scripts/`, `assets/`, with the main document marked
- Rendered Markdown: YAML frontmatter cards, code highlighting, right-side table of contents (scroll-following)
- Script viewing: `.py` and other code files with line numbers and selection-to-copy
- Direct preview of images / PDF / JSON / YAML
- Reading / source mode toggle (`⌘/`)
- Global search over skill names / descriptions / content; reveal files in Finder

**Share skills (Agent interop)**
- `~/.agent/library` is the single source of truth; one-click "copy to library & distribute" pushes any Agent's skill to other Agents' skills dirs
- Distribution via symbolic links: edit the library → every Agent sees it instantly, no data sync
- "Distribute to platforms" panel to pick target Agents; top-bar "Sync" rebuilds distribution anytime
- Safe by design: only cleans up links it created pointing to the library; never touches Agents' own skills

## Installation

Drag `SkillReader.app` into the Applications folder and double-click (right-click → Open on first launch).

Build from source:

```bash
cd SkillReaderApp
./scripts/build_app.sh
open /Applications/SkillReader.app
```

Requirements: macOS 14+, Xcode Command Line Tools (with Swift 6).

## Usage

1. Complete Agent setup on first launch (enable installed Agents), the reader mounts their skill libraries
2. Click a skill name in the sidebar to expand its file tree — `SKILL.md` opens automatically; click any file to view it
3. Top-bar search filters the list as you type; press Enter for full-content search
4. Right-click a skill → "互通：复制到中心库并分发…": import to library, then pick target Agents
5. "Distribute to platforms" saves immediately; the top-bar "Sync" rebuilds distribution
6. "Copy code" copies the whole file; "Reveal" shows it in Finder
7. Press `Esc` to jump back to the skill's main document from a sub-file

## Theme

System-blue theme that follows light/dark mode; code blocks stay dark-highlighted in light mode.

## Data safety

The app writes only symbolic links into the library and each Agent's distribution dir — it never copies or
overwrites any Agent's own skill content. Pure file IO, no process spawning.

## Development

```bash
cd SkillReaderApp
swift build                          # compile
.build/debug/SkillReader --self-test # data-layer self-test (79 assertions)
.build/debug/SkillReader --render-smoke  # render-pipeline self-test
```

## License

MIT
