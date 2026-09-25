import Foundation

/// The launchers' log. Claude Code and Codex own the terminal in interactive mode and redraw
/// over anything printed to it, so when stdout is a TTY lines go to a file instead. In print
/// mode (`claude -p`, `codex exec`) there is no TUI to damage, and stderr is easier to pipe.
///
/// Never log prompts, request bodies or headers: they carry the user's code and credentials.
public struct JevLog: Sendable {
    public enum Destination: Sendable, Equatable {
        case standardError
        case file(URL)
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/jev/jev.log")
    }

    public var destination: Destination
    public var debugEnabled: Bool

    public init(destination: Destination, debugEnabled: Bool = false) {
        self.destination = destination
        self.debugEnabled = debugEnabled
    }

    /// File when stdout is a terminal, stderr otherwise; debug lines when `JEV_DEBUG` is set.
    public init(settings: JevSettings, file: URL = defaultFile) {
        self.init(destination: isatty(STDOUT_FILENO) != 0 ? .file(file) : .standardError, debugEnabled: settings.debug)
    }

    public func log(_ line: String) {
        let text = "[jev] \(line)\n"
        switch destination {
        case .standardError:
            FileHandle.standardError.write(Data(text.utf8))
        case .file(let url):
            // A broken log file must never take down the session.
            try? append("\(Date().formatted(.iso8601)) \(text)", to: url)
        }
    }

    public func debug(_ line: @autoclosure () -> String) {
        if debugEnabled { log(line()) }
    }

    private func append(_ text: String, to url: URL) throws {
        try AtomicFile.privateDirectory(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}
