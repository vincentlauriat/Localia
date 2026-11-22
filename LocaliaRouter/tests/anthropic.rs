//! The Anthropic dialect and the chat-completions engine adapter, ported from the Swift
//! `AnthropicTranslationTests` and `AnthropicGatewayTests` (same names, in snake_case), plus golden streams.

mod common;

use axum::body::Bytes;
use common::stub::{ports, routed, routing, target, Reply, Stub};
use common::{is_id, pipeline, raw, spawn};
use localia_router::dialect::anthropic::{
    self, count_tokens, decode, encode_response, error_body, error_mapping, Encoder,
    DOCUMENT_PLACEHOLDER, IMAGE_PLACEHOLDER,
};
use localia_router::dialect::{DialectError, StreamEncoder};
use localia_router::engine::{
    chat_body, decode_chat_response, is_dead_generation, ChatStreamDecoder, EngineKind,
};
use localia_router::ir::{cut_at_stop, Part, Role, ToolChoice};
use localia_router::sse::SseParser;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

const QWEN: &str = "mlx-community/Qwen3-8B-4bit";

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/anthropic")
}

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(golden_dir().join("recorded").join(name)).unwrap()
}

/// Decodes the SSE events an encoder produced: (event name, payload).
fn events(parts: &[Bytes]) -> Vec<(String, Value)> {
    let text = String::from_utf8(parts.concat()).unwrap();
    text.split("\n\n")
        .filter(|b| !b.is_empty())
        .map(|block| {
            let lines: Vec<&str> = block.split('\n').collect();
            assert_eq!(lines.len(), 2, "bad SSE block: {block:?}");
            let name = lines[0].strip_prefix("event: ").expect(block);
            let data = lines[1].strip_prefix("data: ").expect(block);
            let obj: Value = serde_json::from_str(data).expect(block);
            assert_eq!(obj["type"], name, "{block}");
            (name.to_string(), obj)
        })
        .collect()
}

fn names(ev: &[(String, Value)]) -> Vec<&str> {
    ev.iter().map(|(n, _)| n.as_str()).collect()
}

fn texts(ev: &[(String, Value)]) -> String {
    ev.iter()
        .filter(|(n, _)| n == "content_block_delta")
        .filter_map(|(_, o)| o["delta"]["text"].as_str())
        .collect()
}

fn message_delta(ev: &[(String, Value)]) -> Value {
    ev.iter()
        .find(|(n, _)| n == "message_delta")
        .map(|(_, o)| o.clone())
        .expect("no message_delta")
}

/// Chat chunks (as the engine would send them) through the decoder and an encoder, without the final events.
fn consume(dec: &mut ChatStreamDecoder, enc: &mut Encoder, chunks: &[Value]) -> Vec<Bytes> {
    let mut out = Vec::new();
    for c in chunks {
        for e in dec.feed(&c.to_string()) {
            out.extend(enc.event(&e));
        }
    }
    out
}

fn text_chunk(t: &str) -> Value {
    json!({"choices": [{"delta": {"content": t}}]})
}

fn body(s: &str) -> Vec<u8> {
    s.as_bytes().to_vec()
}

// MARK: - Request

#[test]
fn request_system_messages_tools_and_parameters() {
    let b = body(
        r#"{"model":"claude-x","max_tokens":4096,"stream":true,"temperature":0.2,"top_k":20,"stop_sequences":["END"],
         "system":[{"type":"text","text":"You are Claude Code.","cache_control":{"type":"ephemeral"}},{"type":"text","text":"Be brief."}],
         "messages":[{"role":"user","content":"Read notes.txt"}],
         "tools":[{"name":"Read","description":"Read a file","input_schema":{"type":"object","properties":{"file_path":{"type":"string"}}}},
                  {"type":"web_search_20250305","name":"web_search"}],
         "tool_choice":{"type":"any"},
         "thinking":{"type":"enabled","budget_tokens":1024}}"#,
    );
    let r = decode(&b).unwrap();
    assert!(r.stream);
    assert_eq!(r.stop, vec!["END".to_string()]);
    assert_eq!(r.tool_choice, ToolChoice::Required);
    let c = chat_body(&r, EngineKind::Mlx, QWEN);
    assert_eq!(c["model"], "default_model");
    assert_eq!(c["max_tokens"], 4096);
    assert_eq!(c["top_k"], 20);
    assert_eq!(c["temperature"], 0.2);
    assert!(
        c.get("stop").is_none(),
        "stop sequences are matched by the router"
    );
    assert_eq!(c["stream"], true);
    assert_eq!(c["stream_options"]["include_usage"], true);
    assert_eq!(c["tool_choice"], "required");
    let msgs = c["messages"].as_array().unwrap();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0]["role"], "system");
    assert_eq!(msgs[0]["content"], "You are Claude Code.\nBe brief.");
    assert_eq!(msgs[1]["content"], "Read notes.txt");
    let tools = c["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 1, "server tools cannot run locally");
    assert_eq!(tools[0]["type"], "function");
    assert_eq!(tools[0]["function"]["name"], "Read");
    assert_eq!(tools[0]["function"]["description"], "Read a file");
    assert!(tools[0]["function"]["parameters"].is_object());
    assert!(c.get("thinking").is_none());
}

