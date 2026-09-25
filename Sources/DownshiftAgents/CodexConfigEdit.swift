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
        for line in lines where isTableHeader(line, named: ["model_providers", "downshift"]) {
            throw AppsError("config.toml already defines `\(line.trimmingCharacters(in: .whitespaces))` outside dshift's block; rename or remove it first")
        }

        let firstTable = firstTableHeaderIndex(lines)
        if defaultProvider {
            let topLevel = lines[..<(firstTable ?? lines.count)]
            if let existing = topLevel.first(where: { topLevelKey($0) == "model_provider" }) {
                throw AppsError("config.toml already sets a default provider (`\(existing.trimmingCharacters(in: .whitespaces))`); use --no-codex-default-provider, or remove it first")
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

    /// Index of the first `[table]` / `[[array]]` header, skipping the insides of multi-line
    /// arrays (a top-level `notify = [` … `]` has lines that are not headers).
    static func firstTableHeaderIndex(_ lines: [String]) -> Int? {
        var arrayDepth = 0
        for (index, raw) in lines.enumerated() {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if arrayDepth == 0, line.hasPrefix("["), raw.first == "[" { return index }
            arrayDepth = max(0, arrayDepth + bracketBalance(line))
        }
        return nil
    }

    static func topLevelKey(_ line: String) -> String? {
        let content = stripComment(line)
        guard let equals = content.firstIndex(of: "=") else { return nil }
        let key = content[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    static func isTableHeader(_ line: String, named path: [String]) -> Bool {
        var content = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard content.hasPrefix("["), content.hasSuffix("]"), !content.hasPrefix("[[") else { return false }
        content = String(content.dropFirst().dropLast())
        let parts = content.split(separator: ".").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return parts == path
    }

    /// Net `[` minus `]` outside strings.
    static func bracketBalance(_ line: String) -> Int {
        var balance = 0
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                if escaped { escaped = false } else if character == "\\" && open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "[": balance += 1
            case "]": balance -= 1
            default: break
            }
        }
        return balance
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
        let lines = splitLines(text)
        for line in lines[..<(firstTableHeaderIndex(lines) ?? lines.count)] where topLevelKey(line) == key {
            let content = stripComment(line)
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
        for line in splitLines(text) {
            let trimmed = stripComment(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && line.first == "[" {
                inside = isTableHeader(line, named: path)
                continue
            }
            guard inside, topLevelKey(line) == key else { continue }
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }
}
