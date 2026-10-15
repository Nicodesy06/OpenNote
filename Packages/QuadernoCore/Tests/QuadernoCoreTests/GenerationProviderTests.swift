import XCTest
@testable import QuadernoCore

final class AnthropicProviderTests: XCTestCase {
    func body(_ provider: AnthropicProvider, _ request: GenerationRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try provider.makeBody(request).encoded()) as! [String: Any]
    }

    func testBodyForDefaultModelIncludesFallbackEffortAndNoThinking() throws {
        let provider = AnthropicProvider(apiKey: "k", transport: MockTransport { _, _ in jsonResponse([:]) })
        let json = try body(provider, GenerationRequest(system: "S", messages: [.user("U")], maxOutputTokens: 32_000, effort: .high, stream: true))
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 32_000)
        XCTAssertEqual(json["system"] as? String, "S")
        XCTAssertEqual(json["fallbacks"] as? String, "default")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertNil(json["thinking"], "Il pensiero adattivo è predefinito: niente budget_tokens")
        XCTAssertNil(json["temperature"])
        let messages = json["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
    }

    func testOlderModelGetsNoFallbackOrEffort() throws {
        let provider = AnthropicProvider(apiKey: "k", model: "claude-haiku-4-5", transport: MockTransport { _, _ in jsonResponse([:]) })
        let json = try body(provider, GenerationRequest(system: "S", messages: [.user("U")], effort: .medium))
        XCTAssertNil(json["fallbacks"])
        XCTAssertNil(json["output_config"])
    }

    func testStructuredOutputSchema() throws {
        let provider = AnthropicProvider(apiKey: "k", transport: MockTransport { _, _ in jsonResponse([:]) })
        let json = try body(provider, GenerationRequest(system: "S", messages: [.user("U")], jsonSchema: SbobinaturaSchemas.outline))
        let format = (json["output_config"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual((format?["schema"] as? [String: Any])?["additionalProperties"] as? Bool, false)
    }

    func testNonStreamingRequestHeadersAndParsing() async throws {
        let transport = MockTransport { request, _ in
            XCTAssertEqual(request.headers["x-api-key"], "sk-ant")
            XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
            XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
            XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
            return jsonResponse([
                "model": "claude-opus-5-5",
                "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "Ciao "], ["type": "text", "text": "mondo"]],
                "stop_reason": "end_turn",
                "usage": ["input_tokens": 10, "output_tokens": 3]
            ])
        }
        let provider = AnthropicProvider(apiKey: "sk-ant", transport: transport)
        let result = try await provider.generate(GenerationRequest(system: "S", messages: [.user("U")]))
        XCTAssertEqual(result.text, "Ciao mondo")
        XCTAssertEqual(result.stopReason, .complete)
        XCTAssertEqual(result.usage, GenerationUsage(inputTokens: 10, outputTokens: 3))
    }

    func testStreamingAccumulatesTextAndUsage() async throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":1200}}}"#,
            "",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            ###"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"## Titolo\n\n"}}"###,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Paragrafo. [[S1-S2]]"}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#,
            #"data: {"type":"message_stop"}"#
        ]
        let transport = MockTransport { _, _ in jsonResponse([:]) }
        transport.streamHandler = { _, body in
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(json["stream"] as? Bool, true)
            return lines
        }
        let provider = AnthropicProvider(apiKey: "k", transport: transport)
        let deltas = DeltaRecorder()
        let result = try await provider.generate(GenerationRequest(system: "S", messages: [.user("U")], stream: true), onTextDelta: { deltas.append($0) })
        XCTAssertEqual(result.text, "## Titolo\n\nParagrafo. [[S1-S2]]")
        XCTAssertEqual(result.usage, GenerationUsage(inputTokens: 1200, outputTokens: 42))
        XCTAssertEqual(result.stopReason, .complete)
        XCTAssertEqual(deltas.values.count, 2)
    }

    func testStreamingErrorEventMapsToRetryableOverload() async {
        let transport = MockTransport { _, _ in jsonResponse([:]) }
        transport.streamHandler = { _, _ in [#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#] }
        let provider = AnthropicProvider(apiKey: "k", transport: transport)
        await XCTAssertThrowsErrorAsync(try await provider.generate(GenerationRequest(system: "S", messages: [.user("U")], stream: true))) { error in
            XCTAssertEqual(error as? AIServiceError, .serverUnavailable(status: 529))
            XCTAssertTrue((error as? AIServiceError)?.isRetryable == true)
        }
    }

    func testRefusalAndMaxTokensStopReasons() throws {
        let refusal = try AnthropicProvider.parseMessage(try JSONSerialization.data(withJSONObject: ["content": [], "stop_reason": "refusal", "stop_details": ["type": "refusal", "category": "bio"]]), requestedModel: "m")
        XCTAssertEqual(refusal.stopReason, .refusal)
        XCTAssertEqual(refusal.refusalCategory, "bio")
        let truncated = try AnthropicProvider.parseMessage(try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "abc"]], "stop_reason": "max_tokens"]), requestedModel: "m")
        XCTAssertEqual(truncated.stopReason, .maxTokens)
    }

    func testListModels() async throws {
        let transport = MockTransport { request, _ in
            XCTAssertTrue(request.url.absoluteString.hasPrefix("https://api.anthropic.com/v1/models"))
            return jsonResponse(["data": [["id": "claude-opus-5-5"], ["id": "claude-sonnet-5-5"]]])
        }
        let models = try await AnthropicProvider(apiKey: "k", transport: transport).listModels()
        XCTAssertEqual(models, ["claude-opus-5-5", "claude-sonnet-5-5"])
    }
}