#[test]
fn request_tool_use_and_tool_results_keep_open_ai_order() {
    let b = body(
        r#"{"model":"m","max_tokens":100,"messages":[
          {"role":"user","content":[{"type":"text","text":"Read two files"}]},
          {"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"x"},
             {"type":"text","text":"Reading."},
             {"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"a.txt"}},
             {"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"b.txt"}}]},
          {"role":"user","content":[
             {"type":"tool_result","tool_use_id":"toolu_1","content":"A"},
             {"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":[{"type":"text","text":"not found"},{"type":"image","source":{}}]},
             {"type":"text","text":"Now summarize."}]}]}"#,
    );
    let r = decode(&b).unwrap();
    assert!(!r.stream);
    // Earlier thinking is dropped from assistant turns.
    assert!(!r.messages[1]
        .parts
        .iter()
        .any(|p| matches!(p, Part::Thinking(_))));
    let c = chat_body(&r, EngineKind::Mlx, "x");
    assert!(c.get("stream_options").is_none());
    let msgs = c["messages"].as_array().unwrap();
    let roles: Vec<&str> = msgs.iter().map(|m| m["role"].as_str().unwrap()).collect();
    assert_eq!(roles, ["user", "assistant", "tool", "tool", "user"]);
    assert_eq!(msgs[1]["content"], "Reading.");
    let calls = msgs[1]["tool_calls"].as_array().unwrap();
    let ids: Vec<&str> = calls.iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["toolu_1", "toolu_2"]);
    assert_eq!(calls[0]["type"], "function");
    assert_eq!(calls[0]["function"]["name"], "Read");
    let args: Value =
        serde_json::from_str(calls[0]["function"]["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(args, json!({"file_path": "a.txt"}));
    assert_eq!(msgs[2]["tool_call_id"], "toolu_1");
    assert_eq!(msgs[2]["content"], "A");
    assert_eq!(
        msgs[3]["content"],
        format!("Error: not found\n{IMAGE_PLACEHOLDER}")
    );
    assert_eq!(msgs[4]["content"], "Now summarize.");
}

#[test]
fn request_only_tool_results_no_trailing_empty_user_message() {
    let b = body(
        r#"{"model":"m","max_tokens":10,"messages":[{"role":"user","content":"x"},
          {"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}]}"#,
    );
    let r = decode(&b).unwrap();
    assert_eq!(r.messages[2].role, Role::Tool);
    let c = chat_body(&r, EngineKind::Mlx, "d");
    let msgs = c["messages"].as_array().unwrap();
    let roles: Vec<&str> = msgs.iter().map(|m| m["role"].as_str().unwrap()).collect();
    assert_eq!(roles, ["user", "assistant", "tool"]);
    assert_eq!(msgs[1]["tool_calls"][0]["function"]["arguments"], "{}");
}

#[test]
fn request_hostile_input_is_rejected_or_ignored_never_crashes() {
    let bad = [
        "",
        "[]",
        "null",
        r#"{"messages":5}"#,
        r#"{"messages":[1]}"#,
        r#"{"messages":[{"role":"robot","content":"x"}]}"#,
        r#"{"messages":[{"role":"user","content":5}]}"#,
        r#"{"messages":[{"role":"user","content":[{"type":"tool_result"}]}]}"#,
        r#"{"messages":[{"role":"assistant","content":[{"type":"tool_use"}]}]}"#,
    ];
    for b in bad {
        assert!(decode(b.as_bytes()).is_err(), "{b}");
    }
    assert_eq!(
        decode(br#"{"messages":[{"role":"robot","content":"x"}]}"#),
        Err(DialectError::Invalid(
            "messages.0.role: unexpected value robot".into()
        ))
    );
    // Absurd numbers are dropped, not trapped on.
    let r = decode(
        br#"{"max_tokens":1e300,"top_k":-3,"temperature":true,"tools":[{"name":5},"x"],"tool_choice":"auto",
         "messages":[{"role":"user","content":[{"type":"unknown"},7,{"type":"text","text":"hi"}]}]}"#,
    )
    .unwrap();
    let c = chat_body(&r, EngineKind::Mlx, "d");
    assert!(c.get("max_tokens").is_none());
    assert!(c.get("top_k").is_none());
    assert!(c.get("temperature").is_none());
    assert!(c.get("tools").is_none());
    assert_eq!(c["messages"][0]["content"], "hi");
}

// MARK: - Streaming (recorded mlx_lm 0.32.2 output)

#[test]
fn stream_recorded_tool_call_becomes_tool_use_block() {
    let ev = events(&pipeline(
        &fixture("mlx-0.32.2-stream-toolcall.sse"),
        7,
        &[],
        Encoder::new(QWEN).with_input_tokens(50),
    ));
    // The recording's two `: keepalive` lines each become a `ping` (the Swift gateway's rule).
    assert_eq!(
        names(&ev),
        [
            "message_start",
            "ping",
            "ping",
            "ping",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_delta",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop"
        ]
    );
    // Without the keepalive pings, the indices below are those of the stream itself.
    let mut ev = ev;
    ev.drain(2..4);
    let msg = &ev[0].1["message"];
    assert!(is_id(msg["id"].as_str().unwrap(), "msg_"), "{msg}");
    assert_eq!(msg["model"], QWEN);
    // Reasoning: a thinking block closed by an empty signature, like llama.cpp's endpoint.
    assert_eq!(ev[2].1["content_block"]["type"], "thinking");
    let thought: String = ev[3..7]
        .iter()
        .filter_map(|(_, o)| o["delta"]["thinking"].as_str())
        .collect();
    assert_eq!(thought, "\nOkay, the");
    assert_eq!(
        ev[7].1["delta"],
        json!({"type": "signature_delta", "signature": ""})
    );
    let block = &ev[9].1["content_block"];
    assert_eq!(block["type"], "tool_use");
    assert_eq!(block["name"], "Read");
    assert_eq!(block["id"], "af81cad3-8214-4017-9c3c-27cd5a0b6528");
    assert_eq!(
        ev[9].1["index"], 1,
        "the whitespace between thinking and the call opens no block"
    );
    let delta = &ev[10].1["delta"];
    assert_eq!(delta["type"], "input_json_delta");
    let input: Value = serde_json::from_str(delta["partial_json"].as_str().unwrap()).unwrap();
    assert_eq!(input, json!({"file_path": "/notes.txt"}));
    assert_eq!(ev[12].1["delta"]["stop_reason"], "tool_use");
    assert_eq!(
        ev[12].1["usage"],
        json!({"input_tokens": 177, "output_tokens": 270})
    );
}

#[test]
fn stream_recorded_text_becomes_one_text_block() {
    let ev = events(&pipeline(
        &fixture("mlx-0.32.2-stream-text.sse"),
        1,
        &[],
        Encoder::new(QWEN).with_input_tokens(50),
    ));
    assert_eq!(ev[0].0, "message_start");
    assert_eq!(
        ev.iter()
            .filter(|(n, _)| n == "content_block_start")
            .count(),
        1
    );
    assert_eq!(texts(&ev), "The secret word is **PAMPLEMOUSSE-42**.");
    assert_eq!(message_delta(&ev)["delta"]["stop_reason"], "end_turn");
    assert_eq!(ev.last().unwrap().0, "message_stop");
}

#[test]
fn stream_incremental_tool_arguments_text_then_two_calls() {
    let mut dec = ChatStreamDecoder::new(&[]);
    let mut enc = Encoder::new("m").with_input_tokens(3);
    let mut out = enc.start();
    out.extend(consume(
        &mut dec,
        &mut enc,
        &[
            json!({"choices": [{"delta": {"content": "Let me check."}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "c1", "function": {"name": "Read", "arguments": "{\"file_"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": "path\":\"a\"}"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 1, "function": {"name": "Glob"}}]}}]}),
            json!({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}),
        ],
    ));
    out.extend(enc.finish());
    let ev = events(&out);
    assert_eq!(
        names(&ev),
        [
            "message_start",
            "ping",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop"
        ]
    );
    let indices: Vec<i64> = ev.iter().filter_map(|(_, o)| o["index"].as_i64()).collect();
    assert_eq!(indices, [0, 0, 0, 1, 1, 1, 1, 2, 2, 2]);
    let glob = &ev[9].1["content_block"];
    assert!(
        is_id(glob["id"].as_str().unwrap(), "toolu_"),
        "missing ids are generated"
    );
    assert_eq!(
        ev[10].1["delta"]["partial_json"], "{}",
        "no arguments: empty object"
    );
    assert_eq!(ev[12].1["delta"]["stop_reason"], "tool_use");
    assert_eq!(
        ev[12].1["usage"]["input_tokens"], 3,
        "estimate when upstream sends no usage"
    );
}

#[test]
fn stream_length_and_hostile_chunks() {
    let mut dec = ChatStreamDecoder::new(&[]);
    let mut enc = Encoder::new("m").with_input_tokens(1);
    let mut out = consume(
        &mut dec,
        &mut enc,
        &[
            json!({"choices": "x"}),
            json!({"choices": [5]}),
            json!({"choices": [{"delta": {"tool_calls": [7, {"function": 3}]}}]}),
            json!({"usage": {"prompt_tokens": -4, "completion_tokens": 1e40}}),
            json!({"choices": [{"delta": {"content": "partial"}, "finish_reason": "length"}]}),
        ],
    );
    // Not JSON, or not an object: skipped.
    assert!(dec.feed("{oops").is_empty());
    assert!(dec.feed("[1,2]").is_empty());
    out.extend(enc.finish());
    out.extend(enc.finish());
    let ev = events(&out);
    assert_eq!(
        ev.iter().filter(|(n, _)| n == "message_stop").count(),
        1,
        "finish is idempotent"
    );
    let md = message_delta(&ev);
    assert_eq!(md["delta"]["stop_reason"], "max_tokens");
    assert_eq!(md["usage"]["output_tokens"], 0);
}

#[test]
fn stream_stop_sequence_across_chunks_ends_turn_with_stop_sequence() {
    let stops = vec!["</done>".to_string(), "STOP".to_string()];
    let mut dec = ChatStreamDecoder::new(&stops);
    let mut enc = Encoder::new("m").with_input_tokens(1);
    let mut out = enc.start();
    let chunks: Vec<Value> = ["Result: 4", "2 </do", "ne> trailing", "more"]
        .iter()
        .map(|t| text_chunk(t))
        .collect();
    out.extend(consume(&mut dec, &mut enc, &chunks));
    assert_eq!(dec.matched_stop(), Some("</done>"));
    out.extend(enc.finish());
    let ev = events(&out);
    assert_eq!(texts(&ev), "Result: 42 ");
    let md = message_delta(&ev);
    assert_eq!(md["delta"]["stop_reason"], "stop_sequence");
    assert_eq!(md["delta"]["stop_sequence"], "</done>");
}

#[test]
fn stream_held_prefix_is_flushed_when_no_stop_follows_and_leading_blank_is_kept() {
    let mut dec = ChatStreamDecoder::new(&["STOP".to_string()]);
    let mut enc = Encoder::new("m").with_input_tokens(1);
    let mut out = enc.start();
    let mut chunks: Vec<Value> = ["  ", "Hi ST", "ART"]
        .iter()
        .map(|t| text_chunk(t))
        .collect();
    chunks.push(json!({"choices": [{"delta": {}, "finish_reason": "stop"}]}));
    out.extend(consume(&mut dec, &mut enc, &chunks));
    out.extend(enc.finish());
    let ev = events(&out);
    assert_eq!(
        texts(&ev),
        "  Hi START",
        "blank prefix kept, held 'ST' released"
    );
    assert_eq!(message_delta(&ev)["delta"]["stop_reason"], "end_turn");
    assert!(dec.saw_end());
}

#[test]
fn stream_held_prefix_goes_before_a_tool_call() {
    let mut dec = ChatStreamDecoder::new(&["STOP".to_string()]);
    let mut enc = Encoder::new("m").with_input_tokens(1);
    let mut out = enc.start();
    out.extend(consume(
        &mut dec,
        &mut enc,
        &[
            text_chunk("Done ST"),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "t1", "function": {"name": "Read", "arguments": "{}"}}]}}]}),
            json!({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}),
        ],
    ));
    out.extend(enc.finish());
    let ev = events(&out);
    assert_eq!(
        names(&ev),
        [
            "message_start",
            "ping",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "content_block_start",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop"
        ]
    );
    assert_eq!(
        texts(&ev[3..5]),
        "Done ST",
        "the held 'ST' lands in the text block, before the tool call"
    );
    assert_eq!(ev[6].1["content_block"]["type"], "tool_use");
}

