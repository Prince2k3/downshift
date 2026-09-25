import Crypto
import Foundation
import DownshiftCore

public struct AppsError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// File operations for config files dshift edits on the user's behalf.
enum ManagedFile {
    /// Follows symlinks so a dotfiles-managed `settings.json` keeps being a symlink.
    static func resolved(_ url: URL) -> URL { url.resolvingSymlinksInPath() }

    static func read(_ url: URL) throws -> Data? {
        let target = resolved(url)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return try Data(contentsOf: target)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies the current bytes into `backups/<timestamp>-<app>-<name>` (0600).
    static func backup(_ data: Data, of url: URL, app: ManagedApp, into directory: URL, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = directory.appendingPathComponent(
            "\(formatter.string(from: date))-\(app.rawValue)-\(url.lastPathComponent)")
        try write(data, to: destination, permissions: 0o600)
        return destination
    }

    /// Atomic replace (temp file in the same directory, then rename), keeping the existing
    /// file's permissions. New files get `newFilePermissions`.
    static func write(_ data: Data, to url: URL, newFilePermissions: Int = 0o644) throws {
        let target = resolved(url)
        let existing = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        try write(data, to: target, permissions: existing ?? newFilePermissions)
    }

    private static func write(_ data: Data, to target: URL, permissions: Int) throws {
        do { try AtomicFile.write(data, to: target, permissions: permissions) } catch let error as FileError {
            throw AppsError(error.description)
        }
    }

    static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: resolved(url))
    }
}
