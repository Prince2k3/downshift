import Foundation

/// The `model` saved in `~/.claude/settings.json`. Choosing a /model picker row with Enter
/// makes Claude Code save it as the default for new sessions, and a saved `downshift` would
/// break plain `claude`, which has no proxy to resolve it. So the launcher reads the model
/// before the session and restores it afterwards.
public enum ClaudeSettings {
    public static var userFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The saved default model, ignoring a sentinel left behind by a session that did not
    /// exit cleanly (not a preference worth restoring). Nil when absent or unreadable.
    public static func savedModel(in file: URL = userFile) -> String? {
        guard let data = try? Data(contentsOf: file), let document = try? JSONDocument(parsing: data),
              let model = document.root["model"]?.stringValue, !RouterModel.isRouted(model) else { return nil }
        return model
    }

    /// Puts `previous` back if the file now holds the sentinel (removing `model` when there was
    /// none). Anything but an exact sentinel is left alone, so a real model chosen during the
    /// session survives. Other keys, their order and the file's indentation are kept.
    /// Returns whether the file was changed; a missing or unreadable file is not an error.
    @discardableResult
    public static func restoreSavedModel(_ previous: String?, in file: URL = userFile) -> Bool {
        guard let data = try? Data(contentsOf: file), var document = try? JSONDocument(parsing: data),
              RouterModel.isRouted(document.root["model"]?.stringValue) else { return false }
        document.root["model"] = previous.map(JSONValue.string)
        return (try? AtomicFile.replace(document.rendered(), at: file)) != nil
    }
}
