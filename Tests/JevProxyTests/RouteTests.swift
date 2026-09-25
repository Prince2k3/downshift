import Testing
@testable import JevProxy

@Suite struct RouteTests {
    typealias Route = PassthroughResponder.Route

    @Test func prefixIsStrippedOnlyAtASegmentBoundary() {
        let codex = Route(prefix: "/codex/", upstream: "https://chatgpt.com/backend-api/codex/")
        #expect(codex.target(for: "/codex/responses") == "https://chatgpt.com/backend-api/codex/responses")
        #expect(codex.target(for: "/codex?x=1") == "https://chatgpt.com/backend-api/codex?x=1")
        #expect(codex.target(for: "/codex") == "https://chatgpt.com/backend-api/codex")
        #expect(codex.target(for: "/codexfoo") == nil)
        #expect(codex.target(for: "/v1/messages") == nil)
    }

    @Test func emptyPrefixMatchesEverything() {
        let root = Route(prefix: "", upstream: "https://api.anthropic.com")
        #expect(root.target(for: "/v1/messages?beta=true") == "https://api.anthropic.com/v1/messages?beta=true")
    }
}
