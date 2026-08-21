import Foundation

// MARK: - 资源定位
// SPM 的 Bundle.module 在 .app 打包后会 fatalError（accessor 期望 bundle 在
// .app 根目录，而 build_app.sh 把它放在 Contents/Resources/）。
// 这里多路径探测，两种环境都兼容；不再兜底 Bundle.module。
//   1) 裸可执行（swift build 调试）: bundle 与可执行文件同级
//   2) .app 打包: bundle 在 Contents/Resources/

enum SkillReaderResources {
    /// 自包含 render.html 的 URL（找不到返回 nil）
    static func renderHTMLURL() -> URL? {
        let name = "SkillReader_SkillReader.bundle"

        // 1. 可执行文件同级（SPM debug/release 裸跑）
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidate = exeDir.appendingPathComponent(name).appendingPathComponent("render.html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // 2. .app 的 Contents/Resources/
        if let resDir = Bundle.main.resourceURL {
            let candidate = resDir.appendingPathComponent(name).appendingPathComponent("render.html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
