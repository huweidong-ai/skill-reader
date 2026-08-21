# Skill Reader

[🇨🇳 中文](README.md) · [🇺🇸 English](README.en.md)

A local-first **skill package reader**: browse your local skills library (`SKILL.md` + `references/` + `scripts/`) with rendered Markdown reading, frontmatter cards, table of contents, and syntax-highlighted script viewing with line numbers — filling the gap where Typora falls short for script files.

A native macOS desktop app (SwiftUI + WKWebView). Double-click to launch — no browser or backend service needed.

![screenshot](docs/screenshots/main.png)

## What it does

- Detects skill packages (directories with `SKILL.md`, or standalone `.md` files), showing descriptions and md/py file stats
- Tree browsing of package internals: `references/` docs, `scripts/`, `assets/`, with the main document marked
- Rendered Markdown reading: YAML frontmatter cards, code highlighting, right-side table of contents (scroll-following)
- Script viewing: `.py` and other code files with line numbers and one-click copy
- Direct preview of images / PDF / JSON / YAML
- Reading / source mode toggle (`⌘/`)
- Global search over skill names / descriptions / content; reveal files in Finder

## Installation

### Option 1: Download the .app

The build output is `SkillReader.app`. Drag it into the Applications folder and double-click to run (right-click → Open on first launch).

### Option 2: Build from source

```bash
cd SkillReaderApp
./scripts/build_app.sh
open ~/Applications/SkillReader.app
```

Requirements: macOS 14+, Xcode Command Line Tools (with Swift 6).

## Usage

1. On launch it scans `~/.workbuddy/skills` (user-level skills library); add other directories via the "Skills Library" menu
2. Click a skill name in the sidebar to expand its file tree — `SKILL.md` opens automatically; click any file to view it
3. Search box in the top bar: filter skills as you type; press Enter for full-content search
4. "Skills Library" menu → Show Outline (`⇧⌘O`) toggles the right-side TOC; `⌘/` toggles reading / source mode
5. "Copy code" in the code header copies the whole file; "Reveal" shows it in Finder
6. Press `Esc` to jump back to the skill's main document from a sub-file

## Data safety

The app only reads from your skills directories and never writes back. Added directories can be removed anytime via the "Skills Library" menu.

## Development

```bash
cd SkillReaderApp
swift build                          # compile
.build/debug/SkillReader --self-test # data-layer self-test (42 assertions)
.build/debug/SkillReader --render-smoke  # render-pipeline self-test
```

> The web version (`server.py` + `static/`) is kept in the repo as a fallback for environments without Swift. The desktop app is the primary form.

## License

MIT
