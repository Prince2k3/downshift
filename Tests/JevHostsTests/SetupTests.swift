import DownshiftCore
import Testing
@testable import JevHosts

@Suite struct SetupFieldTests {
    @Test func everyPresetAsksForExactlyOneSecret() {
        for preset in HostPresets.all {
            #expect(preset.setup.filter { $0.kind == .secret }.count == 1, "\(preset.id)")
        }
    }

    @Test func setupAsksOnlyForVariablesThePresetReads() {
        for preset in HostPresets.all {
            // "A or B (note)" → A, B
            let alternatives: [String] = preset.variables.flatMap { $0.components(separatedBy: " or ") }
            let read = Set(alternatives.map { $0.components(separatedBy: " ")[0] })
            for field in preset.setup { #expect(read.contains(field.variable), "\(preset.id): \(field.variable)") }
        }
    }

    @Test func requiredAnswersAloneBuildTheHost() {
        for preset in HostPresets.all {
            var values: [String: String] = [:]
            for field in preset.setup where !field.optional {
                values[field.variable] = field.variable.hasSuffix("_URL") ? "https://jev.example/v1" : "value"
            }
            let built = HostPresets.host(preset.id, environment: DownshiftEnvironment(values: values))
            #expect((try? built.get()) != nil, "\(preset.id)")
        }
    }
}

@Suite struct HostCredentialsTests {
    @Test func nilKeepsAndEmptyRemoves() {
        let stored = ["A": "1", "B": "2"]
        let result = HostCredentials.applying(["A": nil, "B": "", "C": "3"], to: stored)
        #expect(result == ["A": "1", "C": "3"])
    }

    @Test func removingDropsTheHostsVariablesAndItsJevHostEntry() throws {
        let cloudflare = try #require(HostPresets.preset("cloudflare"))
        let stored = ["CLOUDFLARE_ACCOUNT_ID": "id", "CLOUDFLARE_API_TOKEN_JEV": "t", "OPENROUTER_API_KEY": "k",
                      "DSHIFT_HOST": "cloudflare, openrouter"]
        #expect(HostCredentials.removing(cloudflare, from: stored) == ["OPENROUTER_API_KEY": "k", "DSHIFT_HOST": "openrouter"])
        #expect(HostCredentials.removing(cloudflare, from: ["DSHIFT_HOST": "Cloudflare"]).isEmpty)
    }

    @Test func storedHostsAreThoseWithAnyValue() {
        let hosts = HostCredentials.storedHosts(["CLOUDFLARE_AI_GATEWAY": "gw", "OPENROUTER_API_KEY": "k", "OTHER": "x"])
        #expect(hosts.map(\.id) == ["cloudflare", "openrouter"])
    }

    @Test func preferringPutsTheHostFirst() {
        #expect(HostCredentials.preferring("vercel", over: nil) == "vercel")
        #expect(HostCredentials.preferring("vercel", over: "cloudflare, vercel,openrouter") == "vercel,cloudflare,openrouter")
        #expect(HostCredentials.preferring("vercel", over: "none") == "vercel")
    }
}
