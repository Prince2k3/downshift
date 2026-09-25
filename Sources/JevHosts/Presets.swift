import Foundation
import JevCore

/// A named way to reach Jev, built from environment variables (or the keychain, via `jev setup`).
/// Adding a host is one entry here.
public struct HostPreset: Sendable {
    public var id: String
    public var summary: String
    /// What the preset reads, for `jev hosts list`. Alternatives are joined with ` or `.
    public var variables: [String]
    /// What `jev setup` asks for, saved under these variable names.
    public var setup: [SetupField]
    let build: @Sendable (Env) -> Result<JevHost, HostProblem>

    init(id: String, summary: String, variables: [String], setup: [SetupField],
         build: @escaping @Sendable (Env) -> Result<JevHost, HostProblem>) {
        self.id = id
        self.summary = summary
        self.variables = variables
        self.setup = setup
        self.build = build
    }

    /// The one secret `jev setup --key-stdin` reads.
    public var secretField: SetupField? { setup.first { $0.kind == .secret } }
}

/// One value `jev setup` asks for.
public struct SetupField: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case text
        /// Read without echo, never printed, and only accepted on stdin non-interactively.
        case secret
        case choice([String])
    }

    public var variable: String
    public var label: String
    public var kind: Kind
    public var optional: Bool
    /// Where to find the value.
    public var help: String?

    public init(_ variable: String, _ label: String, _ kind: Kind = .text, optional: Bool = false, help: String? = nil) {
        self.variable = variable
        self.label = label
        self.kind = kind
        self.optional = optional
        self.help = help
    }
}

public struct HostProblem: Error, Sendable, Hashable, CustomStringConvertible {
    public var host: String
    public var message: String
    public var description: String { "\(host): \(message)" }
}

/// Environment lookups that treat empty values as unset.
struct Env: Sendable {
    let environment: JevEnvironment
    func first(_ keys: String...) -> String? {
        keys.lazy.compactMap { key in
            self.environment[key].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        }.first
    }
}

public enum HostPresets {
    public static let cloudflare = HostPreset(
        id: "cloudflare", summary: "Cloudflare Workers AI (typesafe/jev), optionally through AI Gateway",
        variables: ["CLOUDFLARE_API_TOKEN_JEV or CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID",
                    "CLOUDFLARE_AI_GATEWAY (optional)", "JEV_CLOUDFLARE_MODEL (optional)"],
        setup: [
            SetupField("CLOUDFLARE_ACCOUNT_ID", "Account ID",
                       help: "dash.cloudflare.com → Workers AI → Use REST API shows it"),
            SetupField("CLOUDFLARE_API_TOKEN_JEV", "API token", .secret,
                       help: "the same page can create a Workers AI API token"),
            SetupField("CLOUDFLARE_AI_GATEWAY", "AI Gateway id", optional: true,
                       help: "only to send the calls through AI Gateway; Enter skips"),
        ]
    ) { env in
        guard let token = env.first("CLOUDFLARE_API_TOKEN_JEV", "CLOUDFLARE_API_TOKEN") else {
            return .failure(HostProblem(host: "cloudflare", message: "CLOUDFLARE_API_TOKEN is not set"))
        }
        guard let account = env.first("CLOUDFLARE_ACCOUNT_ID") else {
            return .failure(HostProblem(host: "cloudflare", message: "CLOUDFLARE_ACCOUNT_ID is not set"))
        }
        guard isPathSegment(account) else {
            return .failure(HostProblem(host: "cloudflare", message: "CLOUDFLARE_ACCOUNT_ID must be letters and digits"))
        }
        let model = env.first("JEV_CLOUDFLARE_MODEL") ?? "typesafe/jev"
        let url: String
        if let gateway = env.first("CLOUDFLARE_AI_GATEWAY") {
            guard isPathSegment(gateway) else {
                return .failure(HostProblem(host: "cloudflare", message: "CLOUDFLARE_AI_GATEWAY must be a gateway id"))
            }
            url = "https://gateway.ai.cloudflare.com/v1/\(account)/\(gateway)/workers-ai/\(model)"
        } else {
            url = "https://api.cloudflare.com/client/v4/accounts/\(account)/ai/run/\(model)"
        }
        return .success(JevHost(id: "cloudflare", format: .workersAI, url: url, apiKey: token, model: model))
    }

    public static let typesafe = HostPreset(
        id: "typesafe", summary: "TypeSafe's own API (POST /v1/systemone)",
        variables: ["JEV_API_KEY or TYPESAFE_API_KEY", "TYPESAFE_BASE_URL (optional)", "JEV_MODEL (optional)"],
        setup: [SetupField("JEV_API_KEY", "API key", .secret, help: "from your TypeSafe account")]
    ) { env in
        guard let key = env.first("JEV_API_KEY", "TYPESAFE_API_KEY") else {
            return .failure(HostProblem(host: "typesafe", message: "JEV_API_KEY is not set"))
        }
        let base = env.first("TYPESAFE_BASE_URL") ?? "https://api.typesafe.ai"
        if let problem = urlProblem(base) { return .failure(HostProblem(host: "typesafe", message: "TYPESAFE_BASE_URL \(problem)")) }
        let url = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/v1/systemone"
        return .success(JevHost(id: "typesafe", format: .systemOne, url: url, apiKey: key,
                                model: env.first("JEV_MODEL") ?? "jev-latest"))
    }

