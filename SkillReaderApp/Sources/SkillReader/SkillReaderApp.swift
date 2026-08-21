import SwiftUI

@main
struct SkillReaderApp: App {
    @StateObject private var state = AppState()

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
            if CommandLine.arguments.contains("--render-smoke") {
                // smoke 模式：不创建 ContentView（避免与测试 WebView 冲突）
                EmptyView().frame(width: 1, height: 1)
            } else {
                ContentView()
                    .environmentObject(state)
                    .frame(minWidth: 860, minHeight: 560)
            }
        }
        .windowResizability(.contentMinSize)
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

            CommandMenu("技能库") {
                Button("刷新技能列表") {
                    state.reloadSkills()
                    state.flashToast("已刷新")
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("添加技能库目录…") {
                    addRootViaPanel()
                }

                Menu("当前技能库") {
                    ForEach(state.store.roots) { root in
                        Button {
                            state.switchRoot(id: root.id)
                        } label: {
                            HStack {
                                Text(root.path).lineLimit(1)
                                if state.store.currentRootID == root.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
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
        }
    }

    private func addRootViaPanel() {
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
}
