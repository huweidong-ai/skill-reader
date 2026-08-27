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

            // 技能库管理（替代侧栏顶部的工具按钮组，与 编辑/显示/窗口 并列）
            CommandMenu(L10n.t("技能库", "Skill Library")) {
                Button(L10n.t("搜索…", "Search…")) {
                    // 由 SidebarView 响应，这里只触发状态切换
                    NotificationCenter.default.post(name: .skillReaderToggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Menu(L10n.t("切换根目录", "Switch Root")) {
                    ForEach(state.store.roots) { root in
                        Button {
                            state.switchRoot(id: root.id)
                        } label: {
                            // 当前选中项加勾标记
                            if root.id == state.store.currentRootID {
                                Text(root.name + " ✓")
                            } else {
                                Text(root.name)
                            }
                        }
                    }
                }

                Button(L10n.t("刷新技能列表", "Refresh Skill List")) {
                    state.reloadSkills()
                    state.flashToast(L10n.t("已刷新", "Refreshed"))
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(L10n.t("同步：分发到已启用平台", "Sync: Distribute to Enabled Platforms")) {
                    state.syncDistribution()
                }

                Divider()

                Button(L10n.t("添加技能库目录…", "Add Skill Library…")) {
                    let panel = NSOpenPanel()
                    panel.title = L10n.t("选择技能库根目录", "Choose Skill Library Root")
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = L10n.t("添加", "Add")
                    if panel.runModal() == .OK, let url = panel.url {
                        state.store.addRoot(path: url.path)
                        state.switchRoot(id: state.store.currentRootID ?? "")
                        state.flashToast(L10n.t("已添加技能库", "Skill library added"))
                    }
                }

                Button(L10n.t("配置 Agent", "Configure Agent")) {
                    state.reopenSetup()
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
        } else if state.needsSetup {
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
