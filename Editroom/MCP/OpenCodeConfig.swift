import Foundation

/// Small, formatting-preserving editor for OpenCode's JSON/JSONC config. OpenCode 1 keeps servers
/// directly under `mcp`; OpenCode 2 puts them under `mcp.servers`. Only Editroom's property is changed,
/// so comments, other servers and the person's formatting are left alone.
enum OpenCodeConfig {
    struct ConfigError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Token {
        enum Kind {
            case objectStart, objectEnd, arrayStart, arrayEnd, colon, comma
            case string(String)
            case scalar(String)
        }
        let kind: Kind
        let range: Range<String.Index>
    }

    private struct Property {
        let key: String
        let keyRange: Range<String.Index>
        let value: Node
        /// The comma after this property, if there is one (including a trailing comma).
        let comma: Range<String.Index>?
    }

    private struct Node {
        let range: Range<String.Index>
        let closingBrace: String.Index?
        let properties: [Property]
        let trailingComma: Bool
        let array: [Node]?
        let scalar: Any?

        var object: [String: Node]? {
            guard closingBrace != nil else { return nil }
            var out: [String: Node] = [:]
            for p in properties { out[p.key] = p.value }
            return out
        }

        var foundationValue: Any {
            if let object { return object.mapValues(\.foundationValue) }
            if let array { return array.map(\.foundationValue) }
            return scalar ?? NSNull()
        }
    }

    private final class Parser {
        let tokens: [Token]
        private var index = 0

        init(_ text: String) throws {
            self.tokens = Self.scan(text)
        }

        func parse() throws -> Node {
            guard !tokens.isEmpty else { throw ConfigError(message: "OpenCode's config is empty.") }
            let node = try value()
            guard index == tokens.count else { throw ConfigError(message: "OpenCode's config isn't valid JSON or JSONC.") }
            return node
        }

        private func value() throws -> Node {
            guard index < tokens.count else { throw ConfigError(message: "OpenCode's config isn't valid JSON or JSONC.") }
            let token = tokens[index]
            switch token.kind {
            case .objectStart:
                index += 1
                var properties: [Property] = []
                var trailingComma = false
                if index < tokens.count, case .objectEnd = tokens[index].kind {
                    let end = tokens[index].range
                    index += 1
                    return Node(range: token.range.lowerBound..<end.upperBound, closingBrace: end.lowerBound,
                                properties: [], trailingComma: false, array: nil, scalar: nil)
                }
                while true {
                    guard index < tokens.count, case .string(let key) = tokens[index].kind else {
                        throw ConfigError(message: "OpenCode's config has an invalid object.")
                    }
                    let keyRange = tokens[index].range
                    index += 1
                    guard index < tokens.count, case .colon = tokens[index].kind else {
                        throw ConfigError(message: "OpenCode's config has an invalid property.")
                    }
                    index += 1
                    let child = try value()
                    var comma: Range<String.Index>?
                    if index < tokens.count, case .comma = tokens[index].kind {
                        comma = tokens[index].range
                        index += 1
                    }
                    properties.append(Property(key: key, keyRange: keyRange, value: child, comma: comma))
                    if index < tokens.count, case .objectEnd = tokens[index].kind {
                        trailingComma = comma != nil
                        let end = tokens[index].range
                        index += 1
                        return Node(range: token.range.lowerBound..<end.upperBound, closingBrace: end.lowerBound,
                                    properties: properties, trailingComma: trailingComma, array: nil, scalar: nil)
                    }
                    guard comma != nil else { throw ConfigError(message: "OpenCode's config is missing a comma.") }
                }
            case .arrayStart:
                index += 1
                var values: [Node] = []
                if index < tokens.count, case .arrayEnd = tokens[index].kind {
                    let end = tokens[index].range
                    index += 1
                    return Node(range: token.range.lowerBound..<end.upperBound, closingBrace: nil,
                                properties: [], trailingComma: false, array: values, scalar: nil)
                }
                while true {
                    values.append(try value())
                    if index < tokens.count, case .comma = tokens[index].kind { index += 1; continue }
                    guard index < tokens.count, case .arrayEnd = tokens[index].kind else {
                        throw ConfigError(message: "OpenCode's config has an invalid array.")
                    }
                    let end = tokens[index].range
                    index += 1
                    return Node(range: token.range.lowerBound..<end.upperBound, closingBrace: nil,
                                properties: [], trailingComma: false, array: values, scalar: nil)
                }
            case .string(let string):
                index += 1
                return Node(range: token.range, closingBrace: nil, properties: [], trailingComma: false, array: nil, scalar: string)
            case .scalar(let raw):
                index += 1
                guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else {
                    throw ConfigError(message: "OpenCode's config has an invalid value.")
                }
                return Node(range: token.range, closingBrace: nil, properties: [], trailingComma: false, array: nil, scalar: value)
            default:
                throw ConfigError(message: "OpenCode's config isn't valid JSON or JSONC.")
            }
        }

