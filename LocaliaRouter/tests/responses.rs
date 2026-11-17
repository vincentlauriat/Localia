//! The OpenAI Responses dialect: request decoding, the streamed and whole answers, and golden streams.

use axum::body::Bytes;
use localia_router::dialect::responses::{decode, encode_response, error_body, Encoder};
use localia_router::dialect::{DialectError, StreamEncoder};
use localia_router::engine::{chat_body, decode_chat_response, ChatStreamDecoder, EngineKind};
use localia_router::ir::{FinishReason, Part, Role, StreamEvent, ToolChoice};
use localia_router::sse::SseParser;
use serde_json::{json, Value};
use std::path::PathBuf;

fn golden_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/golden/responses")
}

/// Decodes the SSE events an encoder produced: (event name, payload). Every payload's `type` is its event
/// name, and sequence numbers count up from 0 without a gap.
fn events(parts: &[Bytes]) -> Vec<(String, Value)> {
    let text = String::from_utf8(parts.concat()).unwrap();
    let ev: Vec<(String, Value)> = text
        .split("\n\n")
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
        .collect();
    for (n, (_, o)) in ev.iter().enumerate() {
        assert_eq!(o["sequence_number"], n, "sequence_number of event {n}");
    }
    ev
}

fn names(ev: &[(String, Value)]) -> Vec<&str> {
    ev.iter().map(|(n, _)| n.as_str()).collect()
}

fn find<'a>(ev: &'a [(String, Value)], name: &str) -> Vec<&'a Value> {
    ev.iter()
        .filter(|(n, _)| n == name)
        .map(|(_, o)| o)
        .collect()
}

/// An engine's SSE bytes through the parser (split every `chunk` bytes), the decoder and the encoder, ending
/// as the relay will: a stop sequence ends the answer, an upstream error or a cut stream fails it.
fn pipeline(sse: &[u8], chunk: usize, stops: &[&str], enc: &mut dyn StreamEncoder) -> Vec<Bytes> {
    let stops: Vec<String> = stops.iter().map(|s| s.to_string()).collect();
    let mut parser = SseParser::new();
    let mut dec = ChatStreamDecoder::new(&stops);
    let mut out = enc.start();
    for piece in sse.chunks(chunk) {
        for payload in parser.feed(piece) {
            for e in dec.feed(&payload) {
                out.extend(enc.event(&e));
            }
            if let Some(err) = dec.take_error() {
                out.extend(enc.fail(&err));
                return out;
            }
            if dec.matched_stop().is_some() {
                out.extend(enc.finish());
                return out;
            }
        }
    }
    if !dec.saw_end() {
        out.extend(
            enc.fail("The local model server closed the stream before the answer was complete."),
        );
        return out;
    }
    out.extend(enc.finish());
    out
}

/// Stream events straight into an encoder, then its end.
fn encode(events: &[StreamEvent], enc: &mut Encoder) -> Vec<Bytes> {
    let mut out = enc.start();
    for e in events {
        out.extend(enc.event(e));
    }
    out.extend(enc.finish());
    out
}

