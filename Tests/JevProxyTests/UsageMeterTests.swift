import JevCore
import NIOCore
import Testing
@testable import JevProxy

@Suite struct UsageMeterTests {
    /// Feeds `text` in chunks of `size` bytes.
    func read(_ text: String, chunk size: Int) -> UsageMeter.Reading? {
        var meter = UsageMeter()
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            meter.feed(ByteBuffer(bytes: bytes[index..<min(index + size, bytes.count)]))
            index += size
        }
        return meter.finish()
    }

    let messages = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","model":"claude-sonnet-5","usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":4000,"output_tokens":1}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":87}}

    event: message_stop
    data: {"type":"message_stop"}


    """

    @Test(arguments: [1, 7, 4096])
    func messagesStream(chunk: Int) {
        let reading = read(messages, chunk: chunk)
        #expect(reading == UsageMeter.Reading(model: "claude-sonnet-5",
                                              tokens: TokenUsage(input: 12, cacheWrite: 300, cacheRead: 4000, output: 87)))
        let crlf = read(messages.replacingOccurrences(of: "\n", with: "\r\n"), chunk: chunk)
        #expect(crlf == reading)
    }

    @Test(arguments: [1, 13, 4096])
    func responsesStream(chunk: Int) {
        let stream = """
        event: response.created
        data: {"type":"response.created","response":{"model":"gpt-6-luna","usage":null}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"hi"}

        event: response.completed
        data: {"type":"response.completed","response":{"model":"gpt-6-luna","usage":{"input_tokens":5000,"input_tokens_details":{"cached_tokens":4096,"cache_write_tokens":100},"output_tokens":42,"output_tokens_details":{"reasoning_tokens":30},"total_tokens":5042}}}

        """
        #expect(read(stream, chunk: chunk) == UsageMeter.Reading(model: "gpt-6-luna",
                                                                 tokens: TokenUsage(input: 804, cacheWrite: 100, cacheRead: 4096, output: 42)))
    }

    @Test func nonStreamedBodies() {
        let message = #"{"type":"message","model":"claude-opus-5","content":[],"usage":{"input_tokens":3,"output_tokens":9}}"#
        #expect(read(message, chunk: 5) == UsageMeter.Reading(model: "claude-opus-5", tokens: TokenUsage(input: 3, output: 9)))
        let response = #"{"object":"response","model":"gpt-6-sol","usage":{"input_tokens":10,"output_tokens":2}}"#
        #expect(read(response, chunk: 5) == UsageMeter.Reading(model: "gpt-6-sol", tokens: TokenUsage(input: 10, output: 2)))
    }

    @Test func noUsageReadsNothing() {
        #expect(read("event: ping\ndata: {}\n\n", chunk: 3) == nil)
        #expect(read("{}", chunk: 1) == nil)
        #expect(read("", chunk: 1) == nil)
    }

    @Test func aTruncatedStreamKeepsWhatWasBilledSoFar() {
        let cut = String(messages.prefix(through: messages.range(of: "content_block_delta")!.lowerBound))
        #expect(read(cut, chunk: 64)?.tokens == TokenUsage(input: 12, cacheWrite: 300, cacheRead: 4000, output: 1))
    }

    @Test func anOversizedEventStopsTheMeter() {
        var meter = UsageMeter()
        meter.feed(ByteBuffer(string: "event: content_block_delta\ndata: "))
        meter.feed(ByteBuffer(repeating: UInt8(ascii: "x"), count: UsageMeter.maxEvent + 1))
        meter.feed(ByteBuffer(string: "\n\n" + messages))
        #expect(meter.finish() == nil)
    }

    @Test func webSocketMessagesEndResponsesOnlyOnEndEvents() {
        let completed = #"{"type":"response.completed","response":{"model":"gpt-6-sol","usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":4},"output_tokens":3}}}"#
        let end = UsageMeter.readMessage(completed)
        #expect(end.ends)
        #expect(end.reading == UsageMeter.Reading(model: "gpt-6-sol", tokens: TokenUsage(input: 6, cacheRead: 4, output: 3)))
        #expect(UsageMeter.readMessage(#"{"type":"response.output_text.delta","delta":"\"completed\" \"error\""}"#) == (false, nil))
        #expect(UsageMeter.readMessage(#"{"type":"response.output_item.done","item":{}}"#) == (false, nil))
        #expect(UsageMeter.readMessage(#"{"type":"error","error":{"message":"rate limited"}}"#) == (true, nil))
        #expect(UsageMeter.readMessage(#"{"type":"response.failed","response":{"id":"r"}}"#) == (true, nil))
        #expect(UsageMeter.readMessage("not json completed\"") == (false, nil))
    }
}