        private static func scan(_ text: String) -> [Token] {
            var tokens: [Token] = []
            var i = text.startIndex
            func isSpace(_ c: Character) -> Bool { c.isWhitespace || c.isNewline }
            func isPunctuation(_ c: Character) -> Bool { "{}[]:,".contains(c) }
            while i < text.endIndex {
                if isSpace(text[i]) { i = text.index(after: i); continue }
                if text[i] == "/", text.index(after: i) < text.endIndex {
                    let next = text[text.index(after: i)]
                    if next == "/" {
                        i = text.index(after: text.index(after: i))
                        while i < text.endIndex, !text[i].isNewline { i = text.index(after: i) }
                        continue
                    }
                    if next == "*" {
                        i = text.index(after: text.index(after: i))
                        var closed = false
                        while i < text.endIndex {
                            if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                                i = text.index(after: text.index(after: i)); closed = true; break
                            }
                            i = text.index(after: i)
                        }
                        if !closed { break }
                        continue
                    }
                }
                let start = i
                let c = text[i]
                if isPunctuation(c) {
                    i = text.index(after: i)
                    let kind: Token.Kind
                    switch c {
                    case "{": kind = .objectStart
                    case "}": kind = .objectEnd
                    case "[": kind = .arrayStart
                    case "]": kind = .arrayEnd
                    case ":": kind = .colon
                    default: kind = .comma
                    }
                    tokens.append(Token(kind: kind, range: start..<i))
                } else if c == "\"" {
                    i = text.index(after: i)
                    var escaped = false
                    while i < text.endIndex {
                        let d = text[i]
                        i = text.index(after: i)
                        if escaped { escaped = false; continue }
                        if d == "\\" { escaped = true; continue }
                        if d == "\"" { break }
                    }
                    let raw = String(text[start..<i])
                    let string = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? String ?? ""
                    tokens.append(Token(kind: .string(string), range: start..<i))
                } else {
                    while i < text.endIndex, !isSpace(text[i]), !isPunctuation(text[i]) {
                        if text[i] == "/", text.index(after: i) < text.endIndex,
                           text[text.index(after: i)] == "/" || text[text.index(after: i)] == "*" { break }
                        i = text.index(after: i)
                    }
                    tokens.append(Token(kind: .scalar(String(text[start..<i])), range: start..<i))
                }
            }
            return tokens
        }
    }

    private static func path(_ major: Int) -> [String] {
        major >= 2 ? ["mcp", "servers", "editroom"] : ["mcp", "editroom"]
    }

    private static func parse(_ text: String) throws -> Node {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return try Parser("{}").parse() }
        return try Parser(text).parse()
    }

    private static func node(_ path: [String], in root: Node) -> Node? {
        var node = root
        for key in path {
            guard let next = node.object?[key] else { return nil }
            node = next
        }
        return node
    }

    static func serverPresent(_ text: String, major: Int) -> Bool {
        guard let root = try? parse(text), let server = node(path(major), in: root) else { return false }
        if major >= 2 {
            if let disabled = server.object?["disabled"]?.scalar as? Bool, disabled { return false }
        } else if let enabled = server.object?["enabled"]?.scalar as? Bool, !enabled {
            return false
        }
        return true
    }

    static func jsonObject(_ text: String) throws -> Any {
        try parse(text).foundationValue
    }

    /// Adds or replaces Editroom's server. `serverJSON` is a complete JSON object.
    static func settingServer(_ serverJSON: String, in text: String, major: Int) throws -> String {
        guard let data = serverJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw ConfigError(message: "Couldn't write OpenCode's MCP settings.")
        }
        let value = String(decoding: compact, as: UTF8.self)
        let root = try parse(text)
        return try setting(value, at: path(major), in: text, root: root)
    }

    static func removingServer(from text: String, major: Int) -> String {
        guard let root = try? parse(text), let parent = node(Array(path(major).dropLast()), in: root),
              let index = parent.properties.firstIndex(where: { $0.key == "editroom" }) else { return text }
        let property = parent.properties[index]
        var remove: Range<String.Index>
        if index < parent.properties.count - 1 {
            remove = property.keyRange.lowerBound..<(property.comma?.upperBound ?? property.value.range.upperBound)
        } else if let comma = property.comma {
            // Last property, with a trailing comma. Take its comma too; if there is a previous
            // property, that property's own comma is left behind as a valid trailing comma.
            remove = property.keyRange.lowerBound..<comma.upperBound
        } else if index > 0, let comma = parent.properties[index - 1].comma {
            remove = comma.lowerBound..<property.value.range.upperBound
        } else {
            remove = property.keyRange.lowerBound..<property.value.range.upperBound
        }
        return text.replacingCharacters(in: remove, with: "")
    }

    private static func setting(_ value: String, at path: [String], in text: String, root: Node) throws -> String {
        guard let key = path.last else { throw ConfigError(message: "Couldn't write OpenCode's MCP settings.") }
        let parentPath = Array(path.dropLast())
        let quotedKey = String(decoding: try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]), as: UTF8.self)
        if let parent = node(parentPath, in: root) {
            guard let close = parent.closingBrace else { throw ConfigError(message: "OpenCode's MCP settings aren't an object.") }
            if let property = parent.properties.first(where: { $0.key == key }) {
                return text.replacingCharacters(in: property.value.range, with: value)
            }
            let body = text[parent.range.lowerBound..<close]
            let multiline = body.contains("\n") || body.contains("\r")
            let needsComma = !parent.properties.isEmpty && !parent.trailingComma
            let insertion: String
            if multiline {
                let lineStart = text[..<close].lastIndex(where: { $0.isNewline }).map(text.index(after:)) ?? text.startIndex
                let closingIndent = String(text[lineStart..<close].filter { $0 == " " || $0 == "\t" })
                let childIndent = closingIndent + "  "
                insertion = "\n\(childIndent)\(quotedKey): \(value)\n\(closingIndent)"
            } else {
                insertion = "\(quotedKey):\(value)"
            }
            if needsComma, let last = parent.properties.last {
                let tail = text[last.value.range.upperBound..<close]
                return text.replacingCharacters(in: last.value.range.upperBound..<close, with: "," + tail + insertion)
            }
            return text.replacingCharacters(in: close..<close, with: insertion)
        }

        // An intermediate object is missing. Find the deepest existing ancestor and add the rest as one value.
        var existing = 0
        while existing < parentPath.count, node(Array(parentPath.prefix(existing + 1)), in: root) != nil { existing += 1 }
        var nested = "{\(quotedKey):\(value)}"
        for part in parentPath.dropFirst(existing + 1).reversed() {
            let quoted = String(decoding: try JSONSerialization.data(withJSONObject: part, options: [.fragmentsAllowed]), as: UTF8.self)
            nested = "{\(quoted):\(nested)}"
        }
        return try setting(nested, at: Array(parentPath.prefix(existing)) + [parentPath[existing]], in: text, root: root)
    }
}
