import ArgumentParser
import Foundation
import DownshiftAgents

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "Point the Claude and Codex desktop apps at the local dshift proxy (reversibly).",
        discussion: """
            Desktop apps are launched from the Dock, so dshift can't wrap them the way `dshift claude`
            wraps the CLI. Instead this edits the config files the apps read at startup:
              claude CLI (not the Claude app)     ~/.claude/settings.json   env.ANTHROPIC_BASE_URL and the "Dynamic (Downshift)" /model row
              Codex app + codex CLI                ~/.codex/config.toml      [model_providers.downshift], model_provider
            Each file is backed up first, and `dshift apps disable` restores it byte for byte when
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
              help: "Codex: also set `model_provider = \"downshift\"` so the app uses dshift by default (otherwise only `codex -c model_provider=downshift` does).")
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
                      dshift serve install --port \(port)     (keeps it running, starts at login)
                      dshift serve --port \(port)             (foreground, this terminal only)
                    """)
            }
            print("\nOpen a new session in each app (restart the app if requests don't reach the proxy).")
        }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Undo `dshift apps enable`.")

        @OptionGroup var selection: Selection

        func run() throws {
            let manager = AppsManager()
            for app in selection.apps {
                let file = manager.locations.file(for: app).path
                switch try manager.disable(app) {
                case .notEnabled: print("\(app.displayName): not enabled")
                case .restoredBackup(let backup): print("\(app.displayName): restored \(file) from \(backup.path)")
                case .removedFile: print("\(app.displayName): removed \(file) (dshift created it)")
                case .removedEntries(let untouched):
                    print("\(app.displayName): removed dshift's entries from \(file) (it changed since enabling, so the rest was kept)")
                    for key in untouched { print("  left \(key) alone: it no longer has the value dshift set") }
                }
            }
            print("\nOpen a new session in each app for the change to apply.")
        }
    }
}
