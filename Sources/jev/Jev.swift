import ArgumentParser
import Foundation

@main
struct Jev: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jev",
        abstract: "Route Claude Code and Codex prompts to the right model with Jev.",
        version: "0.4.0-dev",
        subcommands: [
            SetupCommand.self, ClaudeCommand.self, CodexCommand.self, StatusCommand.self, SavingsCommand.self, DoctorCommand.self,
            ExplainCommand.self, StatuslineCommand.self, SkillsCommand.self, ServeCommand.self, AppsCommand.self,
            HostsCommand.self, SchemaCommand.self,
        ]
    )
}
