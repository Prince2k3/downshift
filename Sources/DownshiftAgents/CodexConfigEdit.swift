import Foundation

/// Edits to `~/.codex/config.toml`, done as text so comments, ordering and formatting the
/// user (or the Codex app) wrote are never rewritten. Everything dshift adds sits between marker
/// comments, and `disable` removes exactly those lines.
///
/// Two blocks are added:
/// - a `[model_providers.downshift]` provider, appended at the end;
/// - optionally `model_provider = "downshift"` among the top-level keys, which makes it the default.
///   The Codex app can't be given flags, so this is how app users route. (A top-level
///   `profile = "..."` is not an option: codex 0.155 rejects it as legacy and the app then fails
///   to load its config at all.) CLI users can instead pass `-c model_provider=downshift`.
public enum CodexConfigEdit {
    public static let beginMarker = "# >>> dshift apps: managed by dshift, remove with `dshift apps disable --codex` >>>"
    public static let endMarker = "# <<< dshift apps <<<"

    public static func tablesBlock(baseURL: String) -> [String] {
        [
            beginMarker,
            "[model_providers.downshift]",
            "name = \"Jev Router\"",
            "base_url = \"\(baseURL)\"",
            "wire_api = \"responses\"",
            "requires_openai_auth = true",
            endMarker,
        ]
    }

    public static let defaultProviderBlock = [beginMarker, "model_provider = \"downshift\"", endMarker]

    public struct Previous: Sendable, Equatable {
        /// `enable` had to add a final newline before appending; `disable` takes it back off.
        public var addedFinalNewline: Bool
    }

    public static func enable(_ data: Data?, baseURL: String, defaultProvider: Bool) throws -> (Data, Previous) {
        guard !baseURL.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
            throw AppsError("base URL must not contain quotes, backslashes or newlines")
        }
        let text = try decode(data)
        var lines = splitLines(text)
        if lines.contains(where: { $0 == beginMarker }) {
            throw AppsError("config.toml already has a dshift block; run `dshift apps disable --codex` first")
        }
        if let existing = downshiftProviderDefinition(lines) {
            throw AppsError("config.toml already defines `\(existing)` outside dshift's block; rename or remove it first")
        }

        let firstTable = firstTableHeaderIndex(lines)
        if defaultProvider {
            let topLevel = statements(lines).prefix { !$0.isHeader }
            if let existing = topLevel.first(where: { topLevelKey($0.content) == "model_provider" }) {
                throw AppsError("config.toml already sets a default provider (`\(existing.content)`); use --no-codex-default-provider, or remove it first")
            }
        }

