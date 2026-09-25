import Foundation

/// The line `dshift statusline` prints for Claude Code, which pipes the session as JSON on stdin
/// and shows whatever comes back. Claude Code's UI shows the model it asked for (the
/// sentinel), never the one dshift routed to, so this is where the decision becomes visible.
/// A status line replaces Claude Code's footer hints, so it echoes the folder and context use.
public enum StatusLine {
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let colors: [Tier: String] = [
        .fast: "\u{1B}[32m", .balanced: "\u{1B}[36m", .strong: "\u{1B}[35m", .long: "\u{1B}[33m",
    ]

    /// - Parameters:
    ///   - input: what Claude Code piped in (`session_id`, `workspace.current_dir`,
    ///     `context_window.used_percentage`, `model.display_name`); anything missing is skipped.
    ///   - status: the session's status file.
    public static func render(input: JSONValue, status: JSONObject?) -> String {
        let directory = (input["workspace"]?["current_dir"]?.stringValue ?? input["cwd"]?.stringValue ?? "")
            .split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let percent = Int((input["context_window"]?["used_percentage"]?.doubleValue ?? 0).rounded())

        let routed: String
        if let status, status["manual"]?.boolValue == true {
            // The user picked a model with /model: show their choice, not a tier.
            let name = input["model"]?["display_name"]?.stringValue ?? ""
            routed = "\(dim)⏸ manual\(reset) \(name)".trimmingCharacters(in: .whitespaces)
        } else if let status {
            let tier = status["tier"]?.stringValue
            let color = tier.flatMap(Tier.init(rawValue:)).flatMap { colors[$0] } ?? ""
            let confidence = status["confidence"]?.doubleValue.map { " \(dim)(p=\(String(format: "%.2f", $0)))\(reset)" } ?? ""
            // Only name the reason when routing held back, so the common case stays short.
            let reason = status["reason"]?.stringValue ?? ""
            let held = !reason.isEmpty && reason != "jev" && reason != "jev/no-change" && !reason.contains("override")
            let why = held ? " \(dim)(\(reason.split(separator: "/").first.map(String.init) ?? reason))\(reset)" : ""
            routed = "\(color)\(status["model"]?.stringValue ?? tier ?? "")\(reset)\(confidence)\(why)"
        } else {
            routed = "\(dim)dshift: waiting for first prompt\(reset)"
        }
        return "\(routed) \(dim)·\(reset) \(directory) \(dim)· \(percent)% context\(reset)"
    }
}
