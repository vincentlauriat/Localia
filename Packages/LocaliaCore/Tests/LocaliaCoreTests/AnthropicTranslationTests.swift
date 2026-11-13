import XCTest
@testable import LocaliaCore

final class AnthropicTranslationTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    /// Decodes the SSE events the encoder produced: (event name, payload).
    private func events(_ parts: [Data]) -> [(String, [String: Any])] {
        let text = String(decoding: parts.reduce(Data(), +), as: UTF8.self)
        return text.components(separatedBy: "\n\n").filter { !$0.isEmpty }.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard lines.count == 2, lines[0].hasPrefix("event: "), lines[1].hasPrefix("data: "),
                  let obj = try? JSONSerialization.jsonObject(with: Data(lines[1].dropFirst(6).utf8)) as? [String: Any]
            else { XCTFail("bad SSE block: \(block)"); return nil }
            XCTAssertEqual(obj["type"] as? String, String(lines[0].dropFirst(7)))
            return (String(lines[0].dropFirst(7)), obj)
        }
    }

    /// Runs a recorded upstream SSE stream through the parser and the encoder.
    private func encode(_ sse: Data, chunkSize: Int = 7) -> [(String, [String: Any])] {
        var parser = SSEDataParser()
        var enc = AnthropicStreamEncoder(model: "mlx-community/Qwen3-8B-4bit", estimatedInputTokens: 50, messageID: "msg_test")
        var out = enc.start()
        var i = sse.startIndex
        while i < sse.endIndex {   // split mid-line, as a socket would
            let j = sse.index(i, offsetBy: chunkSize, limitedBy: sse.endIndex) ?? sse.endIndex
            for p in parser.feed(sse[i..<j]) where p != "[DONE]" {
                if let o = try? JSONSerialization.jsonObject(with: Data(p.utf8)) as? [String: Any] { out += enc.consume(o) }
            }
            i = j
        }
        return events(out + enc.finish())
    }

    // MARK: - Request

    func test_request_systemMessagesToolsAndParameters() throws {
        let body = json("""
        {"model":"claude-x","max_tokens":4096,"stream":true,"temperature":0.2,"top_k":20,"stop_sequences":["END"],
         "system":[{"type":"text","text":"You are Claude Code.","cache_control":{"type":"ephemeral"}},{"type":"text","text":"Be brief."}],
         "messages":[{"role":"user","content":"Read notes.txt"}],
         "tools":[{"name":"Read","description":"Read a file","input_schema":{"type":"object","properties":{"file_path":{"type":"string"}}}},
                  {"type":"web_search_20250305","name":"web_search"}],
         "tool_choice":{"type":"any"},
         "thinking":{"type":"enabled","budget_tokens":1024}}
        """)
        let r = try AnthropicTranslation.chatRequest(from: body, upstreamModel: "default_model")
        XCTAssertTrue(r.stream)
        XCTAssertEqual(r.clientModel, "claude-x")
        XCTAssertEqual(r.body["model"] as? String, "default_model")
        XCTAssertEqual(r.body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(r.body["top_k"] as? Int, 20)
        XCTAssertEqual(r.body["temperature"] as? Double, 0.2)
        XCTAssertNil(r.body["stop"], "stop sequences are matched by the gateway")
        XCTAssertEqual(r.stopSequences, ["END"])
        XCTAssertEqual((r.body["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual(r.body["tool_choice"] as? String, "required")
        let msgs = try XCTUnwrap(r.body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[0]["content"] as? String, "You are Claude Code.\nBe brief.")
        XCTAssertEqual(msgs[1]["content"] as? String, "Read notes.txt")
        let tools = try XCTUnwrap(r.body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1, "server tools cannot run locally")
        let f = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(f["name"] as? String, "Read")
        XCTAssertEqual(f["description"] as? String, "Read a file")
        XCTAssertNotNil(f["parameters"] as? [String: Any])
        XCTAssertNil(r.body["thinking"])
    }

    func test_request_toolUseAndToolResultsKeepOpenAIOrder() throws {
        let body = json("""
        {"model":"m","max_tokens":100,"messages":[
          {"role":"user","content":[{"type":"text","text":"Read two files"}]},
          {"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"x"},
             {"type":"text","text":"Reading."},
             {"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"a.txt"}},
             {"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"b.txt"}}]},
          {"role":"user","content":[
             {"type":"tool_result","tool_use_id":"toolu_1","content":"A"},
             {"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"not found"},{"type":"image","source":{}}]},
             {"type":"text","text":"Now summarize."}]}]}
        """)
        let r = try AnthropicTranslation.chatRequest(from: body, upstreamModel: "default_model")
        XCTAssertFalse(r.stream)
        XCTAssertNil(r.body["stream_options"])
        let msgs = try XCTUnwrap(r.body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(msgs[1]["content"] as? String, "Reading.")
        let calls = try XCTUnwrap(msgs[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["id"] as? String }, ["toolu_1", "toolu_2"])
        let fn = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "Read")
        let args = try XCTUnwrap(fn["arguments"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: String], ["file_path": "a.txt"])
        XCTAssertEqual(msgs[2]["tool_call_id"] as? String, "toolu_1")
        XCTAssertEqual(msgs[2]["content"] as? String, "A")
        XCTAssertEqual(msgs[3]["content"] as? String, "Error: not found\n" + AnthropicTranslation.imagePlaceholder)
        XCTAssertEqual(msgs[4]["content"] as? String, "Now summarize.")
    }

    func test_request_onlyToolResults_noTrailingEmptyUserMessage() throws {
        let body = json("""
        {"model":"m","max_tokens":10,"messages":[{"role":"user","content":"x"},
          {"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}]}
        """)
        let msgs = try XCTUnwrap(try AnthropicTranslation.chatRequest(from: body, upstreamModel: "d").body["messages"] as? [[String: Any]])
        XCTAssertEqual(msgs.map { $0["role"] as? String }, ["user", "assistant", "tool"])
        let calls = try XCTUnwrap(msgs[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual((calls[0]["function"] as? [String: Any])?["arguments"] as? String, "{}")
    }

    func test_request_hostileInputIsRejectedOrIgnored_neverCrashes() {
        let bad = ["", "[]", "null", "{\"messages\":5}", "{\"messages\":[1]}", "{\"messages\":[{\"role\":\"robot\",\"content\":\"x\"}]}",
                   "{\"messages\":[{\"role\":\"user\",\"content\":5}]}",
                   "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\"}]}]}",
                   "{\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\"}]}]}"]
        for b in bad {
            XCTAssertThrowsError(try AnthropicTranslation.chatRequest(from: json(b), upstreamModel: "d"), b)
        }
        // Absurd numbers are dropped, not trapped on.
        let r = try? AnthropicTranslation.chatRequest(from: json("""
        {"max_tokens":1e300,"top_k":-3,"temperature":true,"tools":[{"name":5},"x"],"tool_choice":"auto",
         "messages":[{"role":"user","content":[{"type":"unknown"},7,{"type":"text","text":"hi"}]}]}
        """), upstreamModel: "d")
        XCTAssertNotNil(r)
        XCTAssertNil(r?.body["max_tokens"])
        XCTAssertNil(r?.body["top_k"])
        XCTAssertNil(r?.body["temperature"])
        XCTAssertNil(r?.body["tools"])
    }

    // MARK: - Streaming (recorded mlx_lm 0.32.2 output)

    func test_stream_recordedToolCall_becomesToolUseBlock() throws {
        let ev = encode(try fixture("mlx-0.32.2-stream-toolcall.sse"))
        XCTAssertEqual(ev.map(\.0), ["message_start", "ping",
                                     "content_block_start", "content_block_delta", "content_block_delta", "content_block_delta",
                                     "content_block_delta", "content_block_delta", "content_block_stop",
                                     "content_block_start", "content_block_delta", "content_block_stop",
                                     "message_delta", "message_stop"])
        let msg = try XCTUnwrap(ev[0].1["message"] as? [String: Any])
        XCTAssertEqual(msg["id"] as? String, "msg_test")
        XCTAssertEqual(msg["model"] as? String, "mlx-community/Qwen3-8B-4bit")
        // Reasoning: a thinking block closed by an empty signature, like llama.cpp's endpoint.
        XCTAssertEqual((ev[2].1["content_block"] as? [String: Any])?["type"] as? String, "thinking")
        let thought = ev[3...6].compactMap { ($0.1["delta"] as? [String: Any])?["thinking"] as? String }.joined()
        XCTAssertEqual(thought, "\nOkay, the")
        XCTAssertEqual(ev[7].1["delta"] as? [String: String], ["type": "signature_delta", "signature": ""])
        let block = try XCTUnwrap(ev[9].1["content_block"] as? [String: Any])
        XCTAssertEqual(block["type"] as? String, "tool_use")
        XCTAssertEqual(block["name"] as? String, "Read")
        XCTAssertEqual(block["id"] as? String, "af81cad3-8214-4017-9c3c-27cd5a0b6528")
        XCTAssertEqual(ev[9].1["index"] as? Int, 1, "the whitespace between thinking and the call opens no block")
        let delta = try XCTUnwrap(ev[10].1["delta"] as? [String: Any])
        XCTAssertEqual(delta["type"] as? String, "input_json_delta")
        let input = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(delta["partial_json"] as? String).utf8)) as? [String: String]
        XCTAssertEqual(input, ["file_path": "/notes.txt"])
        let md = try XCTUnwrap(ev[12].1["delta"] as? [String: Any])
        XCTAssertEqual(md["stop_reason"] as? String, "tool_use")
        let usage = try XCTUnwrap(ev[12].1["usage"] as? [String: Int])
        XCTAssertEqual(usage, ["input_tokens": 177, "output_tokens": 270])
    }

    func test_stream_recordedText_becomesOneTextBlock() throws {
        let ev = encode(try fixture("mlx-0.32.2-stream-text.sse"), chunkSize: 1)
        XCTAssertEqual(ev.first?.0, "message_start")
        XCTAssertEqual(ev.filter { $0.0 == "content_block_start" }.count, 1)
        let text = ev.filter { $0.0 == "content_block_delta" }
            .compactMap { ($0.1["delta"] as? [String: Any])?["text"] as? String }.joined()
        XCTAssertEqual(text, "The secret word is **PAMPLEMOUSSE-42**.")
        let md = try XCTUnwrap(ev.first { $0.0 == "message_delta" }?.1)
        XCTAssertEqual((md["delta"] as? [String: Any])?["stop_reason"] as? String, "end_turn")
        XCTAssertEqual(ev.last?.0, "message_stop")
    }

    func test_stream_incrementalToolArguments_textThenTwoCalls() {
        var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 3, messageID: "msg_1")
        var out = enc.start()
        let chunks: [[String: Any]] = [
            ["choices": [["delta": ["content": "Let me check."]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "c1", "function": ["name": "Read", "arguments": "{\"file_"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "path\":\"a\"}"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 1, "function": ["name": "Glob"]]]]]]],
            ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
        ]
        for c in chunks { out += enc.consume(c) }
        let ev = events(out + enc.finish())
        XCTAssertEqual(ev.map(\.0), ["message_start", "ping",
                                     "content_block_start", "content_block_delta", "content_block_stop",
                                     "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop",
                                     "content_block_start", "content_block_delta", "content_block_stop",
                                     "message_delta", "message_stop"])
        XCTAssertEqual(ev.compactMap { $0.1["index"] as? Int }, [0, 0, 0, 1, 1, 1, 1, 2, 2, 2])
        let glob = ev[9].1["content_block"] as? [String: Any]
        XCTAssertTrue((glob?["id"] as? String)?.hasPrefix("toolu_") ?? false, "missing ids are generated")
        XCTAssertEqual((ev[10].1["delta"] as? [String: Any])?["partial_json"] as? String, "{}", "no arguments: empty object")
        XCTAssertEqual(((ev[12].1["delta"] as? [String: Any])?["stop_reason"]) as? String, "tool_use")
        XCTAssertEqual((ev[12].1["usage"] as? [String: Int])?["input_tokens"], 3, "estimate when upstream sends no usage")
    }

    func test_stream_lengthAndHostileChunks() {
        var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 1)
        var out: [Data] = []
        for c: [String: Any] in [["choices": "x"], ["choices": [5]], ["choices": [["delta": ["tool_calls": [7, ["function": 3]]]]]],
                                 ["usage": ["prompt_tokens": -4, "completion_tokens": 1e40]],
                                 ["choices": [["delta": ["content": "partial"], "finish_reason": "length"]]]] {
            out += enc.consume(c)
        }
        let ev = events(out + enc.finish() + enc.finish())
        XCTAssertEqual(ev.filter { $0.0 == "message_stop" }.count, 1, "finish is idempotent")
        let md = ev.first { $0.0 == "message_delta" }?.1
        XCTAssertEqual((md?["delta"] as? [String: Any])?["stop_reason"] as? String, "max_tokens")
        XCTAssertEqual((md?["usage"] as? [String: Int])?["output_tokens"], 0)
    }

    func test_stream_stopSequenceAcrossChunks_endsTurnWithStopSequence() {
        var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 1, stopSequences: ["</done>", "STOP"], messageID: "msg_1")
        var out = enc.start()
        for t in ["Result: 4", "2 </do", "ne> trailing", "more"] {
            out += enc.consume(["choices": [["delta": ["content": t]]]])
        }
        XCTAssertEqual(enc.matchedStop, "</done>")
        let ev = events(out + enc.finish())
        let text = ev.filter { $0.0 == "content_block_delta" }.compactMap { ($0.1["delta"] as? [String: Any])?["text"] as? String }.joined()
        XCTAssertEqual(text, "Result: 42 ")
        let md = ev.first { $0.0 == "message_delta" }?.1["delta"] as? [String: Any]
        XCTAssertEqual(md?["stop_reason"] as? String, "stop_sequence")
        XCTAssertEqual(md?["stop_sequence"] as? String, "</done>")
    }

    func test_stream_heldPrefixIsFlushedWhenNoStopFollows_andLeadingBlankIsKept() {
        var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 1, stopSequences: ["STOP"])
        var out = enc.start()
        for t in ["  ", "Hi ST", "ART"] { out += enc.consume(["choices": [["delta": ["content": t]]]]) }
        out += enc.consume(["choices": [["delta": [:], "finish_reason": "stop"]]])
        let ev = events(out + enc.finish())
        let text = ev.filter { $0.0 == "content_block_delta" }.compactMap { ($0.1["delta"] as? [String: Any])?["text"] as? String }.joined()
        XCTAssertEqual(text, "  Hi START", "blank prefix kept, held 'ST' released")
        XCTAssertEqual((ev.first { $0.0 == "message_delta" }?.1["delta"] as? [String: Any])?["stop_reason"] as? String, "end_turn")
        XCTAssertTrue(enc.sawFinishReason)
    }

    func test_stream_heldPrefixGoesBeforeAToolCall() {
        var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 1, stopSequences: ["STOP"])
        var out = enc.start()
        out += enc.consume(["choices": [["delta": ["content": "Done ST"]]]])
        out += enc.consume(["choices": [["delta": ["tool_calls": [["index": 0, "id": "t1", "function": ["name": "Read", "arguments": "{}"]]]]]]])
        out += enc.consume(["choices": [["delta": [:], "finish_reason": "tool_calls"]]])
        let ev = events(out + enc.finish())
        XCTAssertEqual(ev.map(\.0), ["message_start", "ping", "content_block_start", "content_block_delta", "content_block_delta",
                                     "content_block_stop", "content_block_start", "content_block_delta", "content_block_stop",
                                     "message_delta", "message_stop"])
        let text = ev[3...4].compactMap { ($0.1["delta"] as? [String: Any])?["text"] as? String }.joined()
        XCTAssertEqual(text, "Done ST", "the held 'ST' lands in the text block, before the tool call")
        XCTAssertEqual((ev[6].1["content_block"] as? [String: Any])?["type"] as? String, "tool_use")
    }

    func test_stopSequence_firstToComplete_sameInStreamAndWhole() throws {
        let stops = ["abcd", "c"]
        let whole = try AnthropicTranslation.message(
            fromChatCompletion: json(#"{"choices":[{"finish_reason":"stop","message":{"content":"xabcdy"}}]}"#),
            clientModel: "m", stopSequences: stops)
        XCTAssertEqual(whole["stop_sequence"] as? String, "c")
        XCTAssertEqual((whole["content"] as? [[String: Any]])?.first?["text"] as? String, "xab")
        for chunks in [["xabcdy"], ["x", "a", "b", "c", "d", "y"], ["xab", "cdy"]] {
            var enc = AnthropicStreamEncoder(model: "m", estimatedInputTokens: 1, stopSequences: stops)
            var out = enc.start()
            for t in chunks { out += enc.consume(["choices": [["delta": ["content": t]]]]) }
            XCTAssertEqual(enc.matchedStop, "c", "\(chunks)")
            let text = events(out + enc.finish()).filter { $0.0 == "content_block_delta" }
                .compactMap { ($0.1["delta"] as? [String: Any])?["text"] as? String }.joined()
            XCTAssertEqual(text, "xab", "\(chunks)")
        }
    }

    func test_nonStream_stopSequenceCutsText() throws {
        let data = json(#"{"choices":[{"finish_reason":"stop","message":{"content":"abc END def"}}]}"#)
        let m = try AnthropicTranslation.message(fromChatCompletion: data, clientModel: "m", stopSequences: ["END"])
        XCTAssertEqual(m["stop_reason"] as? String, "stop_sequence")
        XCTAssertEqual(m["stop_sequence"] as? String, "END")
        XCTAssertEqual((m["content"] as? [[String: Any]])?.first?["text"] as? String, "abc ")
    }

    func test_sseParser_ignoresCommentsAndHandlesCRLF() {
        var p = SSEDataParser()
        XCTAssertEqual(p.feed(Data(": keepalive 1/2\r\n\r\ndata: {\"a\":1}\r\n\r\nevent: x\ndata:".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(p.feed(Data("[DONE]\n".utf8)), ["[DONE]"])
    }

    // MARK: - Non-streamed

    func test_nonStream_recordedText() throws {
        let m = try AnthropicTranslation.message(fromChatCompletion: try fixture("mlx-0.32.2-nonstream-text.json"), clientModel: "local")
        XCTAssertEqual(m["type"] as? String, "message")
        XCTAssertEqual(m["model"] as? String, "local")
        XCTAssertEqual(m["stop_reason"] as? String, "end_turn")
        let content = try XCTUnwrap(m["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "The secret word is **PAMPLEMOUSSE-42**.")
        XCTAssertEqual(m["usage"] as? [String: Int], ["input_tokens": 220, "output_tokens": 16])
    }

    func test_nonStream_toolCalls() throws {
        let data = json("""
        {"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"x1","type":"function","function":{"name":"Read","arguments":"{\\"file_path\\":\\"a\\"}"}},
                        {"type":"function","function":{"name":"Bad","arguments":"not json"}}]}}]}
        """)
        let m = try AnthropicTranslation.message(fromChatCompletion: data, clientModel: "m")
        XCTAssertEqual(m["stop_reason"] as? String, "tool_use")
        let content = try XCTUnwrap(m["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["id"] as? String, "x1")
        XCTAssertEqual(content[0]["input"] as? [String: String], ["file_path": "a"])
        XCTAssertEqual((content[1]["input"] as? [String: Any])?.count, 0)
        XCTAssertThrowsError(try AnthropicTranslation.message(fromChatCompletion: json("{\"choices\":[]}"), clientModel: "m"))
    }

    func test_errorMapping() {
        XCTAssertEqual(AnthropicTranslation.errorMapping(upstreamStatus: 400).type, "invalid_request_error")
        XCTAssertEqual(AnthropicTranslation.errorMapping(upstreamStatus: 404).status, 404)
        XCTAssertEqual(AnthropicTranslation.errorMapping(upstreamStatus: 500).status, 502)
        let body = try? JSONSerialization.jsonObject(with: AnthropicTranslation.errorBody(type: "api_error", message: "x")) as? [String: Any]
        XCTAssertEqual(body?["type"] as? String, "error")
    }
}
