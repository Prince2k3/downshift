import JevCore

/// What `jev setup` and `jev hosts remove` do to the stored credentials, as pure functions
/// over the keychain's variable → value dictionary.
public enum HostCredentials {
    /// `stored` with one host's answers applied. A nil answer keeps the stored value; an empty
    /// one removes it (an optional field left blank).
    public static func applying(_ answers: [String: String?], to stored: [String: String]) -> [String: String] {
        var result = stored
        for (key, answer) in answers {
            guard let answer else { continue }
            result[key] = answer.isEmpty ? nil : answer
        }
        return result
    }

    /// `stored` without the host's variables, and without a `JEV_HOST` that names only it.
    public static func removing(_ preset: HostPreset, from stored: [String: String]) -> [String: String] {
        var result = stored
        for field in preset.setup { result[field.variable] = nil }
        if let hosts = result["JEV_HOST"] {
            let remaining = hosts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != preset.id }
            result["JEV_HOST"] = remaining.isEmpty ? nil : remaining.joined(separator: ",")
        }
        return result
    }

    /// Hosts with anything stored.
    public static func storedHosts(_ stored: [String: String]) -> [HostPreset] {
        HostPresets.all.filter { preset in preset.setup.contains { stored[$0.variable] != nil } }
    }

    /// `JEV_HOST` putting `id` first, keeping the rest of an existing failover list.
    public static func preferring(_ id: String, over current: String?) -> String {
        let rest = (current ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.lowercased() != id && $0.lowercased() != "none" && $0.lowercased() != "off" }
        return ([id] + rest).joined(separator: ",")
    }
}
