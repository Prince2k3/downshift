import Foundation

/// The boxed report printed by `jev explain`, `/jev-explain` and `$jev-explain`.
public enum Explain {
    /// Node used 33, sized for tier names. Jev now answers with exact model ids, so the box fits
    /// the longest one: "Recommended model: CLAUDE-HAIKU-4-5-20251001" is 44 characters.
    static let width = 46

    public static func format(_ status: JSONObject?) -> String {
        guard let status else { return "Jev Router: no routing decision has been recorded for this session." }
        if status["manual"]?.boolValue == true {
            return "Jev Router: routing is paused because you selected a model manually."
        }

        let metrics = status["metrics"]
        let session = status["jev"]?["request"]?["state"]?["session"]
        let tier = status["tier"]?.stringValue
        // The model question is sent under the key `model`. (The Node version read
        // `model_tier` here, so it always fell back to the final tier.)
        let recommendation = status["jev"]?["response"]?["answers"]?["model"]?["choice"]?.stringValue ?? tier ?? "unknown"
        let confidence = status["confidence"]?.doubleValue

        return ([
            "┌\(String(repeating: "─", count: width))┐",
            row("Jev Router"),
            row(),
            row("Jev request"),
        ] + wrapped("Prompt: ", status["prompt"]?.stringValue ?? "not recorded") + [
            row("Current model: \((session?["current_model"]?.stringValue ?? "unknown").uppercased())"),
            row("Context tokens: \(session?["context_tokens"].flatMap(numberText) ?? "unknown")"),
            row(),
            row("Jev response"),
            row("Task complexity     \(metric(metrics?["taskComplexity"]))"),
            row("Reasoning required  \(metric(metrics?["reasoningRequired"]))"),
            row("Tool complexity     \(metric(metrics?["toolComplexity"]))"),
            row("Context size        \(metric(metrics?["contextSize"]))"),
            row(),
            row("Recommended model: \(recommendation.uppercased())"),
            row("Selected model: \((status["model"]?.stringValue ?? tier ?? "unknown").uppercased())"),
            row(),
            row("Confidence: \(confidence.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a")"),
            row("Decision: \(decision(status["reason"]?.stringValue ?? ""))"),
            "└\(String(repeating: "─", count: width))┘",
        ]).joined(separator: "\n")
    }

    static func row(_ text: String = "") -> String {
        let fitted = String(text.prefix(width - 2))
        return "│ \(fitted)\(String(repeating: " ", count: width - 2 - fitted.count)) │"
    }

    static func metric(_ value: JSONValue?) -> String {
        guard let number = value?.doubleValue, number.isFinite else { return "n/a" }
        return String(format: "%.2f", number)
    }

    /// A number as written in the status file, or a string value as is.
    static func numberText(_ value: JSONValue) -> String? {
        switch value {
        case .number(let literal): literal
        case .string(let text): text
        default: nil
        }
    }

    /// Word-wraps `label + value` into rows.
    static func wrapped(_ label: String, _ value: String) -> [String] {
        let words = "\(label)\(value)".split(whereSeparator: \.isWhitespace)
        var lines: [String] = []
        for word in words {
            if let last = lines.last, last.count + 1 + word.count <= width - 2 {
                lines[lines.count - 1] = "\(last) \(word)"
            } else {
                lines.append(String(word))
            }
        }
        return lines.map { row($0) }
    }

    static func decision(_ reason: String) -> String {
        if reason.contains("override") { return "prompt override" }
        if reason.contains("jev-unavailable") { return "Jev unavailable; held" }
        if reason.contains("low-confidence-no-downgrade") { return "low confidence; held" }
        if reason.contains("low-confidence-capped") { return "low confidence; capped" }
        if reason.contains("cache-rebuild") { return "cache rebuild avoided" }
        if reason.contains("unavailable") { return "nearest available tier" }
        return "Jev recommendation"
    }
}
