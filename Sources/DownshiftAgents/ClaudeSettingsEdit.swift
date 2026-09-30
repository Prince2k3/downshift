import Foundation
import DownshiftCore

/// Edits to `~/.claude/settings.json`. The Claude app's Code tab and the `claude` CLI both
/// apply its `env` block to every new session, which is how a Dock-launched app is pointed at
/// the local proxy. Key order is preserved and the file is re-indented the way Claude Code
/// writes it (`JSON.stringify(settings, null, indent)`).
public enum ClaudeSettingsEdit {
    public static let baseURLKey = "ANTHROPIC_BASE_URL"

    /// What `enable` replaced, so `disable` can put it back.
    public struct Previous: Sendable, Equatable {
        /// The value of each managed env key before enabling (`nil` = the key was absent).
        public var env: [String: String?]
        public var envExisted: Bool
        /// The saved `model` before enabling. Picking the sentinel's /model row saves
        /// `"model": "downshift"`, which plain `claude` can't resolve once the proxy is gone.
        public var model: String?

        public init(env: [String: String?], envExisted: Bool, model: String? = nil) {
            self.env = env
            self.envExisted = envExisted
            self.model = model
        }
    }

    /// The `env.ANTHROPIC_BASE_URL` a settings file sets, if any.
    public static func baseURL(in data: Data?) -> String? {
        guard let data, let root = try? JSONValue.parse(data).objectValue else { return nil }
        return root["env"]?.objectValue?[baseURLKey]?.stringValue
    }

    /// The row the sentinel gets in Claude Code's /model picker, named like the Codex one.
    public static let pickerName = "Dynamic (Downshift)"

    /// The base URL, then the sentinel's /model picker row. Claude Code sends the id verbatim
    /// behind a custom base URL, which is how the proxy tells "route this" from a model the
    /// user picked. Capabilities are declared so Claude Code still composes thinking and
    /// effort; the proxy strips what the routed model can't accept. Claude Code doesn't know
    /// the sentinel's context window and would assume 200K, auto-compacting a longer session on
    /// every turn, so the window is declared (it applies only to model ids not named
    /// `claude-*`), and the window-enforcement flag keeps versions that check it client-side
    /// from capping it again.
    public static func managedEnv(baseURL: String) -> [(String, String)] {
        [
            (baseURLKey, baseURL),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION", RouterModel.id),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_NAME", pickerName),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION", "Route each turn to the cheapest model that can do it"),
            ("ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES",
             "thinking,adaptive_thinking,interleaved_thinking,effort,max_effort"),
            ("CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT", "1"),
            ("CLAUDE_CODE_MAX_CONTEXT_TOKENS", String(ClaudeModel.routedContextWindow)),
        ]
    }

    public static func enable(_ data: Data?, baseURL: String) throws -> (Data, Previous) {
        var (root, indent, trailingNewline) = try parse(data)
        var env: JSONObject
        let envExisted: Bool
        switch root["env"] {
        case nil: env = JSONObject(); envExisted = false
        case .object(let existing)?: env = existing; envExisted = true
        case _?: throw AppsError("\"env\" in settings.json is not an object; fix it before running dshift apps enable")
        }
        var previous: [String: String?] = [:]
        for (key, value) in managedEnv(baseURL: baseURL) {
            switch env[key] {
            case nil: previous[key] = .some(nil)
            case .string(let old)?: previous[key] = .some(old)
            case _?: throw AppsError("env.\(key) in settings.json is not a string")
            }
            env[key] = .string(value)
        }
        root["env"] = .object(env)
        let model = root["model"]?.stringValue.flatMap { RouterModel.isRouted($0) ? nil : $0 }
        return (render(root, indent: indent, trailingNewline: trailingNewline),
                Previous(env: previous, envExisted: envExisted, model: model))
    }

    /// Removes only what `enable` added, plus a saved sentinel model (put back to the model
    /// saved before enabling). A key the user has since changed to another value is left
    /// alone and reported.
    public static func disable(_ data: Data, baseURL: String, previous: Previous) throws -> (Data, untouched: [String]) {
        var (root, indent, trailingNewline) = try parse(data)
        var changed = false
        if RouterModel.isRouted(root["model"]?.stringValue) {
            root["model"] = previous.model.map(JSONValue.string)
            changed = true
        }
        guard case .object(var env)? = root["env"] else {
            return (changed ? render(root, indent: indent, trailingNewline: trailingNewline) : data, [])
        }
        var untouched: [String] = []
        for (key, value) in managedEnv(baseURL: baseURL) {
            guard env[key]?.stringValue == value else {
                if env[key] != nil { untouched.append(key) }
                continue
            }
            if case .some(.some(let old)) = previous.env[key] {
                env[key] = .string(old)
            } else {
                env[key] = nil
            }
        }
        root["env"] = env.isEmpty && !previous.envExisted ? nil : .object(env)
        return (render(root, indent: indent, trailingNewline: trailingNewline), untouched)
    }

    public static func isEnabled(_ data: Data?, baseURL: String? = nil) -> String? {
        guard let data, let root = try? JSONValue.parse(data), let url = root["env"]?[baseURLKey]?.stringValue
        else { return nil }
        if let baseURL, url != baseURL { return nil }
        return url
    }

    static func parse(_ data: Data?) throws -> (JSONObject, indent: Int, trailingNewline: Bool) {
        do {
            let document = try JSONDocument(parsing: data)
            return (document.root, document.indent, document.trailingNewline)
        } catch .invalid(let error) {
            throw AppsError("settings.json is not valid JSON (\(error)); fix it before running dshift apps")
        } catch .notAnObject {
            throw AppsError("settings.json is not a JSON object")
        }
    }

    static func render(_ root: JSONObject, indent: Int, trailingNewline: Bool) -> Data {
        JSONDocument(root: root, indent: indent, trailingNewline: trailingNewline).rendered()
    }
}
