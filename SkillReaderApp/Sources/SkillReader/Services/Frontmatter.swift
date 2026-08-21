import Foundation

// MARK: - YAML frontmatter 轻量解析（对齐 web 版 server.py 行为）

enum Frontmatter {
    struct Result {
        var dict: [String: FMValue] = [:]
        var body: String
    }

    /// 与 server.py 一致: 解析首部 --- 块, 返回 (dict, 正文)
    static func parse(_ content: String) -> Result {
        var result = Result(body: content)
        // 匹配 ^---\n ... \n---\n?
        var start = content.startIndex
        guard content.hasPrefix("---") else { return result }
        let afterFirst = content.index(content.startIndex, offsetBy: 3)
        // 第一行必须是以 --- 开头后紧跟换行
        guard afterFirst < content.endIndex,
              content[afterFirst] == "\n" || content[afterFirst] == "\r" else {
            return result
        }
        start = afterFirst
        // 找到结尾的 --- 行
        var end: String.Index?
        var bodyStart = content.endIndex
        var searchStart = start
        while searchStart < content.endIndex {
            guard let nl = content.range(of: "\n", range: searchStart..<content.endIndex) else { break }
            var lineStart = nl.upperBound
            // 处理 \r\n: nl.lowerBound 是 \n, 检查前面是否有 \r
            if nl.lowerBound > content.startIndex {
                let prev = content.index(before: nl.lowerBound)
                if content[prev] == "\r" { lineStart = nl.upperBound }
            }
            let lineEnd = content.range(of: "\n", range: lineStart..<content.endIndex)?.lowerBound ?? content.endIndex
            let line = String(content[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
            if line == "---" {
                end = lineStart
                // body 从 "---" 行之后的换行开始
                var b = lineEnd
                if b < content.endIndex, content[b] == "\r" { b = content.index(after: b) }
                if b < content.endIndex, content[b] == "\n" { b = content.index(after: b) }
                bodyStart = b
                break
            }
            searchStart = lineEnd
        }
        guard let endIdx = end else { return result }

        let fmText = String(content[start..<endIdx])

        result.dict = parseBody(fmText)
        result.body = String(content[bodyStart...])
        return result
    }

    private static func parseBody(_ text: String) -> [String: FMValue] {
        var dict: [String: FMValue] = [:]
        var key: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let m = line.range(of: #"^([A-Za-z_][\w-]*):\s*(.*)$"#, options: .regularExpression) {
                let parts = line[m].split(separator: ":", maxSplits: 1)
                key = String(parts[0])
                let val = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
                dict[key!] = .scalar(scalar(val))
            } else if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t"), line.trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                let itemText = line.trimmingCharacters(in: .whitespaces)
                let item = scalar(String(itemText.dropFirst().trimmingCharacters(in: .whitespaces)))
                if case .array(var arr)? = dict[k] {
                    arr.append(.scalar(item))
                    dict[k] = .array(arr)
                } else if let existing = dict[k], case .scalar = existing {
                    dict[k] = .array([existing, .scalar(item)])
                } else {
                    dict[k] = .array([.scalar(item)])
                }
            } else if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t"),
                      line.range(of: #"^\s{2,}[\w-]+:"#, options: .regularExpression) != nil {
                // 嵌套 map: 保留为原始行文本
                if case .scalar(let s)? = dict[k] {
                    dict[k] = .scalar("\(s.base)\n" + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return dict
    }

    private static func scalar(_ v: String) -> AnyHashable {
        if v.isEmpty { return "" }
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        if v == "true" { return true }
        if v == "false" { return false }
        if v.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            if v.contains(".") { return Double(v) ?? 0 }
            return Int(v) ?? 0
        }
        return v
    }
}

enum FMValue: Equatable {
    case scalar(AnyHashable)
    case array([FMValue])

    var stringValue: String {
        switch self {
        case .scalar(let v):
            if let b = v as? Bool { return b ? "true" : "false" }
            return String(describing: v)
        case .array(let arr):
            return arr.map { $0.stringValue }.joined(separator: "、")
        }
    }

    var raw: Any {
        switch self {
        case .scalar(let v): return v.base
        case .array(let arr): return arr.map { $0.raw }
        }
    }
}
