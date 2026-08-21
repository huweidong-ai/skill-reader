import Foundation

// MARK: - 文件类型分类

enum FileKind: String {
    case md, code, yaml, json, toml, text, img, pdf, bin

    var icon: String {
        switch self {
        case .md: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .yaml, .json, .toml: return "gearshape"
        case .text: return "doc.plaintext"
        case .img: return "photo"
        case .pdf: return "book"
        case .bin: return "questionmark.folder"
        }
    }
}

// MARK: - 文件树节点

final class FileNode: Identifiable {
    let name: String
    var path: String          // 相对 skill 包的路径
    let isDir: Bool
    let kind: FileKind
    let size: Int
    let sizeHuman: String
    let lang: String?
    var children: [FileNode]

    var id: String { path }
    var isEntry: Bool = false

    init(name: String, path: String, isDir: Bool, kind: FileKind = .bin,
         size: Int = 0, sizeHuman: String = "", lang: String? = nil,
         children: [FileNode] = []) {
        self.name = name
        self.path = path
        self.isDir = isDir
        self.kind = kind
        self.size = size
        self.sizeHuman = sizeHuman
        self.lang = lang
        self.children = children
    }
}

// MARK: - 文件内容

struct FileContent {
    let name: String
    let path: String
    let kind: FileKind
    let size: Int
    let sizeHuman: String
    let lang: String?
    let content: String?
    let tooLarge: Bool
}