#[test]
fn stop_sequence_first_to_complete_same_in_stream_and_whole() {
    let stops = vec!["abcd".to_string(), "c".to_string()];
    let mut whole = decode_chat_response(
        br#"{"choices":[{"finish_reason":"stop","message":{"content":"xabcdy"}}]}"#,
    )
    .unwrap();
    cut_at_stop(&mut whole, &stops);
    let m = encode_response(&whole, "m");
    assert_eq!(m["stop_sequence"], "c");
    assert_eq!(m["content"][0]["text"], "xab");
    for chunks in [
        vec!["xabcdy"],
        vec!["x", "a", "b", "c", "d", "y"],
        vec!["xab", "cdy"],
    ] {
        let mut dec = ChatStreamDecoder::new(&stops);
        let mut enc = Encoder::new("m").with_input_tokens(1);
        let mut out = enc.start();
        let cs: Vec<Value> = chunks.iter().map(|t| text_chunk(t)).collect();
        out.extend(consume(&mut dec, &mut enc, &cs));
        assert_eq!(dec.matched_stop(), Some("c"), "{chunks:?}");
        out.extend(enc.finish());
        assert_eq!(texts(&events(&out)), "xab", "{chunks:?}");
    }
}

#[test]
fn non_stream_stop_sequence_cuts_text() {
    let mut r = decode_chat_response(
        br#"{"choices":[{"finish_reason":"stop","message":{"content":"abc END def"}}]}"#,
    )
    .unwrap();
    cut_at_stop(&mut r, &["END".to_string()]);
    let m = encode_response(&r, "m");
    assert_eq!(m["stop_reason"], "stop_sequence");
    assert_eq!(m["stop_sequence"], "END");
    assert_eq!(m["content"][0]["text"], "abc ");
}

