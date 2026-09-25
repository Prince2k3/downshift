import Foundation
import JevCore

/// The agent skills jev ships, compiled in as templates so a single binary is enough (plan
/// §6). They are rendered with the command that runs jev: the absolute path of the running
/// binary for per-launch and user installs, or plain `jev` (found through PATH) for skills
/// committed to a project.
public enum SkillAgent: String, Sendable, CaseIterable {
    case claude
    case codex
}

public struct Skill: Sendable {
    public var name: String
    public var render: @Sendable (_ agent: SkillAgent, _ command: String) -> String

    /// `/jev-explain` (Claude) and `$jev-explain` (Codex): the boxed report for the last turn.
    /// The `<jev-explain>` tag also tells the proxy not to route the turn that asks.
    public static let explain = Skill(name: "jev-explain") { agent, command in
        switch agent {
        case .claude:
            """
            ---
            name: jev-explain
            description: Show why Jev Router selected the model used for the last prompt.
            disable-model-invocation: true
            allowed-tools: Bash(\(command) explain *)
            ---

            <jev-explain>
            Return the report below verbatim in a plain text code block. Do not add analysis or use tools.

            !`\(command) explain "${CLAUDE_SESSION_ID}"`

            """
        case .codex:
            """
            ---
            name: jev-explain
            description: Show why Jev Router selected the model used for the last prompt.
            ---

            <jev-explain>
            Run `\(command) explain` once and return its stdout verbatim in a plain text code block. Do not add analysis or use other tools.

            """
        }
    }

    /// The registry; new skills are added here and the installer picks them up.
    public static let all: [Skill] = [.explain]
}

public enum SkillInstaller {
    /// The command text a skill runs jev with. A path with spaces is quoted, and the
    /// `allowed-tools` rule uses the same text so the two always match.
    public static func command(executable: String?) -> String {
        guard let executable else { return "jev" }
        return executable.contains(where: \.isWhitespace) ? "\"\(executable)\"" : executable
    }

    /// Where an agent looks for skills under `root` (a project, or the home folder).
    public static func skillsDirectory(_ agent: SkillAgent, root: URL) -> URL {
        switch agent {
        case .claude: root.appendingPathComponent(".claude/skills", isDirectory: true)
        case .codex: root.appendingPathComponent(".agents/skills", isDirectory: true)
        }
    }

    /// User-level folders; Claude's follows `CLAUDE_CONFIG_DIR`. The home folder is `$HOME`,
    /// as the agents see it, rather than the account's (which ignores `HOME`).
    public static func userSkillsDirectory(_ agent: SkillAgent, environment: [String: String] = ProcessInfo.processInfo.environment,
                                           home: URL? = nil) -> URL {
        let home = home ?? environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        if agent == .claude, let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return URL(fileURLWithPath: config, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        }
        return skillsDirectory(agent, root: home)
    }

    public static func file(_ skill: Skill, in directory: URL) -> URL {
        directory.appendingPathComponent(skill.name, isDirectory: true).appendingPathComponent("SKILL.md")
    }

    public enum Outcome: Sendable, Equatable {
        case written
        case unchanged
        /// A file jev didn't write is in the way; `force` replaces it.
        case skippedForeign
    }

    /// A file counts as jev's when it carries the skill's tag, which every version (the Node
    /// one included) has.
    static func isOurs(_ text: String, skill: Skill) -> Bool {
        text.contains("<\(skill.name)>")
    }

    /// Writes one skill file, creating folders as needed; an existing file jev wrote is
    /// refreshed, anything else is kept unless `force`.
    @discardableResult
    public static func install(_ skill: Skill, agent: SkillAgent, command: String, in directory: URL,
                               force: Bool = false) throws -> Outcome {
        let target = file(skill, in: directory)
        let text = skill.render(agent, command)
        if let existing = try? String(contentsOf: target, encoding: .utf8) {
            if existing == text { return .unchanged }
            if !force && !isOurs(existing, skill: skill) { return .skippedForeign }
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data(text.utf8), to: target, permissions: 0o644)
        return .written
    }

    /// What is installed at `directory`: absent, jev's own (current or not), or someone else's.
    public enum State: Sendable, Equatable {
        case missing
        case current
        case outdated
        case foreign
    }

    public static func state(_ skill: Skill, agent: SkillAgent, command: String, in directory: URL) -> State {
        guard let existing = try? String(contentsOf: file(skill, in: directory), encoding: .utf8) else { return .missing }
        if existing == skill.render(agent, command) { return .current }
        return isOurs(existing, skill: skill) ? .outdated : .foreign
    }
}
