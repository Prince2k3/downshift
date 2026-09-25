import Foundation
import DownshiftCore
import Testing
@testable import JevHosts

/// Real calls to every configured host. Off unless DSHIFT_LIVE=1; they spend a little credit.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DSHIFT_LIVE"] == "1"))
struct LiveHostTests {
    @Test func everyConfiguredHostAnswersWithinTheSchema() async throws {
        let environment = DownshiftEnvironment.load()
        let hosts = HostPresets.all.compactMap { try? HostPresets.host($0.id, environment: environment).get() }
        try #require(!hosts.isEmpty, "no host credentials configured")
        for host in hosts {
            let timing = JevClient.Timing(attemptTimeout: .seconds(15), retries: 0, deadline: .seconds(15))
            let outcome = await JevClient(hosts: [host], timing: timing).ask(try Fixture.request())
            #expect(outcome.result != nil, "\(host.id): \(outcome.summary) \(outcome.attempts.compactMap(\.message))")
            if let choice = outcome.result?.answers["model"]?.choice {
                #expect(Fixture.models.map(\.id).contains(choice), "\(host.id) chose \(choice)")
            }
        }
    }
}
