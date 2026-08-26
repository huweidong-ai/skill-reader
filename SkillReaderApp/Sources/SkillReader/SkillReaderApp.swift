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

    var body: some Scene {
        WindowGroup("Skill Reader") {
            rootView
                .tint(Color.srAccent)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("显示 / 隐藏大纲") {
                    state.tocVisible.toggle()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button(state.sourceMode ? "阅读模式" : "源码模式") {
                    state.toggleSourceMode()
                }
                .keyboardShortcut("/", modifiers: .command)

                Button("返回主文档") {
                    state.backToEntry()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            // 文档操作（飞书风格：编辑 + 分享）
            CommandGroup(replacing: .newItem) {
                Button("在编辑器中打开") {
                    state.openInEditor()
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("分享…") {
                    state.shareActive()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // 技能库管理（替代侧栏顶部的工具按钮组，与 编辑/显示/窗口 并列）
            CommandMenu("技能库") {
                Button("搜索…") {
                    // 由 SidebarView 响应，这里只触发状态切换
                    NotificationCenter.default.post(name: .skillReaderToggleSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Menu("切换根目录") {
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

                Button("刷新技能列表") {
                    state.reloadSkills()
                    state.flashToast("已刷新")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("同步：分发到已启用平台") {
                    state.syncDistribution()
                }

                Divider()

                Button("添加技能库目录…") {
                    let panel = NSOpenPanel()
                    panel.title = "选择技能库根目录"
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "添加"
                    if panel.runModal() == .OK, let url = panel.url {
                        state.store.addRoot(path: url.path)
                        state.switchRoot(id: state.store.currentRootID ?? "")
                        state.flashToast("已添加技能库")
                    }
                }

                Button("配置 Agent…") {
                    state.reopenSetup()
                }

                Divider()

                Menu("主题") {
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
