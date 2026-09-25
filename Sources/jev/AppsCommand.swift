import ArgumentParser
import Foundation
import JevAgents

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Point the Claude and Codex desktop apps at the local jev proxy (reversibly).",
        discussion: """
            Desktop apps are launched from the Dock, so jev can't wrap them the way `jev claude`
            wraps the CLI. Instead this edits the config files the apps read at startup:
              claude CLI (not the Claude app)     ~/.claude/settings.json   env.ANTHROPIC_BASE_URL and the "Dynamic (Jev)" /model row
              Codex app + codex CLI                ~/.codex/config.toml      [model_providers.jev], model_provider
            Each file is backed up first, and `jev apps disable` restores it byte for byte when
            nothing else has changed it since. The proxy must be running while enabled, or new
            sessions fail to connect.
            """,
        subcommands: [Enable.self, Disable.self]
    )

    struct Selection: ParsableArguments {
        @Flag(help: "The claude CLI. The Claude app's Code tab pins its own ANTHROPIC_BASE_URL and is not covered.") var claude = false
        @Flag(help: "The Codex app and the codex CLI.") var codex = false

        var apps: [ManagedApp] {
            let chosen = ManagedApp.allCases.filter { ($0 == .claude && claude) || ($0 == .codex && codex) }
            return chosen.isEmpty ? ManagedApp.allCases : chosen
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Route the apps through the proxy on 127.0.0.1.")

        @OptionGroup var selection: Selection

        @Option(help: "Proxy port on 127.0.0.1.") var port = AppsManager.defaultPort

        @Flag(inversion: .prefixedNo,
              help: "Codex: also set `model_provider = \"jev\"` so the app uses jev by default (otherwise only `codex -c model_provider=jev` does).")
        var codexDefaultProvider = true

        func run() throws {
            let manager = AppsManager()
            for app in selection.apps {
                switch try manager.enable(app, port: port, codexDefaultProvider: codexDefaultProvider) {
                case .alreadyEnabled:
                    print("\(app.displayName): already enabled")
                case .enabled(let backup):
                    print("\(app.displayName): enabled -> \(AppsManager.baseURL(for: app, port: port))")
                    print("  edited  \(manager.locations.file(for: app).path)")
                    if let backup { print("  backup  \(backup.path)") }
                }
            }
            if !ProxyProbe.isListening(port: port) {
                print("""

                    warning: nothing is listening on 127.0.0.1:\(port) yet. Start the proxy before opening a new
                    session, or the apps can't connect:
                      jev serve install --port \(port)     (keeps it running, starts at login)
                      jev serve --port \(port)             (foreground, this terminal only)
                    """)
            }
            print("\nOpen a new session in each app (restart the app if requests don't reach the proxy).")
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Undo `jev apps enable`.")

        @OptionGroup var selection: Selection

        func run() throws {
            let manager = AppsManager()
            for app in selection.apps {
                let file = manager.locations.file(for: app).path
                switch try manager.disable(app) {
                case .notEnabled: print("\(app.displayName): not enabled")
                case .restoredBackup(let backup): print("\(app.displayName): restored \(file) from \(backup.path)")
                case .removedFile: print("\(app.displayName): removed \(file) (jev created it)")
                case .removedEntries(let untouched):
                    print("\(app.displayName): removed jev's entries from \(file) (it changed since enabling, so the rest was kept)")
                    for key in untouched { print("  left \(key) alone: it no longer has the value jev set") }
                }
            }
            print("\nOpen a new session in each app for the change to apply.")
        }
    }
}