#[test]
fn sse_parser_ignores_comments_and_handles_crlf() {
    let mut p = SseParser::new();
    assert_eq!(
        p.feed(b": keepalive 1/2\r\n\r\ndata: {\"a\":1}\r\n\r\nevent: x\ndata:"),
        vec!["{\"a\":1}".to_string()]
    );
    assert_eq!(p.feed(b"[DONE]\n"), vec!["[DONE]".to_string()]);
    // A line longer than the cap is dropped whole, and parsing goes on after it.
    let mut p = SseParser::new();
    let mut big = b"data: ".to_vec();
    big.extend(std::iter::repeat_n(b'x', SseParser::MAX_LINE_BYTES + 1));
    assert!(p.feed(&big).is_empty());
    assert!(p.feed(b"xxx\ndata: ok\n").contains(&"ok".to_string()));
}

// MARK: - Non-streamed

#[test]
fn non_stream_recorded_text() {
    let r = decode_chat_response(&fixture("mlx-0.32.2-nonstream-text.json")).unwrap();
    let m = encode_response(&r, "local");
    assert_eq!(m["type"], "message");
    assert_eq!(m["role"], "assistant");
    assert!(is_id(m["id"].as_str().unwrap(), "msg_"));
    assert_eq!(m["model"], "local");
    assert_eq!(m["stop_reason"], "end_turn");
    assert_eq!(m["stop_sequence"], Value::Null);
    assert_eq!(
        m["content"][0]["text"],
        "The secret word is **PAMPLEMOUSSE-42**."
    );
    assert_eq!(
        m["usage"],
        json!({"input_tokens": 220, "output_tokens": 16})
    );
}