    public static let vercel = HostPreset(
        id: "vercel", summary: "Vercel AI Gateway (typesafe-ai/jev)",
        variables: ["VERCEL_AI_GATEWAY_API_KEY_JEV or AI_GATEWAY_API_KEY", "JEV_VERCEL_MODEL (optional)"],
        setup: [SetupField("VERCEL_AI_GATEWAY_API_KEY_JEV", "AI Gateway API key", .secret,
                           help: "vercel.com → AI Gateway → API Keys")]
    ) { env in
        guard let key = env.first("VERCEL_AI_GATEWAY_API_KEY_JEV", "AI_GATEWAY_API_KEY") else {
            return .failure(HostProblem(host: "vercel", message: "AI_GATEWAY_API_KEY is not set"))
        }
        return .success(JevHost(id: "vercel", format: .vercel, url: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model",
                                apiKey: key, model: env.first("JEV_VERCEL_MODEL") ?? "typesafe-ai/jev"))
    }

    public static let openrouter = HostPreset(
        id: "openrouter", summary: "OpenRouter's Decisions endpoint (~typesafe/jev-latest)",
        variables: ["OPENROUTER_API_KEY", "JEV_OPENROUTER_MODEL (optional)"],
        setup: [SetupField("OPENROUTER_API_KEY", "API key", .secret, help: "openrouter.ai/settings/keys")]
    ) { env in
        guard let key = env.first("OPENROUTER_API_KEY") else {
            return .failure(HostProblem(host: "openrouter", message: "OPENROUTER_API_KEY is not set"))
        }
        return .success(JevHost(id: "openrouter", format: .systemOne, url: "https://openrouter.ai/api/alpha/decisions",
                                apiKey: key, model: env.first("JEV_OPENROUTER_MODEL") ?? "~typesafe/jev-latest"))
    }

    public static let custom = HostPreset(
        id: "custom", summary: "Any endpoint speaking one of the wire formats",
        variables: ["JEV_BASE_URL (the full endpoint URL)", "JEV_HOST_API_KEY",
                    "JEV_TRANSPORT (systemone, workers-ai or vercel; default systemone)", "JEV_MODEL (optional)"],
        setup: [
            SetupField("JEV_BASE_URL", "Endpoint URL", help: "the full URL; https, or http to localhost"),
            SetupField("JEV_HOST_API_KEY", "API key", .secret),
            SetupField("JEV_TRANSPORT", "Wire format", .choice(JevHost.WireFormat.allCases.map(\.rawValue)), optional: true,
                       help: "Enter keeps systemone"),
        ]
    ) { env in
        guard let url = env.first("JEV_BASE_URL") else {
            return .failure(HostProblem(host: "custom", message: "JEV_BASE_URL is not set"))
        }
        if let problem = urlProblem(url) { return .failure(HostProblem(host: "custom", message: "JEV_BASE_URL \(problem)")) }
        guard let key = env.first("JEV_HOST_API_KEY") else {
            return .failure(HostProblem(host: "custom", message: "JEV_HOST_API_KEY is not set"))
        }
        let transport = env.first("JEV_TRANSPORT") ?? "systemone"
        guard let format = JevHost.WireFormat(rawValue: transport) else {
            let known = JevHost.WireFormat.allCases.map(\.rawValue).joined(separator: ", ")
            return .failure(HostProblem(host: "custom", message: "JEV_TRANSPORT must be one of \(known)"))
        }
        return .success(JevHost(id: "custom", format: format, url: url, apiKey: key, model: env.first("JEV_MODEL") ?? "jev-latest"))
    }

    /// In automatic-resolution order.
    public static let all: [HostPreset] = [cloudflare, typesafe, vercel, openrouter, custom]

    public static func preset(_ id: String) -> HostPreset? { all.first { $0.id == id } }

    /// Builds one preset's host, or says what is missing.
    public static func host(_ id: String, environment: JevEnvironment) -> Result<JevHost, HostProblem> {
        guard let preset = preset(id) else {
            return .failure(HostProblem(host: id, message: "unknown host (known: \(all.map(\.id).joined(separator: ", ")))"))
        }
        return preset.build(Env(environment: environment))
    }

    /// Which hosts to ask, in order: `--host`, then `JEV_HOST` (a comma-separated list is a
    /// failover chain), then the first preset in `all` whose credentials are set.
    /// `none` turns routing off.
    public static func resolve(flag: String? = nil, environment: JevEnvironment) -> HostResolution {
        let env = Env(environment: environment)
        let explicit: (String, String)? = flag.flatMap { $0.isEmpty ? nil : ("--host", $0) }
            ?? env.first("JEV_HOST").map { ("JEV_HOST", $0) }
            ?? env.first("JEV_PROVIDER").map { ("JEV_PROVIDER", $0) }
        if let (source, list) = explicit {
            let ids = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
            if ids == ["none"] || ids == ["off"] { return HostResolution(hosts: [], source: source, problems: []) }
            var hosts: [JevHost] = []
            var problems: [HostProblem] = []
            for id in ids where !hosts.contains(where: { $0.id == id }) {
                switch host(id, environment: environment) {
                case .success(let host): hosts.append(host)
                case .failure(let problem): problems.append(problem)
                }
            }
            return HostResolution(hosts: hosts, source: source, problems: problems)
        }
        for preset in all {
            if case .success(let host) = preset.build(env) {
                return HostResolution(hosts: [host], source: "credentials found", problems: [])
            }
        }
        return HostResolution(hosts: [], source: "no credentials found", problems: [])
    }

    static func isPathSegment(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Keys are sent as bearer tokens, so plain HTTP is only allowed to this machine.
    static func urlProblem(_ string: String) -> String? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return "is not a URL"
        }
        if scheme == "https" { return nil }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host) { return nil }
        return "must be https (plain http is only allowed to localhost)"
    }
}

public struct HostResolution: Sendable {
    /// Tried in order within one deadline. Empty means routing is off.
    public var hosts: [JevHost]
    /// Where the choice came from: `--host`, `JEV_HOST`, `credentials found`, ...
    public var source: String
    /// Named hosts that could not be used.
    public var problems: [HostProblem]
}