final class OpenAIResponsesProviderTests: XCTestCase {
    func testBodyUsesStrictSchemaAndReasoningEffort() throws {
        let provider = OpenAIResponsesProvider(apiKey: "k", model: "gpt-6.1-sol", transport: MockTransport { _, _ in jsonResponse([:]) })
        let json = try JSONSerialization.jsonObject(with: try provider.makeBody(GenerationRequest(system: "S", messages: [.user("U")], maxOutputTokens: 9000, jsonSchema: SbobinaturaSchemas.verification, effort: .xhigh)).encoded()) as! [String: Any]
        XCTAssertEqual(json["instructions"] as? String, "S")
        XCTAssertEqual(json["max_output_tokens"] as? Int, 9000)
        XCTAssertEqual(json["store"] as? Bool, false, "Le lezioni non vengono conservate sul provider oltre il necessario")
        let format = (json["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        XCTAssertEqual(format?["name"] as? String, "section_verification")
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testParsesOutputItems() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-x", "status": "completed",
            "output": [["type": "reasoning"], ["type": "message", "content": [["type": "output_text", "text": "Ciao"], ["type": "output_text", "text": "!"]]]],
            "usage": ["input_tokens": 5, "output_tokens": 2]
        ])
        let result = try OpenAIResponsesProvider.parseResponse(data, requestedModel: "gpt-x")
        XCTAssertEqual(result.text, "Ciao!")
        XCTAssertEqual(result.stopReason, .complete)
        let incomplete = try OpenAIResponsesProvider.parseResponse(try JSONSerialization.data(withJSONObject: ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": []]), requestedModel: "x")
        XCTAssertEqual(incomplete.stopReason, .maxTokens)
    }

    func testStreamingEvents() async throws {
        let transport = MockTransport { _, _ in jsonResponse([:]) }
        transport.streamHandler = { _, _ in [
            "event: response.output_text.delta",
            #"data: {"type":"response.output_text.delta","delta":"Uno "}"#,
            #"data: {"type":"response.output_text.delta","delta":"due"}"#,
            #"data: {"type":"response.completed","response":{"status":"completed","model":"gpt-x","usage":{"input_tokens":7,"output_tokens":2}}}"#
        ] }
        let provider = OpenAIResponsesProvider(apiKey: "k", model: "gpt-x", transport: transport)
        let result = try await provider.generate(GenerationRequest(system: "S", messages: [.user("U")], stream: true))
        XCTAssertEqual(result.text, "Uno due")
        XCTAssertEqual(result.usage.outputTokens, 2)
        XCTAssertEqual(result.stopReason, .complete)
    }

    func testRequiresModelSelection() async {
        let provider = OpenAIResponsesProvider(apiKey: "k", model: "", transport: MockTransport { _, _ in jsonResponse([:]) })
        await XCTAssertThrowsErrorAsync(try await provider.generate(GenerationRequest(system: "S", messages: [.user("U")])))
    }

    func testModelSuggestionSkipsAudioAndDatedSnapshots() {
        let models = ["gpt-4o-transcribe", "gpt-transcribe", "gpt-5.5-2026-05-01", "gpt-5.5", "gpt-5.5-mini", "text-embedding-3-large", "tts-1"]
        XCTAssertEqual(OpenAIResponsesProvider.suggestTextModel(from: models), "gpt-5.5")
        XCTAssertEqual(OpenAIResponsesProvider.suggestTextModel(from: ["gpt-6-astra", "gpt-5.5"]), "gpt-6-astra")
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesDataAndEventLines() {
        var parser = SSELineParser()
        XCTAssertNil(parser.consume("event: message_start"))
        XCTAssertEqual(parser.consume("data: {\"a\":1}")?.data, "{\"a\":1}")
        XCTAssertEqual(parser.consume("data: {\"a\":1}")?.event, "message_start")
        XCTAssertNil(parser.consume(""))
        XCTAssertNil(parser.consume(": commento"))
        XCTAssertNil(parser.consume("data: x")?.event)
    }
}

final class DeltaRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
