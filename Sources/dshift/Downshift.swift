import ArgumentParser
import Foundation

@main
struct Downshift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dshift",
        abstract: "Route Claude Code and Codex prompts to the right model with Jev.",
        version: "0.4.0",
        subcommands: [
            SetupCommand.self, ClaudeCommand.self, CodexCommand.self, StatusCommand.self, SavingsCommand.self, DoctorCommand.self,
            StatuslineCommand.self, ServeCommand.self, AppsCommand.self,
            HostsCommand.self, SchemaCommand.self,
        ]
    )
}