        let addedFinalNewline = !text.isEmpty && !text.hasSuffix("\n")
        // `splitLines` leaves an empty final element for a trailing newline; drop it while editing.
        if lines.last == "" { lines.removeLast() }
        lines.append(contentsOf: tablesBlock(baseURL: baseURL))
        if defaultProvider {
            lines.insert(contentsOf: defaultProviderBlock, at: firstTable ?? 0)
        }
        return (Data((lines.joined(separator: "\n") + "\n").utf8), Previous(addedFinalNewline: addedFinalNewline))
    }

    public static func disable(_ data: Data, previous: Previous) throws -> Data {
        let text = try decode(data)
        var output: [String] = []
        var inside = false
        for line in splitLines(text) {
            if line == beginMarker {
                guard !inside else { throw AppsError("config.toml has a nested dshift begin marker; remove the dshift block by hand") }
                inside = true
            } else if line == endMarker {
                guard inside else { throw AppsError("config.toml has a dshift end marker without a begin marker; remove it by hand") }
                inside = false
            } else if !inside {
                output.append(line)
            }
        }
        guard !inside else { throw AppsError("config.toml has an unterminated dshift block; remove it by hand") }
        var result = output.joined(separator: "\n")
        if previous.addedFinalNewline, result.hasSuffix("\n") { result.removeLast() }
        return Data(result.utf8)
    }

    public static func isEnabled(_ data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        return splitLines(text).contains(beginMarker)
    }

    public static func hasDefaultProvider(_ data: Data?) -> Bool {
        guard let data, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = splitLines(text)
        guard let begin = lines.firstIndex(of: beginMarker) else { return false }
        return lines.indices.contains(begin + 1) && lines[begin + 1] == defaultProviderBlock[1]
    }

    static func decode(_ data: Data?) throws -> String {
        guard let data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else { throw AppsError("config.toml is not UTF-8") }
        return text
    }

    /// Splits on `\n` only, keeping `\r` in place so CRLF files round-trip.
    static func splitLines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// One line as TOML sees it: `content` has the comment dropped and is empty for a line that
    /// continues a multi-line value (inside a `"""` string or a multi-line array or inline
    /// table), since such a line can't be a header or a key.
    struct Statement {
        var index: Int
        var content: String
        var isHeader: Bool { content.hasPrefix("[") }
    }

    /// Walks `lines` with enough of a TOML lexer to skip the insides of multi-line strings and
    /// of multi-line arrays (a top-level `notify = [` … `]` has lines that are not headers).
    /// Headers balance their own brackets, so counting every bracket outside strings works.
    static func statements(_ lines: [String]) -> [Statement] {
        var result: [Statement] = []
        var depth = 0
        var multiline: Substring?
        for (index, raw) in lines.enumerated() {
            let continuing = depth > 0 || multiline != nil
            var content = ""
            var quote: Character?
            var escaped = false
            var position = raw.startIndex
            scan: while position < raw.endIndex {
                let rest = raw[position...]
                let character = raw[position]
                var step = 1
                if let delimiter = multiline {
                    if escaped {
                        escaped = false
                    } else if delimiter.first == "\"" && character == "\\" {
                        escaped = true
                    } else if rest.hasPrefix(delimiter) {
                        multiline = nil
                        step = 3
                        // `""""` ends the string with one quote inside it: skip the extra quotes.
                        var after = raw.index(position, offsetBy: 3)
                        while after < raw.endIndex, raw[after] == delimiter.first, step < 5 {
                            after = raw.index(after: after)
                            step += 1
                        }
                    }
                } else if let open = quote {
                    if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                } else if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                    multiline = rest.prefix(3)
                    step = 3
                } else {
                    switch character {
                    case "#": break scan
                    case "\"", "'": quote = character
                    case "[", "{": depth += 1
                    case "]", "}": depth = max(0, depth - 1)
                    default: break
                    }
                }
                let next = raw.index(position, offsetBy: step)
                if !continuing { content += raw[position..<next] }
                position = next
            }
            result.append(Statement(index: index, content: continuing ? "" : content.trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// Index of the first `[table]` / `[[array]]` header, indented or not.
    static func firstTableHeaderIndex(_ lines: [String]) -> Int? {
        statements(lines).first(where: \.isHeader)?.index
    }

    static func topLevelKey(_ line: String) -> String? {
        let content = stripComment(line)
        guard let equals = content.firstIndex(of: "=") else { return nil }
        let key = content[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// A dotted key or header path, unquoted: `a."b.c" . d` is `["a", "b.c", "d"]`.
    static func keyPath(_ text: some StringProtocol) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// The path of a `[table]` or `[[array]]` header; nil for anything else.
    static func headerPath(_ content: String) -> [String]? {
        guard content.hasPrefix("["), content.hasSuffix("]") else { return nil }
        let inner = content.hasPrefix("[[") && content.hasSuffix("]]")
            ? content.dropFirst(2).dropLast(2) : content.dropFirst().dropLast()
        return keyPath(inner)
    }

    static func isTableHeader(_ line: String, named path: [String]) -> Bool {
        let content = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard !content.hasPrefix("[[") else { return false }
        return headerPath(content) == path
    }

    /// Where the config already defines `model_providers.downshift`, in any TOML spelling: a
    /// `[model_providers.downshift]` header (or a subtable of it), a dotted key such as
    /// `model_providers.downshift.name = …`, or an inline table `downshift = { … }` under
    /// `[model_providers]` or inside `model_providers = { … }`.
    static func downshiftProviderDefinition(_ lines: [String]) -> String? {
        let target = ["model_providers", "downshift"]
        var table: [String] = []
        for statement in statements(lines) where !statement.content.isEmpty {
            let content = statement.content
            if let path = headerPath(content) {
                table = path
                if path.starts(with: target) { return content }
                continue
            }
            guard let equals = content.firstIndex(of: "=") else { continue }
            let full = table + keyPath(content[..<equals])
            if full.starts(with: target) { return content }
            if full == ["model_providers"],
               content[content.index(after: equals)...].range(of: #"[{,]\s*["']?downshift["']?\s*[.=]"#,
                                                              options: .regularExpression) != nil {
                return content
            }
        }
        return nil
    }

    /// Drops a `#` comment that is not inside a string.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character } else if character == "#" { return String(line[..<index]) }
        }
        return line
    }
}

extension CodexConfigEdit {
    /// A top-level string key (before the first table), e.g. `model`. Read only.
    public static func topLevelString(_ data: Data?, key: String) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        for statement in statements(splitLines(text)).prefix(while: { !$0.isHeader }) where topLevelKey(statement.content) == key {
            let content = statement.content
            guard let equals = content.firstIndex(of: "=") else { continue }
            let value = content[content.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    /// A string key inside one `[a.b]` table, e.g. `model` in `[profiles.work]`. Read only.
    public static func tableString(_ data: Data?, table path: [String], key: String) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        var inside = false
        for statement in statements(splitLines(text)) {
            let trimmed = statement.content
            if statement.isHeader {
                inside = !trimmed.hasPrefix("[[") && headerPath(trimmed) == path
                continue
            }
            guard inside, topLevelKey(trimmed) == key else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }
}
