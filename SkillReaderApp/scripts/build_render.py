#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_render.py — 将 render.html 模板中的 vendor 引用内联，生成自包含 render.html。

WKWebView 的 loadFileURL(_:allowingReadAccessTo:) 只能授予一个目录的读取权限：
- render.html 引用的 marked/highlight/DOMPurify 位于 App bundle 内；
- 技能库里的图片/PDF 位于用户技能库根目录。
两者无法同时被覆盖。解决方案：把 vendor JS/CSS 内联进 HTML，页面自包含，
readAccess 只授予技能库根目录即可（图片仍可加载）。

用法: python3 build_render.py [--out 输出路径]
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR_DIR = os.path.join(HERE, "..", "vendor-src")
WEB_DIR = os.path.join(HERE, "..", "Sources", "SkillReader", "Resources", "web")
TEMPLATE = os.path.join(VENDOR_DIR, "render.template.html")
DEFAULT_OUT = os.path.join(WEB_DIR, "render.html")

# vendor 文件 → 内联方式
VENDOR_CSS = [("github.min.css", "<style>", "</style>")]
VENDOR_JS = [
    ("marked.min.js", "<script>", "</script>"),
    ("purify.min.js", "<script>", "</script>"),
    ("highlight.min.js", "<script>", "</script>"),
]


def load(name):
    with open(os.path.join(VENDOR_DIR, name), "r", encoding="utf-8") as f:
        return f.read()


def inline(template):
    # 替换 CSS link
    for name, open_tag, close_tag in VENDOR_CSS:
        pattern = re.compile(
            r'<link[^>]*href="%s"[^>]*>' % re.escape(name), re.IGNORECASE)
        template = pattern.sub(
            lambda _: open_tag + "\n" + load(name) + "\n" + close_tag, template)
    # 替换 JS script src
    for name, open_tag, close_tag in VENDOR_JS:
        pattern = re.compile(
            r'<script[^>]*src="%s"[^>]*>\s*</script>' % re.escape(name), re.IGNORECASE)
        template = pattern.sub(
            lambda _: open_tag + "\n" + load(name) + "\n" + close_tag, template)
    return template


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    with open(TEMPLATE, "r", encoding="utf-8") as f:
        template = f.read()
    html = inline(template)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)
    print("✓ 已生成 %s (%.1f KB)" % (args.out, os.path.getsize(args.out) / 1024))


if __name__ == "__main__":
    main()