#[test]
fn non_stream_tool_calls() {
    let data = br#"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,
      "tool_calls":[{"id":"x1","type":"function","function":{"name":"Read","arguments":"{\"file_path\":\"a\"}"}},
                    {"type":"function","function":{"name":"Bad","arguments":"not json"}}]}}]}"#;
    let m = encode_response(&decode_chat_response(data).unwrap(), "m");
    assert_eq!(m["stop_reason"], "tool_use");
    let content = m["content"].as_array().unwrap();
    assert_eq!(content.len(), 2);
    assert_eq!(content[0]["type"], "tool_use");
    assert_eq!(content[0]["id"], "x1");
    assert_eq!(content[0]["input"], json!({"file_path": "a"}));
    assert!(is_id(content[1]["id"].as_str().unwrap(), "toolu_"));
    assert_eq!(content[1]["input"], json!({}));
    assert!(decode_chat_response(br#"{"choices":[]}"#).is_err());
}

#[test]
fn error_mapping_maps_upstream_statuses() {
    assert_eq!(error_mapping(400), (400, "invalid_request_error"));
    assert_eq!(error_mapping(422), (400, "invalid_request_error"));
    assert_eq!(error_mapping(404), (404, "not_found_error"));
    assert_eq!(error_mapping(413), (413, "request_too_large"));
    assert_eq!(error_mapping(429), (429, "rate_limit_error"));
    assert_eq!(error_mapping(500), (502, "api_error"));
    let b = error_body("api_error", "x");
    assert_eq!(
        b,
        json!({"type": "error", "error": {"type": "api_error", "message": "x"}})
    );
}

// MARK: - Gateway behaviour (AnthropicGatewayTests)
//
// The HTTP route for `/v1/messages` arrives with the relay (Task 8). Until then, the gateway tests that are about
// translation run against the translation pipeline, the ones about the loopback server against `serve`, and the
// ones that need an upstream engine are kept, ignored, under their names.

const SIMPLE: &str =
    r#"{"model":"local","max_tokens":64,"messages":[{"role":"user","content":"hi"}]"#;

#[test]
fn streamed_messages_translates_recorded_upstream() {
    let r = decode(format!(r#"{SIMPLE},"stream":true}}"#).as_bytes()).unwrap();
    let sent = chat_body(&r, EngineKind::Mlx, QWEN);
    assert_eq!(sent["model"], "default_model");
    assert_eq!(sent["stream"], true);
    let out = pipeline(
        &fixture("mlx-0.32.2-stream-text.sse"),
        64,
        &r.stop.iter().map(String::as_str).collect::<Vec<_>>(),
        Encoder::new("local"),
    );
    let text = String::from_utf8(out.concat()).unwrap();
    assert!(text.starts_with("event: message_start"));
    assert!(text.contains("AMPLE"));
    assert!(text.ends_with("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"));
}

#[test]
fn non_streamed_messages() {
    let r = decode(format!("{SIMPLE}}}").as_bytes()).unwrap();
    assert!(!r.stream);
    let m = encode_response(
        &decode_chat_response(&fixture("mlx-0.32.2-nonstream-text.json")).unwrap(),
        "local",
    );
    assert_eq!(m["model"], "local");
    assert_eq!(
        m["content"][0]["text"],
        "The secret word is **PAMPLEMOUSSE-42**."
    );
}

#[tokio::test]
async fn upstream_errors_become_anthropic_errors() {
    let (status, kind) = error_mapping(500);
    assert_eq!(status, 502);
    let b = error_body(kind, "boom").to_string();
    assert!(b.contains(r#""type":"api_error""#) && b.contains("boom"));
    assert!(b.contains(r#""type":"error""#));
    // Not a chat completion at all: an error the relay answers 502 with.
    assert!(decode_chat_response(b"<html>bad gateway</html>").is_err());

    // Over HTTP, through the router's MLX routes.
    let (mlx, h) = mlx_router().await;
    mlx.on(|_| Reply::status(500, r#"{"error":"boom"}"#));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 502);
    assert_eq!(
        common::anthropic_error(&r),
        ("api_error".into(), "boom".into())
    );
    mlx.on(|_| Reply::status(400, r#"{"error":{"message":"bad request"}}"#));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 400);
    assert_eq!(
        common::anthropic_error(&r),
        ("invalid_request_error".into(), "bad request".into())
    );
    mlx.on(|_| Reply::status(500, "<html>no</html>"));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(
        common::anthropic_error(&r).1,
        "The local model server answered HTTP 500."
    );
    // A whole answer that is no chat completion.
    mlx.on(|_| Reply::json("<html>bad gateway</html>"));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 502);
    assert!(common::anthropic_error(&r)
        .1
        .starts_with("The local model server did not answer"));
}

const SIMPLE_BODY: &str =
    r#"{"model":"local","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#;

fn mlx_path(rest: &str) -> String {
    format!("/s/sess-1/mlx{rest}")
}

/// An MLX stub and a router whose active model is on it.
async fn mlx_router() -> (Stub, common::Harness) {
    let mlx = Stub::start(EngineKind::Mlx, &[]).await;
    let h = routed(
        ports(Stub::dead_port().await, Stub::dead_port().await, mlx.port),
        Some(routing(
            Some(target(EngineKind::Mlx, QWEN, 32768)),
            vec![],
            Some(QWEN),
        )),
        false,
        None,
    )
    .await;
    (mlx, h)
}

#[tokio::test]
async fn health_follows_upstream_and_count_tokens_and_models() {
    let simple = format!("{SIMPLE}}}");
    assert_eq!(count_tokens(simple.as_bytes()), simple.len() as u64 / 4);
    assert_eq!(count_tokens(b""), 1);
    assert_eq!(count_tokens(b"abc"), 1);

    let (mlx, h) = mlx_router().await;
    let r = common::send(h.port, "GET", &mlx_path("/health"), &[], b"").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json(), json!({"status": "ok"}));
    mlx.health.store(503, std::sync::atomic::Ordering::SeqCst);
    let r = common::send(h.port, "GET", &mlx_path("/health"), &[], b"").await;
    assert_eq!(r.status, 503);
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages/count_tokens"),
        &[],
        simple.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json(), json!({"input_tokens": simple.len() / 4}));
    let r = common::send(h.port, "GET", &mlx_path("/v1/models"), &[], b"").await;
    assert_eq!(r.status, 200);
    let models = r.json();
    assert_eq!(models["object"], "list");
    assert_eq!(models["data"].as_array().unwrap().len(), 1);
    assert_eq!(models["data"][0]["id"], QWEN);
    assert_eq!(models["data"][0]["owned_by"], "localia");
    assert!(mlx.seen().is_empty(), "none of these reach the engine");
}

#[tokio::test]
async fn bad_requests_are_refused_and_gateway_keeps_serving() {
    let h = spawn(|_| {}).await;
    let p = h.port;
    let too_big = raw(
        p,
        format!("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\nContent-Length: 999999999\r\n\r\n")
            .as_bytes(),
    )
    .await;
    assert_eq!(too_big.status, 413);
    let chunked = raw(
        p,
        format!("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
            .as_bytes(),
    )
    .await;
    assert_eq!(chunked.status, 411);
    let bad_length = raw(
        p,
        format!("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\nContent-Length: -1\r\n\r\n")
            .as_bytes(),
    )
    .await;
    assert_eq!(bad_length.status, 400);
    let garbage = raw_text(p, b"\x00\x01\x02\r\n\r\n").await;
    assert!(garbage.starts_with("HTTP/1.1 400"), "{garbage:?}");
    let mut flood = format!("GET / HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\nX: ").into_bytes();
    flood.extend(std::iter::repeat_n(b'a', 70_000));
    let flood = raw_text(p, &flood).await;
    assert!(flood.starts_with("HTTP/1.1 431"), "{flood:?}");
    // A body that is not JSON is the dialect's 400, and the gateway keeps serving.
    let e = decode(b"{not json").unwrap_err();
    assert_eq!(e.message(), "Request body must be a JSON object.");
    for path in ["/s/sess-1/mlx/v1/messages", "/s/sess-1/auto/v1/messages"] {
        let r = common::send(p, "POST", path, &[], b"{not json").await;
        assert_eq!(r.status, 400, "{path}");
        assert_eq!(
            common::anthropic_error(&r),
            (
                "invalid_request_error".into(),
                "Request body must be a JSON object.".into()
            ),
            "{path}"
        );
        let r = common::send(
            p,
            "POST",
            "/s/sess-1/auto/v1/messages/count_tokens",
            &[],
            SIMPLE_BODY.as_bytes(),
        )
        .await;
        assert_eq!(r.status, 200);
    }
    let r = common::send(p, "POST", "/v2/other", &[], b"{}").await;
    assert_eq!(r.status, 404);
    // Still alive after all that.
    let r = common::send(p, "GET", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 200);
}

#[tokio::test]
async fn browser_requests_are_forbidden() {
    let h = spawn(|_| {}).await;
    let p = h.port;
    let r = common::send(
        p,
        "POST",
        "/v1/messages/count_tokens",
        &[("Origin", "https://evil.example")],
        format!("{SIMPLE}}}").as_bytes(),
    )
    .await;
    assert_eq!(r.status, 403);
    let rebound = raw_text(
        p,
        format!("GET /localia/health HTTP/1.1\r\nHost: evil.example:{p}\r\n\r\n").as_bytes(),
    )
    .await;
    assert!(rebound.starts_with("HTTP/1.1 403"), "{rebound}");
    let no_host = raw_text(p, b"GET /localia/health HTTP/1.1\r\n\r\n").await;
    assert!(no_host.starts_with("HTTP/1.1 403"), "{no_host}");
    let local = raw_text(
        p,
        format!("GET /localia/health HTTP/1.1\r\nHost: localhost:{p}\r\n\r\n").as_bytes(),
    )
    .await;
    assert!(local.starts_with("HTTP/1.1 200"), "{local}");
}

#[tokio::test]
async fn slow_client_is_dropped_and_connections_are_capped() {
    let h = spawn(|c| {
        c.read_timeout = Duration::from_millis(500);
        c.max_connections = 1;
    })
    .await;
    let p = h.port;
    // One client holds the only slot without finishing its headers.
    let mut slow = TcpStream::connect(("127.0.0.1", p)).await.unwrap();
    slow.write_all(b"GET /localia/health HTTP/1.1\r\nHost: 127.0")
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    let refused = raw_text(
        p,
        format!("GET /localia/health HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n").as_bytes(),
    )
    .await;
    assert!(refused.starts_with("HTTP/1.1 503"), "{refused}");
    // The deadline closes the slow one without an answer, and frees the slot.
    let mut got = Vec::new();
    tokio::time::timeout(Duration::from_secs(3), slow.read_to_end(&mut got))
        .await
        .expect("slow client still connected")
        .ok();
    assert!(!String::from_utf8_lossy(&got).contains(" 200 "), "{got:?}");
    drop(slow);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let ok = raw_text(
        p,
        format!("GET /localia/health HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n").as_bytes(),
    )
    .await;
    assert!(ok.starts_with("HTTP/1.1 200"), "{ok}");
}

#[tokio::test]
async fn refusals_are_capped_too() {
    let h = spawn(|c| {
        c.read_timeout = Duration::from_secs(2);
        c.max_connections = 1;
    })
    .await;
    let p = h.port;
    let served = TcpStream::connect(("127.0.0.1", p)).await.unwrap(); // holds the only slot, sends nothing
    tokio::time::sleep(Duration::from_millis(100)).await;
    let refusing = TcpStream::connect(("127.0.0.1", p)).await.unwrap(); // holds the only refusal
    tokio::time::sleep(Duration::from_millis(100)).await;
    let start = Instant::now();
    let third = raw_text(
        p,
        format!("GET /localia/health HTTP/1.1\r\nHost: 127.0.0.1:{p}\r\n\r\n").as_bytes(),
    )
    .await;
    assert_eq!(
        third, "",
        "beyond the refusal cap a connection is closed without an answer"
    );
    assert!(
        start.elapsed() < Duration::from_millis(1500),
        "closed at once, not after the read deadline"
    );
    drop((served, refusing));
}

#[test]
fn truncated_upstream_stream_ends_with_error_not_end_turn() {
    let cut = b"data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}\n\n";
    let text = String::from_utf8(pipeline(cut, 7, &[], Encoder::new("local")).concat()).unwrap();
    assert!(text.contains("event: error"), "{text}");
    assert!(!text.contains("end_turn"));
    assert!(!text.contains("message_stop"));
}

#[test]
fn stop_sequence_is_matched_by_gateway_not_sent_upstream() {
    let req = br#"{"model":"local","max_tokens":64,"stream":true,"stop_sequences":["MOUSSE"],"messages":[{"role":"user","content":"hi"}]}"#;
    let r = decode(req).unwrap();
    let sent = chat_body(&r, EngineKind::Mlx, QWEN);
    assert!(sent.get("stop").is_none());
    let stops: Vec<&str> = r.stop.iter().map(String::as_str).collect();
    let text = String::from_utf8(
        pipeline(
            &fixture("mlx-0.32.2-stream-text.sse"),
            64,
            &stops,
            Encoder::new("local"),
        )
        .concat(),
    )
    .unwrap();
    assert!(text.contains(r#""stop_reason":"stop_sequence""#), "{text}");
    assert!(text.contains(r#""stop_sequence":"MOUSSE""#), "{text}");
    assert!(
        !text.contains(r#""text":"4""#),
        "text after the stop sequence is dropped"
    );
    assert!(text.contains(r#""text":"AMPLE""#));
}

#[tokio::test]
async fn open_ai_chat_completions_pass_through_with_model_renamed() {
    let (mlx, h) = mlx_router().await;
    let whole = fixture("mlx-0.32.2-nonstream-text.json");
    let w = whole.clone();
    mlx.on(move |_| Reply::json(w.clone()));
    let body =
        r#"{"model":"gpt-local","temperature":0.2,"messages":[{"role":"user","content":"hi"}]}"#;
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        body.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, whole, "forwarded unchanged");
    assert_eq!(r.header("content-type"), Some("application/json"));
    let sent = &mlx.seen()[0];
    assert_eq!(sent.path, "/v1/chat/completions");
    let mut want: Value = serde_json::from_str(body).unwrap();
    want["model"] = json!("default_model");
    assert_eq!(serde_json::from_slice::<Value>(&sent.body).unwrap(), want);

    let sse = fixture("mlx-0.32.2-stream-text.sse");
    let s = sse.clone();
    mlx.on(move |_| Reply::sse(s.clone()));
    let body = r#"{"model":"gpt-local","stream":true,"messages":[{"role":"user","content":"hi"}]}"#;
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        body.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, sse);
    assert_eq!(r.header("content-type"), Some("text/event-stream"));
    assert_eq!(r.header("cache-control"), Some("no-cache"));
    assert_eq!(
        serde_json::from_slice::<Value>(&mlx.seen()[1].body).unwrap()["model"],
        "default_model"
    );

    for bad in [r#"{"model":"m"}"#, "[]", "nope"] {
        let r = common::send(
            h.port,
            "POST",
            &mlx_path("/v1/chat/completions"),
            &[],
            bad.as_bytes(),
        )
        .await;
        assert_eq!(r.status, 400, "{bad}");
        assert_eq!(
            r.json(),
            json!({"error": {"message": "Request body must be a JSON object with messages", "type": "invalid_request_error"}})
        );
    }
    assert_eq!(mlx.seen().len(), 2);
    let r = common::send(h.port, "GET", &mlx_path("/v1/models"), &[], b"").await;
    assert_eq!(r.json()["data"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn dead_generation_becomes_overloaded_and_asks_for_a_restart() {
    let died = b"RuntimeError: generation thread died";
    assert!(is_dead_generation(404, died));
    assert!(is_dead_generation(500, died));
    assert!(
        !is_dead_generation(200, died),
        "a model may say these words"
    );
    assert!(!is_dead_generation(400, died));
    assert!(!is_dead_generation(404, b"{}"));
    assert!(localia_router::engine::DEAD_GENERATION_MESSAGE.contains("restarting"));

    // Over HTTP: 529 for Claude Code (which retries it), 503 for OpenAI clients, and the restart request is
    // the route status's `engineFailure` (the app restarts MLX when it sees it).
    let (mlx, h) = mlx_router().await;
    mlx.on(|_| Reply::status(500, "RuntimeError: generation thread died"));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 529);
    assert_eq!(
        common::anthropic_error(&r),
        (
            "overloaded_error".into(),
            localia_router::engine::DEAD_GENERATION_MESSAGE.into()
        )
    );
    let health = common::send(h.port, "GET", "/localia/health", &[], b"")
        .await
        .json();
    assert_eq!(health["route"]["engineFailure"], "mlx");
    let chat = r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#;
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        chat.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 503);
    assert_eq!(r.json()["error"]["type"], "server_error");
    // A model may say these words in a 200: that is an answer.
    mlx.on(|_| Reply::json(r#"{"choices":[{"message":{"content":"generation thread died"},"finish_reason":"stop"}]}"#));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/messages"),
        &[],
        SIMPLE_BODY.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 200);
}

#[tokio::test]
async fn pass_through_error_truncated_or_invalid_becomes_valid_json() {
    let (mlx, h) = mlx_router().await;
    let chat = r#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#;
    let whole = r#"{"error":{"message":"bad","type":"invalid_request_error"}}"#;
    mlx.on(move |_| Reply::status(400, whole));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        chat.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 400);
    assert_eq!(
        r.body,
        whole.as_bytes(),
        "a whole JSON error is forwarded as it is"
    );

    mlx.on(|_| Reply::status(500, "<html>Internal Server Error</html>"));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        chat.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 500);
    assert_eq!(
        r.json(),
        json!({"error": {"message": "The local model server answered HTTP 500.", "type": "api_error"}})
    );

    // Over 64 KiB: cut, so not forwarded even though it starts like JSON.
    let big = format!(r#"{{"error":{{"message":"{}"}}}}"#, "x".repeat(70_000));
    mlx.on(move |_| Reply::status(502, big.clone()));
    let r = common::send(
        h.port,
        "POST",
        &mlx_path("/v1/chat/completions"),
        &[],
        chat.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 502);
    assert!(r.body.len() < 1000, "replaced, not forwarded");
    assert_eq!(r.json()["error"]["type"], "api_error");
}

#[tokio::test]
async fn port_in_use_throws() {
    let h = spawn(|_| {}).await;
    let data = tempfile::tempdir().unwrap();
    let sessions = tempfile::tempdir().unwrap();
    let cfg = localia_router::ServiceConfig {
        port: h.port,
        data_dir: data.path().to_path_buf(),
        sessions_dir: sessions.path().to_path_buf(),
        engine_ports: localia_router::EnginePorts::default(),
        version: "42".into(),
        read_timeout: Duration::from_secs(30),
        max_body: 32 << 20,
        max_connections: 32,
    };
    let second = tokio::time::timeout(
        Duration::from_secs(5),
        localia_router::listen(cfg, std::future::pending()),
    )
    .await
    .expect("a second listener on the same port must fail at once, not serve");
    let err = second.expect_err("second listener on the same port");
    assert!(format!("{err:#}").contains(&h.port.to_string()), "{err:#}");
}

/// Sends raw bytes and returns everything the server answers before closing (empty when it just closes).
async fn raw_text(port: u16, bytes: &[u8]) -> String {
    let mut s = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let _ = s.write_all(bytes).await;
    let mut buf = Vec::new();
    let _ = tokio::time::timeout(Duration::from_secs(10), s.read_to_end(&mut buf))
        .await
        .expect("no answer within 10 s");
    String::from_utf8_lossy(&buf).to_string()
}

// MARK: - Golden streams

/// Generated ids become `msg_X` and `toolu_1`, `toolu_2`… in order of first appearance; ids the engine sent
/// stay as they are.
fn normalise_ids(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut tools: Vec<String> = Vec::new();
    let mut rest = s;
    'scan: while !rest.is_empty() {
        for prefix in ["msg_", "toolu_"] {
            if let Some(tail) = rest.strip_prefix(prefix) {
                let hex = tail
                    .as_bytes()
                    .iter()
                    .take(32)
                    .take_while(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b));
                if hex.count() == 32 {
                    let id = &rest[..prefix.len() + 32];
                    if prefix == "msg_" {
                        out.push_str("msg_X");
                    } else {
                        let n = match tools.iter().position(|t| t == id) {
                            Some(i) => i + 1,
                            None => {
                                tools.push(id.to_string());
                                tools.len()
                            }
                        };
                        out.push_str(&format!("toolu_{n}"));
                    }
                    rest = &rest[prefix.len() + 32..];
                    continue 'scan;
                }
            }
        }
        let c = rest.chars().next().unwrap();
        out.push(c);
        rest = &rest[c.len_utf8()..];
    }
    out
}

fn golden(case: &str, stops: &[&str]) {
    let dir = golden_dir().join(case);
    let engine = std::fs::read(dir.join("engine.sse")).unwrap();
    let want = std::fs::read_to_string(dir.join("client.sse")).unwrap();
    for chunk in [7, 1] {
        let out = pipeline(
            &engine,
            chunk,
            stops,
            Encoder::new("localia").with_input_tokens(50),
        );
        let got = normalise_ids(&String::from_utf8(out.concat()).unwrap());
        assert_eq!(got, want, "{case}, {chunk}-byte chunks");
    }
}

#[test]
fn golden_mlx_text_stream() {
    golden("mlx_text_stream", &[]);
}

#[test]
fn golden_mlx_thinking_then_text() {
    golden("mlx_thinking_then_text", &[]);
}

#[test]
fn golden_mlx_parallel_tool_calls() {
    golden("mlx_parallel_tool_calls", &[]);
    // Each block's fragments concatenate to its exact JSON, under distinct ids.
    let engine = std::fs::read(golden_dir().join("mlx_parallel_tool_calls/engine.sse")).unwrap();
    let ev = events(&pipeline(&engine, 7, &[], Encoder::new("localia")));
    let mut ids = Vec::new();
    for (i, want) in [json!({"file_path": "a.txt"}), json!({"pattern": "*.md"})]
        .iter()
        .enumerate()
    {
        let start = ev
            .iter()
            .find(|(n, o)| n == "content_block_start" && o["index"] == i)
            .unwrap();
        ids.push(start.1["content_block"]["id"].as_str().unwrap().to_string());
        let json: String = ev
            .iter()
            .filter(|(n, o)| n == "content_block_delta" && o["index"] == i)
            .filter_map(|(_, o)| o["delta"]["partial_json"].as_str())
            .collect();
        assert_eq!(serde_json::from_str::<Value>(&json).unwrap(), *want);
    }
    assert_ne!(ids[0], ids[1]);
}

#[test]
fn golden_mlx_stop_sequence_split_across_chunks() {
    golden("mlx_stop_sequence_split_across_chunks", &["</answer>"]);
}

#[test]
fn golden_mlx_upstream_error_midstream() {
    golden("mlx_upstream_error_midstream", &[]);
}

#[test]
fn placeholders_and_documents() {
    let r = decode(
        br#"{"messages":[{"role":"user","content":[{"type":"image","source":{}},{"type":"document","source":{}},{"type":"text","text":"What is this?"}]}]}"#,
    )
    .unwrap();
    let c = chat_body(&r, EngineKind::Ollama, "qwen3:8b");
    assert_eq!(
        c["model"], "qwen3:8b",
        "only MLX is addressed as default_model"
    );
    assert_eq!(
        c["messages"][0]["content"],
        format!("{IMAGE_PLACEHOLDER}\n{DOCUMENT_PLACEHOLDER}\nWhat is this?")
    );
}

#[test]
fn client_model_is_echoed_not_the_engines() {
    let r = decode(
        br#"{"model":"claude-x","max_tokens":8,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#,
    )
    .unwrap();
    assert_eq!(r.client_model, "claude-x");
    assert_eq!(
        chat_body(&r, EngineKind::Mlx, QWEN)["model"],
        "default_model",
        "the engine gets its own name"
    );
    // The recorded stream says `"model": "default_model"`; the client is answered with its own model.
    let ev = events(&pipeline(
        &fixture("mlx-0.32.2-stream-text.sse"),
        7,
        &[],
        Encoder::new(&r.client_model),
    ));
    assert_eq!(ev[0].1["message"]["model"], "claude-x");
    let whole = decode_chat_response(&fixture("mlx-0.32.2-nonstream-text.json")).unwrap();
    assert_eq!(
        encode_response(&whole, &r.client_model)["model"],
        "claude-x"
    );
    // No model: empty, as the gateway echoed it.
    assert_eq!(decode(br#"{"messages":[]}"#).unwrap().client_model, "");
}

#[test]
fn queued_tool_call_keeps_fragments_that_arrive_after_text() {
    let mut dec = ChatStreamDecoder::new(&[]);
    let mut enc = Encoder::new("m");
    let mut out = enc.start();
    out.extend(consume(
        &mut dec,
        &mut enc,
        &[
            json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "a", "function": {"name": "Read", "arguments": "{\"file_path\":\"a\"}"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 1, "id": "b", "function": {"name": "Glob", "arguments": "{\"pat"}}]}}]}),
            text_chunk("Checking."),
            json!({"choices": [{"delta": {"reasoning": "hmm"}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 1, "function": {"arguments": "tern\":\"*.md\"}"}}]}}]}),
            json!({"choices": [{"delta": {"tool_calls": [{"index": 2, "id": "c", "function": {"name": "Ls", "arguments": "{}"}}]}}]}),
            json!({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}),
        ],
    ));
    out.extend(enc.finish());
    let ev = events(&out);
    let blocks: Vec<(i64, String)> = ev
        .iter()
        .filter(|(n, _)| n == "content_block_start")
        .map(|(_, o)| {
            let b = &o["content_block"];
            let label = b["name"]
                .as_str()
                .or(b["type"].as_str())
                .unwrap()
                .to_string();
            (o["index"].as_i64().unwrap(), label)
        })
        .collect();
    assert_eq!(
        blocks,
        [
            (0, "Read".to_string()),
            (1, "text".to_string()),
            (2, "thinking".to_string()),
            (3, "Glob".to_string()),
            (4, "Ls".to_string())
        ],
        "queued calls wait for the end, in call order"
    );
    for (index, want) in [
        (0, json!({"file_path": "a"})),
        (3, json!({"pattern": "*.md"})),
        (4, json!({})),
    ] {
        let args: String = ev
            .iter()
            .filter(|(n, o)| n == "content_block_delta" && o["index"] == index)
            .filter_map(|(_, o)| o["delta"]["partial_json"].as_str())
            .collect();
        assert_eq!(
            serde_json::from_str::<Value>(&args).unwrap(),
            want,
            "block {index}"
        );
    }
    assert_eq!(message_delta(&ev)["delta"]["stop_reason"], "tool_use");
}

#[test]
fn tool_choice_is_mapped() {
    let with = |choice: &str| {
        let b = format!(
            r#"{{"tools":[{{"name":"Read","input_schema":{{"type":"object"}}}}],"tool_choice":{choice},"messages":[{{"role":"user","content":"x"}}]}}"#
        );
        let r = decode(b.as_bytes()).unwrap();
        (
            r.tool_choice.clone(),
            chat_body(&r, EngineKind::Mlx, "m")
                .get("tool_choice")
                .cloned(),
        )
    };
    assert_eq!(with(r#"{"type":"auto"}"#), (ToolChoice::Auto, None));
    assert_eq!(
        with(r#"{"type":"none"}"#),
        (ToolChoice::None, Some(json!("none")))
    );
    assert_eq!(
        with(r#"{"type":"any"}"#),
        (ToolChoice::Required, Some(json!("required")))
    );
    assert_eq!(
        with(r#"{"type":"tool","name":"Read"}"#),
        (
            ToolChoice::Named("Read".into()),
            Some(json!({"type": "function", "function": {"name": "Read"}}))
        )
    );
    assert_eq!(with(r#"{"type":"tool"}"#), (ToolChoice::Auto, None));
    // Without tools, no choice is sent.
    let r = decode(br#"{"tool_choice":{"type":"any"},"messages":[]}"#).unwrap();
    assert!(chat_body(&r, EngineKind::Mlx, "m")
        .get("tool_choice")
        .is_none());
    assert_eq!(anthropic::count_tokens(b"x"), 1);
}
