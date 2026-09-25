import Foundation
import DownshiftAgents
import DownshiftCore

/// Forwarded-argument helpers shared by both launchers.
public enum ForwardedArguments {
    /// Finds `--name value`, `--name=value` (and the short forms) before a `--` terminator,
    /// and returns the last value with every occurrence removed.
    public static func extract(_ names: Set<String>, from arguments: [String]) -> (value: String?, rest: [String]) {
        var value: String?
        var rest: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                rest += arguments[index...]
                break
            }
            if names.contains(argument), index + 1 < arguments.count {
                value = arguments[index + 1]
                index += 2
                continue
            }
            if let equals = argument.firstIndex(of: "="), names.contains(String(argument[..<equals])) {
                value = String(argument[argument.index(after: equals)...])
                index += 1
                continue
            }
            rest.append(argument)
            index += 1
        }
        return (value, rest)
    }

    /// The value of an option without removing it.
    public static func value(of names: Set<String>, in arguments: [String]) -> String? {
        extract(names, from: arguments).value
    }

    public static func contains(_ names: Set<String>, in arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "--" { return false }
            if names.contains(argument) { return true }
            if let equals = argument.firstIndex(of: "="), names.contains(String(argument[..<equals])) { return true }
        }
        return false
    }
}

/// How `dshift claude` runs Claude Code (plan §5, §5a, §6).
public enum ClaudeLaunch {
    static let modelFlags: Set<String> = ["--model"]
    /// Claude Code subcommands that start no session; they get the arguments untouched.
    static let subcommands: Set<String> = [
        "mcp", "config", "update", "upgrade", "doctor", "install", "migrate-installer", "setup-token", "plugin", "auth",
    ]

    /// The settings files that can hold a `model` or a `statusLine`, most specific first.
    public static func settingsFiles(currentDirectory: URL, userSettings: URL) -> [URL] {
        let project = currentDirectory.appendingPathComponent(".claude", isDirectory: true)
        return [project.appendingPathComponent("settings.local.json"), project.appendingPathComponent("settings.json"), userSettings]
    }

    /// Plan §5a: `--model`, then `ANTHROPIC_MODEL`, then the settings files. Nil means
    /// Claude Code's own default. The sentinel never counts.
    public static func baselineModel(arguments: [String], environment: [String: String], settingsFiles: [URL]) -> String? {
        func real(_ model: String?) -> String? {
            guard let model, !model.isEmpty, !RouterModel.isRouted(model) else { return nil }
            return model
        }
        if let model = real(ForwardedArguments.value(of: modelFlags, in: arguments)) { return model }
        if let model = real(environment["ANTHROPIC_MODEL"]) { return model }
        for file in settingsFiles {
            if let model = real(settingValue(in: file, key: "model")?.stringValue) { return model }
        }
        return nil
    }

    /// Whether the user configured a status line of their own; it takes priority over dshift's.
    public static func hasOwnStatusLine(settingsFiles: [URL]) -> Bool {
        settingsFiles.contains { settingValue(in: $0, key: "statusLine") != nil }
    }

    static func settingValue(in file: URL, key: String) -> JSONValue? {
        guard let data = try? Data(contentsOf: file), let root = try? JSONValue.parse(data) else { return nil }
        return root[key]
    }

    public static func isSubcommand(_ arguments: [String]) -> Bool {
        arguments.first.map(subcommands.contains) ?? false
    }

    /// The forwarded arguments with dshift's added first, so a trailing `-- prompt` stays last.
    /// When routing, `--model` is dropped: it became the baseline, and the session starts on
    /// the sentinel instead.
    public static func arguments(_ forwarded: [String], route: Bool, settingsFile: URL?) -> [String] {
        if isSubcommand(forwarded) { return forwarded }
        var added: [String] = []
        if let settingsFile { added += ["--settings", settingsFile.path] }
        let rest = route ? ForwardedArguments.extract(modelFlags, from: forwarded).rest : forwarded
        return added + rest
    }

    /// The child's environment: the proxy, the picker row, and (when routing) the sentinel as
    /// this session's model. `ANTHROPIC_MODEL` applies to this session only and is never saved.
    public static func environment(_ base: [String: String], baseURL: String, route: Bool) -> [String: String] {
        var environment = base
        for (key, value) in ClaudeSettingsEdit.managedEnv(baseURL: baseURL) { environment[key] = value }
        environment["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
        if route { environment["ANTHROPIC_MODEL"] = RouterModel.id }
        return environment
    }

    /// The `--settings` file that adds dshift's status line.
    /// How a settings file runs `executable`: quoted when the path has spaces.
    public static func command(executable: String) -> String {
        executable.contains(where: \.isWhitespace) ? "\"\(executable)\"" : executable
    }

    public static func statusLineSettings(command: String) -> Data {
        let settings: JSONValue = ["statusLine": ["type": "command", "command": .string("\(command) statusline"), "padding": 0]]
        return Data(settings.serialized())
    }
}

/// How `dshift codex` runs the Codex CLI (plan §5a, §6).
public enum CodexLaunch {
    public static let provider = "downshift"
    static let modelFlags: Set<String> = ["-m", "--model"]
    static let profileFlags: Set<String> = ["-p", "--profile"]

    /// Plan §5a: `-m`/`--model`, then `--profile`'s model, then `model` in config.toml. Nil
    /// means Codex's own default.
    public static func baselineModel(arguments: [String], codexHome: URL) -> String? {
        if let model = ForwardedArguments.value(of: modelFlags, in: arguments), !RouterModel.isRouted(model) { return model }
        let config = try? Data(contentsOf: codexHome.appendingPathComponent("config.toml"))
        if let profile = ForwardedArguments.value(of: profileFlags, in: arguments), !profile.contains("/") {
            // codex 0.155: `<CODEX_HOME>/<name>.config.toml`; older versions: `[profiles.<name>]`.
            let file = codexHome.appendingPathComponent("\(profile).config.toml")
            if let model = CodexConfigEdit.topLevelString(try? Data(contentsOf: file), key: "model") { return model }
            if let model = CodexConfigEdit.tableString(config, table: ["profiles", profile], key: "model") { return model }
        }
        if let model = CodexConfigEdit.topLevelString(config, key: "model"), !RouterModel.isRouted(model) { return model }
        return nil
    }

    /// The provider flags pointing Codex at the proxy, then (when routing) the sentinel in
    /// place of any `-m`, then the user's arguments. `supports_websockets=false` keeps the
    /// CLI on HTTP, where the decision line is injected.
    public static func arguments(_ forwarded: [String], baseURL: String, route: Bool) -> [String] {
        var arguments: [String] = []
        let rest: [String]
        if route {
            arguments += ["--model", RouterModel.id]
            rest = ForwardedArguments.extract(modelFlags, from: forwarded).rest
        } else {
            rest = forwarded
        }
        for setting in [
            "model_provider=\"\(provider)\"",
            "model_providers.\(provider).name=\"Jev Router\"",
            "model_providers.\(provider).base_url=\"\(baseURL)\"",
            "model_providers.\(provider).wire_api=\"responses\"",
            "model_providers.\(provider).requires_openai_auth=true",
            "model_providers.\(provider).supports_websockets=false",
        ] {
            arguments += ["--config", setting]
        }
        return arguments + rest
    }
}
