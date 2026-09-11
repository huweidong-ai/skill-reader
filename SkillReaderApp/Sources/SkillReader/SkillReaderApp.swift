import SwiftUI
import AppKit

// MARK: - 全局通知名
extension Notification.Name {
    /// 切换搜索框展开/折叠（⌘F 触发）
    static let skillReaderToggleSearch = Notification.Name("skillReaderToggleSearch")
}

// MARK: - 品牌强调色（现代靛蓝，深浅模式自动适配）

extension Color {
    /// 品牌强调色：浅色 #007AFF / 深色 #0A84FF（macOS 系统蓝，跟随系统外观）
    static let srAccent = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 1)   // #0A84FF
            : NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)     // #007AFF
    })
    /// 强调色柔和底色（选中 / 高亮背景）
    static let srAccentSoft = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.16)
            : NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 0.10)
    })
    /// 操作成功 / 已安装等状态绿
    static let srSuccess = Color(nsColor: .systemGreen)
}

@main
struct SkillReaderApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--self-test") {
            exit(SelfTest.run())
        }
        if args.contains("--render-smoke") {
            // 同步执行：与最小测试一致，由 RenderSmoke 自己驱动 runloop。
            // 若走 asyncAfter，SwiftUI 主 runloop 已接管，嵌套 RunLoop.main.run 会收不到加载回调。
            exit(RenderSmoke.run())
        }
    }

    /// 语言菜单绑定：读写 L10n.override（落到 UserDefaults），AppState 监听
    /// UserDefaults 变化推送 objectWillChange，切换后界面即时全量刷新。
    private var languageBinding: Binding<L10n.Language> {
        Binding(
            get: { L10n.override },
            set: { L10n.override = $0 }
        )
    }

    var body: some Scene {
        WindowGroup("Skill Reader") {
            rootView
                .tint(Color.srAccent)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .sidebar) {
                Button(L10n.t("显示 / 隐藏大纲", "Show / Hide Outline")) {
                    state.tocVisible.toggle()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(state.sourceMode ? L10n.t("阅读模式", "Reading Mode") : L10n.t("源码模式", "Source Mode")) {
                    state.toggleSourceMode()
                }
                .keyboardShortcut("/", modifiers: .command)

                Button(L10n.t("返回主文档", "Back to Main Doc")) {
                    state.backToEntry()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            // 文档操作（飞书风格：编辑 + 分享）
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("在编辑器中打开", "Open in Editor")) {
                    state.openInEditor()
                }
                .keyboardShortcut("e", modifiers: .command)

                Button(L10n.t("分享…", "Share…")) {
                    state.shareActive()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // 复制文件到剪贴板（⌘C）：把选中的文件/文件夹作为文件承诺写入剪贴板，
            // 可粘贴到 Finder、聊天窗口、邮件等支持文件粘贴的目标；焦点在网页正文 / 文本框时走系统文字复制。
            CommandGroup(replacing: .pasteboard) {
                Button(L10n.t("剪切", "Cut")) {
                    state.cutActive()
                }
                .keyboardShortcut("x", modifiers: .command)

                Button(L10n.t("复制", "Copy")) {
                    state.copyActiveFile()
                }
                .keyboardShortcut("c", modifiers: .command)

                Button(L10n.t("粘贴", "Paste")) {
                    state.forwardEdit(#selector(NSText.paste(_:)))
                }
                .keyboardShortcut("v", modifiers: .command)

                // 网页正文 / 文本框内 ⌘A 全选（WKWebView 与 NSText 实现 selectAll:），
                // 焦点在文件树 / 工具栏时不拦截，避免误触。
                Button(L10n.t("全选", "Select All")) {
                    state.forwardEdit(#selector(NSText.selectAll(_:)))
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            // 设置（替代侧栏顶部的工具按钮组，与 编辑/显示/窗口 并列）
            CommandMenu(L10n.t("设置", "Settings")) {
                Button(L10n.t("搜索…", "Search…")) {
                    // 由 SidebarView 响应，这里只触发状态切换
                    NotificationCenter.default.post(name: .skillReaderToggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button(L10n.t("重新加载技能", "Reload Skills")) {
                    state.reloadSkills()
                    state.flashToast(L10n.t("已刷新", "Refreshed"))
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L10n.t("配置 skill 源", "Configure Skill Sources")) {
                    state.reopenSetup()
                }
                .keyboardShortcut(",", modifiers: .command)

                Button(L10n.t("同步分发到已启用智能体", "Sync Distribute to Enabled Agents")) {
                    state.syncDistribution()
                }

                Divider()

                Menu(L10n.t("主题", "Theme")) {
                    ForEach(ThemeMode.allCases) { mode in
                        Button {
                            state.setTheme(mode)
                        } label: {
                            if state.theme == mode {
                                Text(mode.label + " ✓")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }

                Menu(L10n.t("语言", "Language")) {
                    ForEach(L10n.Language.allCases) { lang in
                        Button {
                            L10n.override = lang
                        } label: {
                            if L10n.override == lang {
                                Text(lang.displayName + " ✓")
                            } else {
                                Text(lang.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if CommandLine.arguments.contains("--render-smoke") {
            // smoke 模式：不创建 ContentView（避免与测试 WebView 冲突）
            EmptyView().frame(width: 1, height: 1)
        } else if state.needsSetup || CommandLine.arguments.contains("--force-setup") {
            // --force-setup：开发自验用，直接拉起配置页（不写配置、不重建 ~/.agent）
            AgentSetupView()
                .environmentObject(state)
                .frame(minWidth: 780, minHeight: 560)
        } else {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 860, minHeight: 560)
        }
    }
}
