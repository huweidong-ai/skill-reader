import Foundation

/// 中英双语。
///
/// **为什么不用 `.strings` / `NSLocalizedString`：** 本项目用 SPM 构建，
/// `build_app.sh` 手工组装 `.app` bundle。`.lproj` 资源要经
/// `Bundle.module` 才能取到，而手工组包时资源路径和 SPM 的预期不一致，
/// 极易变成「开发时能取到、打包后静默回落到 key」—— 那正是这个项目
/// 最忌讳的假成功。纯 Swift 函数在编译期就绑定，取不到就编译不过。
///
/// 用法：`L10n.t("中文", "English")`。
enum L10n {

    enum Language: String, CaseIterable, Codable, Identifiable {
        case system
        case zhHans
        case en

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return L10n.t("跟随系统", "System")
            case .zhHans: return "简体中文"
            case .en:     return "English"
            }
        }
    }

    /// 用户在「语言」菜单里选的语言。AppState 会监听 UserDefaults 变化并推送
    /// objectWillChange，因此切换后主窗口文案会立即全量刷新（菜单栏
    /// 标题随 @StateObject 变化同步刷新）。
    static var override: Language {
        get {
            guard let raw = UserDefaults.standard.string(forKey: overrideKey),
                  let lang = Language(rawValue: raw)
            else { return .system }
            return lang
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: overrideKey)
        }
    }

    private static let overrideKey = "skillreader.language"

    /// 当前是否用中文。
    ///
    /// `system` 时读 `Locale.preferredLanguages` 而非
    /// `Locale.current.language` —— 后者在没有本地化资源的 app 里
    /// 总是回落到开发语言，拿不到用户真实的系统语言设置。
    static var isChinese: Bool {
        switch override {
        case .zhHans: return true
        case .en:     return false
        case .system:
            guard let first = Locale.preferredLanguages.first?.lowercased() else { return false }
            return first.hasPrefix("zh")
        }
    }

    /// 按当前语言取一条文案。
    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    /// 英文单复数。中文没有复数变化，所以中文侧只取一个词。
    ///
    /// 不做这个的话会输出 "1 items"、"1 groups" 这种明显的机翻痕迹 ——
    /// 对一个要建立信任的工具来说，这种小破绽很伤。
    static func plural(_ n: Int, zh: String, one: String, many: String) -> String {
        isChinese ? "\(n) \(zh)" : "\(n) \(n == 1 ? one : many)"
    }
}