/// Random ids (`resp_`, `msg_`, `fc_`, `call_` + 32 hex) become `<prefix><n>`, numbered per prefix in order
/// of appearance.
fn normalise_ids(s: &str) -> String {
    const PREFIXES: [&str; 4] = ["resp_", "msg_", "fc_", "call_"];
    let mut seen: Vec<Vec<String>> = vec![Vec::new(); PREFIXES.len()];
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    'scan: while !rest.is_empty() {
        for (k, prefix) in PREFIXES.iter().enumerate() {
            if let Some(tail) = rest.strip_prefix(prefix) {
                let hex = tail
                    .bytes()
                    .take(32)
                    .take_while(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
                    .count();
                if hex == 32 {
                    let id = &rest[..prefix.len() + 32];
                    let n = match seen[k].iter().position(|t| t == id) {
                        Some(i) => i + 1,
                        None => {
                            seen[k].push(id.to_string());
                            seen[k].len()
                        }
                    };
                    out.push_str(&format!("{prefix}{n}"));
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

fn is_id(s: &str, prefix: &str) -> bool {
    s.strip_prefix(prefix).is_some_and(|h| {
        h.len() == 32
            && h.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

// MARK: - Request

#[test]
fn decode_maps_input_items_and_tools() {
    let r = decode(
        br#"{"model":"gpt-5-codex","instructions":"You are Codex.","stream":true,"max_output_tokens":2048,
         "temperature":0.3,"top_p":0.9,"store":false,"previous_response_id":null,
         "input":[
           {"type":"message","role":"developer","content":[{"type":"input_text","text":"Sandbox: read-only."}]},
           {"role":"user","content":"List the files"},
           {"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"xyz"},
           {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Looking."}]},
           {"type":"function_call","call_id":"call_a","name":"shell","arguments":"{\"cmd\":\"ls\"}"},
           {"type":"function_call","call_id":"call_b","name":"shell","arguments":"{\"cmd\":\"pwd\"}"},
           {"type":"function_call_output","call_id":"call_a","output":"a.txt"},
           {"type":"function_call_output","call_id":"call_b","output":[{"type":"input_text","text":"/tmp"}]},
           {"type":"message","role":"user","content":[{"type":"input_text","text":"And this?"},{"type":"input_image","image_url":"data:"}]}
         ],
         "tools":[
           {"type":"function","name":"shell","description":"Run a command","strict":false,
            "parameters":{"type":"object","properties":{"cmd":{"type":"string"}}}},
           {"type":"web_search"},
           {"type":"custom","name":"apply_patch","format":{"type":"grammar"}},
           {"type":"function","name":"noargs"}
         ],
         "tool_choice":{"type":"function","name":"shell"}}"#,
    )
    .unwrap();
    assert_eq!(r.client_model, "gpt-5-codex");
    assert_eq!(
        r.system.as_deref(),
        Some("You are Codex.\n\nSandbox: read-only.")
    );
    assert!(r.stream);
    assert_eq!(r.max_tokens, Some(2048));
    assert_eq!(r.temperature, Some(0.3));
    assert_eq!(r.top_p, Some(0.9));
    assert_eq!(r.top_k, None);
    assert!(r.stop.is_empty());
    assert_eq!(r.tool_choice, ToolChoice::Named("shell".into()));

    // Reasoning is dropped; the assistant's text and its calls are one turn; both outputs are one tool turn.
    let roles: Vec<Role> = r.messages.iter().map(|m| m.role).collect();
    assert_eq!(
        roles,
        [Role::User, Role::Assistant, Role::Tool, Role::User],
        "{:?}",
        r.messages
    );
    assert_eq!(r.messages[0].parts, [Part::Text("List the files".into())]);
    assert_eq!(
        r.messages[1].parts,
        [
            Part::Text("Looking.".into()),
            Part::ToolCall {
                id: "call_a".into(),
                name: "shell".into(),
                arguments: r#"{"cmd":"ls"}"#.into()
            },
            Part::ToolCall {
                id: "call_b".into(),
                name: "shell".into(),
                arguments: r#"{"cmd":"pwd"}"#.into()
            },
        ]
    );
    assert_eq!(
        r.messages[2].parts,
        [
            Part::ToolResult {
                call_id: "call_a".into(),
                content: "a.txt".into(),
                is_error: false
            },
            Part::ToolResult {
                call_id: "call_b".into(),
                content: "/tmp".into(),
                is_error: false
            },
        ]
    );
    assert_eq!(r.messages[3].parts[0], Part::Text("And this?".into()));
    assert_eq!(
        r.messages[3].parts.len(),
        2,
        "the image becomes a placeholder"
    );

    // Function tools only, flat; a tool without parameters gets an empty object schema.
    let tools: Vec<&str> = r.tools.iter().map(|t| t.name.as_str()).collect();
    assert_eq!(tools, ["shell", "noargs"]);
    assert_eq!(r.tools[0].description.as_deref(), Some("Run a command"));
    assert_eq!(r.tools[0].parameters["properties"]["cmd"]["type"], "string");
    assert_eq!(r.tools[1].parameters["type"], "object");

    // What the engine receives: one assistant message with both calls, then two tool messages.
    let c = chat_body(&r, EngineKind::Mlx, "q");
    let m = c["messages"].as_array().unwrap();
    let roles: Vec<&str> = m.iter().map(|x| x["role"].as_str().unwrap()).collect();
    assert_eq!(
        roles,
        ["system", "user", "assistant", "tool", "tool", "user"]
    );
    assert_eq!(m[2]["tool_calls"].as_array().unwrap().len(), 2);
    assert_eq!(c["max_tokens"], 2048);
    assert_eq!(c["tool_choice"]["function"]["name"], "shell");
}

#[test]
fn decode_string_input_and_choices() {
    let r =
        decode(br#"{"model":"m","input":"hello","tool_choice":"required","tools":[]}"#).unwrap();
    assert_eq!(r.messages.len(), 1);
    assert_eq!(r.messages[0].role, Role::User);
    assert_eq!(r.messages[0].parts, [Part::Text("hello".into())]);
    assert_eq!(r.tool_choice, ToolChoice::Required);
    assert!(!r.stream);
    assert_eq!(r.system, None);
    for (raw, want) in [
        (r#""none""#, ToolChoice::None),
        (r#""auto""#, ToolChoice::Auto),
        (r#"{"type":"web_search"}"#, ToolChoice::Auto),
    ] {
        let b = format!(r#"{{"input":"x","tool_choice":{raw}}}"#);
        assert_eq!(decode(b.as_bytes()).unwrap().tool_choice, want, "{raw}");
    }
    // A system message in the input, with no instructions, becomes the system prompt.
    let r = decode(
        br#"{"input":[{"role":"system","content":"Be brief."},{"role":"user","content":"hi"}]}"#,
    )
    .unwrap();
    assert_eq!(r.system.as_deref(), Some("Be brief."));
    assert_eq!(r.messages.len(), 1);
}

#[test]
fn decode_rejects_previous_response_id() {
    let err =
        decode(br#"{"model":"m","previous_response_id":"resp_123","input":"hi"}"#).unwrap_err();
    assert_eq!(
        err,
        DialectError::Invalid(
            "previous_response_id is not supported by local models; send the full input".into()
        )
    );
    // A null one is no conversation state at all.
    assert!(decode(br#"{"previous_response_id":null,"input":"hi"}"#).is_ok());
}

#[test]
fn decode_rejects_malformed_bodies() {
    for b in [
        &b"not json"[..],
        br#"[1,2]"#,
        br#"{"input":[{"type":"function_call","name":"x","arguments":"{}"}]}"#,
        br#"{"input":[{"type":"function_call_output","output":"x"}]}"#,
        br#"{"input":42}"#,
    ] {
        assert!(
            matches!(decode(b), Err(DialectError::Invalid(_))),
            "{}",
            String::from_utf8_lossy(b)
        );
    }
}

// MARK: - Whole answers and errors

#[test]
fn golden_responses_mlx_nonstream() {
    let dir = golden_dir().join("mlx_nonstream");
    let engine = std::fs::read(dir.join("engine.json")).unwrap();
    let want: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("client.json")).unwrap()).unwrap();
    let mut got = encode_response(&decode_chat_response(&engine).unwrap(), "localia");
    assert!(got["created_at"].as_u64().unwrap() > 1_700_000_000);
    got["created_at"] = json!(0);
    let got: Value = serde_json::from_str(&normalise_ids(&got.to_string())).unwrap();
    assert_eq!(got, want);
}

#[test]
fn encode_response_with_tool_calls() {
    let r = localia_router::ir::ChatResponse {
        parts: vec![
            Part::Thinking("hmm".into()),
            Part::Text("Reading.".into()),
            Part::ToolCall {
                id: "".into(),
                name: "Read".into(),
                arguments: r#"{"file_path":"a"}"#.into(),
            },
            Part::ToolCall {
                id: "call_engine".into(),
                name: "Ls".into(),
                arguments: "".into(),
            },
        ],
        finish: FinishReason::ToolCalls,
        input: Some(5),
        output: None,
    };
    let v = encode_response(&r, "gpt-x");
    assert!(is_id(v["id"].as_str().unwrap(), "resp_"));
    assert_eq!(v["object"], "response");
    assert_eq!(v["status"], "completed");
    assert_eq!(v["model"], "gpt-x");
    let out = v["output"].as_array().unwrap();
    let kinds: Vec<&str> = out.iter().map(|o| o["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["message", "function_call", "function_call"]);
    assert_eq!(out[0]["content"][0]["text"], "Reading.");
    assert!(is_id(out[1]["call_id"].as_str().unwrap(), "call_"));
    assert!(is_id(out[1]["id"].as_str().unwrap(), "fc_"));
    assert_eq!(out[1]["arguments"], r#"{"file_path":"a"}"#);
    assert_eq!(out[2]["call_id"], "call_engine");
    assert_eq!(out[2]["arguments"], "{}");
    assert_eq!(
        v["usage"],
        json!({"input_tokens": 5, "output_tokens": 0, "total_tokens": 5})
    );
}

#[test]
fn error_body_is_openai_shaped() {
    assert_eq!(
        error_body("invalid_request_error", "nope"),
        json!({"error": {"type": "invalid_request_error", "message": "nope"}})
    );
}

// MARK: - Streaming

fn golden(case: &str) {
    let dir = golden_dir().join(case);
    let engine = std::fs::read(dir.join("engine.sse")).unwrap();
    let want = std::fs::read_to_string(dir.join("client.sse")).unwrap();
    for chunk in [7, 1] {
        let mut enc = Encoder::new("localia")
            .with_input_tokens(50)
            .with_created_at(1_700_000_000);
        let out = pipeline(&engine, chunk, &[], &mut enc);
        let got = normalise_ids(&String::from_utf8(out.concat()).unwrap());
        assert_eq!(got, want, "{case}, {chunk}-byte chunks");
        events(&out);
    }
}

#[test]
fn golden_responses_mlx_text_stream() {
    golden("mlx_text_stream");
}

#[test]
fn golden_responses_mlx_parallel_tool_calls() {
    golden("mlx_parallel_tool_calls");
    // Two function_call items, distinct call ids, each `.done` holding its call's whole JSON.
    let engine = std::fs::read(golden_dir().join("mlx_parallel_tool_calls/engine.sse")).unwrap();
    for chunk in [7, 1] {
        let ev = events(&pipeline(&engine, chunk, &[], &mut Encoder::new("m")));
        let done = find(&ev, "response.output_item.done");
        assert_eq!(done.len(), 2);
        let want = [json!({"file_path": "a.txt"}), json!({"pattern": "*.md"})];
        let mut call_ids = Vec::new();
        for (i, item) in done.iter().enumerate() {
            let item = &item["item"];
            assert_eq!(item["type"], "function_call");
            assert_eq!(item["status"], "completed");
            call_ids.push(item["call_id"].as_str().unwrap().to_string());
            let args: Value = serde_json::from_str(item["arguments"].as_str().unwrap()).unwrap();
            assert_eq!(args, want[i]);
            // The deltas of the item add up to its arguments too.
            let joined: String = find(&ev, "response.function_call_arguments.delta")
                .iter()
                .filter(|o| o["item_id"] == item["id"])
                .filter_map(|o| o["delta"].as_str())
                .collect();
            assert_eq!(joined, item["arguments"].as_str().unwrap());
        }
        assert_ne!(call_ids[0], call_ids[1]);
        assert!(call_ids.iter().all(|c| is_id(c, "call_")));
    }
}

#[test]
fn tool_fragments_after_text_are_kept() {
    // A call starts, text arrives, then more of the call's fragments, and a second call interleaves.
    let ev = events(&encode(
        &[
            StreamEvent::ToolCallStart {
                index: 0,
                id: "".into(),
                name: "Read".into(),
            },
            StreamEvent::ToolCallArgs {
                index: 0,
                fragment: r#"{"file_"#.into(),
            },
            StreamEvent::TextDelta("Let me look.".into()),
            StreamEvent::ToolCallStart {
                index: 1,
                id: "call_x".into(),
                name: "Ls".into(),
            },
            StreamEvent::ToolCallArgs {
                index: 0,
                fragment: r#"path":"a"}"#.into(),
            },
            StreamEvent::ThinkingDelta("hmm".into()),
            StreamEvent::ToolCallArgs {
                index: 1,
                fragment: "{}".into(),
            },
            StreamEvent::ToolCallStart {
                index: 0,
                id: "".into(),
                name: "Read".into(),
            },
            StreamEvent::Finish(FinishReason::ToolCalls),
        ],
        &mut Encoder::new("m"),
    ));
    let done: Vec<&Value> = find(&ev, "response.output_item.done")
        .into_iter()
        .map(|o| &o["item"])
        .collect();
    let kinds: Vec<&str> = done.iter().map(|i| i["type"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["message", "function_call", "function_call"]);
    assert_eq!(done[0]["content"][0]["text"], "Let me look.");
    assert_eq!(done[1]["name"], "Read");
    assert_eq!(done[1]["arguments"], r#"{"file_path":"a"}"#);
    assert_eq!(done[2]["name"], "Ls");
    assert_eq!(done[2]["call_id"], "call_x");
    assert_eq!(done[2]["arguments"], "{}");
    // Output indices follow the order of the items, and `response.completed` lists the same items.
    for (i, (_, o)) in ev
        .iter()
        .filter(|(n, _)| n == "response.output_item.done")
        .enumerate()
    {
        assert_eq!(o["output_index"], i);
    }
    let completed = find(&ev, "response.completed")[0];
    let output: Vec<&Value> = completed["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .collect();
    assert_eq!(output, done);
    assert!(
        !names(&ev).iter().any(|n| n.contains("reasoning")),
        "reasoning is not sent"
    );
}

#[test]
fn leading_whitespace_waits_for_text_and_tool_without_arguments_gets_object() {
    let ev = events(&encode(
        &[
            StreamEvent::TextDelta("\n\n".into()),
            StreamEvent::TextDelta("Hi".into()),
            StreamEvent::ToolCallStart {
                index: 0,
                id: "".into(),
                name: "Ls".into(),
            },
            StreamEvent::Usage {
                input: Some(7),
                output: Some(2),
            },
            StreamEvent::Finish(FinishReason::ToolCalls),
        ],
        &mut Encoder::new("m"),
    ));
    let deltas: Vec<&str> = find(&ev, "response.output_text.delta")
        .iter()
        .map(|o| o["delta"].as_str().unwrap())
        .collect();
    assert_eq!(deltas, ["\n\nHi"]);
    let call = &find(&ev, "response.output_item.done")[1]["item"];
    assert_eq!(call["arguments"], "{}");
    assert_eq!(
        find(&ev, "response.function_call_arguments.done")[0]["arguments"],
        "{}"
    );
    assert_eq!(
        find(&ev, "response.completed")[0]["response"]["usage"],
        json!({"input_tokens": 7, "output_tokens": 2, "total_tokens": 9})
    );

    // Whitespace alone never opens a message.
    let ev = events(&encode(
        &[
            StreamEvent::TextDelta("  ".into()),
            StreamEvent::Finish(FinishReason::Stop),
        ],
        &mut Encoder::new("m"),
    ));
    assert_eq!(
        names(&ev),
        [
            "response.created",
            "response.in_progress",
            "response.completed"
        ]
    );
}

#[test]
fn client_model_is_echoed_and_input_estimate_used_without_usage() {
    let ev = events(&encode(
        &[
            StreamEvent::TextDelta("ok".into()),
            StreamEvent::Finish(FinishReason::Stop),
        ],
        &mut Encoder::new("gpt-5-codex").with_input_tokens(40),
    ));
    let created = &find(&ev, "response.created")[0]["response"];
    assert_eq!(created["model"], "gpt-5-codex");
    assert_eq!(created["status"], "in_progress");
    assert!(is_id(created["id"].as_str().unwrap(), "resp_"));
    let completed = &find(&ev, "response.completed")[0]["response"];
    assert_eq!(completed["id"], created["id"]);
    assert_eq!(completed["model"], "gpt-5-codex");
    assert_eq!(
        completed["usage"],
        json!({"input_tokens": 40, "output_tokens": 0, "total_tokens": 40})
    );
}

#[test]
fn fail_emits_response_failed_and_ends_the_stream() {
    let mut enc = Encoder::new("m");
    let mut out = enc.start();
    out.extend(enc.event(&StreamEvent::TextDelta("partial".into())));
    out.extend(enc.fail("engine died"));
    out.extend(enc.event(&StreamEvent::TextDelta("late".into())));
    out.extend(enc.finish());
    out.extend(enc.fail("again"));
    let ev = events(&out);
    assert_eq!(
        names(&ev),
        [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
            "response.failed",
        ]
    );
    let r = &find(&ev, "response.failed")[0]["response"];
    assert_eq!(r["status"], "failed");
    assert_eq!(r["error"]["message"], "engine died");
    assert_eq!(r["error"]["code"], "server_error");

    // After a normal end, fail adds nothing.
    let mut enc = Encoder::new("m");
    let mut out = encode(&[StreamEvent::Finish(FinishReason::Stop)], &mut enc);
    out.extend(enc.fail("late"));
    assert_eq!(names(&events(&out)).last(), Some(&"response.completed"));
}

#[test]
fn upstream_error_and_cut_stream_fail_the_response() {
    let err = b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\ndata: {\"error\":{\"message\":\"boom\"}}\n\n";
    let ev = events(&pipeline(err, 7, &[], &mut Encoder::new("m")));
    assert_eq!(names(&ev).last(), Some(&"response.failed"));
    assert_eq!(
        find(&ev, "response.failed")[0]["response"]["error"]["message"],
        "boom"
    );

    let cut = b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n";
    let ev = events(&pipeline(cut, 1, &[], &mut Encoder::new("m")));
    assert_eq!(names(&ev).last(), Some(&"response.failed"));
}

#[test]
fn stop_sequence_ends_the_text() {
    let sse = b"data: {\"choices\":[{\"delta\":{\"content\":\"Answer: 4 </do\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ne> more\"}}]}\n\n";
    for chunk in [7, 1] {
        let ev = events(&pipeline(sse, chunk, &["</done>"], &mut Encoder::new("m")));
        assert_eq!(
            find(&ev, "response.output_text.done")[0]["text"],
            "Answer: 4 "
        );
        assert_eq!(names(&ev).last(), Some(&"response.completed"));
    }
}
