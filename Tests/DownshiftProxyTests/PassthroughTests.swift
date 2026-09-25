import Testing
@testable import DownshiftProxy

@Suite struct HopByHopTests {
    @Test func hopByHopHeadersAreNotForwarded() {
        for name in ["connection", "transfer-encoding", "host", "content-length", "upgrade"] {
            #expect(hopByHopHeaders.contains(name))
        }
        #expect(!hopByHopHeaders.contains("authorization"))
    }
}
