import Testing
@testable import JevProxy

@Suite struct HopByHopTests {
    @Test func hopByHopHeadersAreNotForwarded() {
        for name in ["connection", "transfer-encoding", "host", "content-length", "upgrade"] {
            #expect(hopByHopHeaders.contains(name))
        }
        #expect(!hopByHopHeaders.contains("authorization"))
    }
}
