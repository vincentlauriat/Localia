//! Usage extraction and status rules (ported from the Swift `UsageExtractorTests`, plus the Responses dialect),
//! the proxied path parser (`ProxyRouteTests`), and the translation driver's stream rules.

mod common;

use common::pipeline;
use localia_router::dialect::{anthropic, responses};
use localia_router::engine::EngineKind;
use localia_router::metering::{
    error_message, requesting_usage, status_for, Dialect, StreamMeter, UsageExtractor,
};
use localia_router::relay::{EngineEnd, ProxyPath, Segment, Translation};
use localia_router::sse::{SseLine, SseParser};
use localia_router::store::Status;
use std::path::PathBuf;

fn matrix(name: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/golden/matrix")
            .join(name),
    )
    .unwrap()
}

fn recorded(name: &str) -> Vec<u8> {
    std::fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/golden/anthropic/recorded")
            .join(name),
    )
    .unwrap()
}

/// Every `data:` payload of `sse` through an extractor.
fn stream_usage(sse: &[u8], d: Dialect) -> (Option<i64>, Option<i64>) {
    let mut ex = UsageExtractor::new(d);
    for p in SseParser::new().feed(sse) {
        ex.feed_sse_data(&p);
    }
    ex.usage()
}

#[test]
fn anthropic_stream() {
    assert_eq!(
        stream_usage(&matrix("anthropic-stream-usage.sse"), Dialect::Anthropic),
        (Some(1200), Some(87))
    );
}

#[test]
fn anthropic_json() {
    assert_eq!(
        UsageExtractor::from_json(&matrix("anthropic-nonstream.json"), Dialect::Anthropic),
        (Some(50), Some(12))
    );
}

#[test]
fn openai_stream() {
    assert_eq!(
        stream_usage(&matrix("openai-stream-usage.sse"), Dialect::Chat),
        (Some(300), Some(40))
    );
}

#[test]
fn openai_json() {
    let body = br#"{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3}}"#;
    assert_eq!(
        UsageExtractor::from_json(body, Dialect::Chat),
        (Some(7), Some(3))
    );
}

#[test]
fn stream_without_usage() {
    assert_eq!(
        stream_usage(&matrix("mlx-0.32.2-stream-text-nousage.sse"), Dialect::Chat),
        (None, None)
    );
}

#[test]
fn mlx_real_stream_reports_usage() {
    assert_eq!(
        stream_usage(&recorded("mlx-0.32.2-stream-text.sse"), Dialect::Chat),
        (Some(220), Some(16))
    );
}

#[test]
fn garbage_json_is_unknown() {
    assert_eq!(
        UsageExtractor::from_json(b"nope", Dialect::Chat),
        (None, None)
    );
    assert_eq!(
        UsageExtractor::from_json(b"[1,2]", Dialect::Anthropic),
        (None, None)
    );
}

#[test]
fn non_integral_counts_are_unknown() {
    // Swift read counts with `as? Int`: a fraction is not a count.
    let body = br#"{"usage":{"input_tokens":1.5,"output_tokens":"3"}}"#;
    assert_eq!(
        UsageExtractor::from_json(body, Dialect::Anthropic),
        (None, None)
    );
    let body = br#"{"usage":{"input_tokens":4.0,"output_tokens":2}}"#;
    assert_eq!(
        UsageExtractor::from_json(body, Dialect::Anthropic),
        (Some(4), Some(2))
    );
}

#[test]
fn responses_stream_reads_completed_only() {
    let sse = concat!(
        "event: response.created\n",
        "data: {\"type\":\"response.created\",\"response\":{\"usage\":null}}\n\n",
        "event: response.in_progress\n",
        "data: {\"type\":\"response.in_progress\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":9}}}\n\n",
        "event: response.completed\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":120,\"output_tokens\":33,\"total_tokens\":153}}}\n\n",
    );
    assert_eq!(
        stream_usage(sse.as_bytes(), Dialect::Responses),
        (Some(120), Some(33))
    );
}

#[test]
fn responses_json() {
    let body = br#"{"object":"response","status":"completed","usage":{"input_tokens":220,"output_tokens":16,"total_tokens":236}}"#;
    assert_eq!(
        UsageExtractor::from_json(body, Dialect::Responses),
        (Some(220), Some(16))
    );
}

#[test]
fn dialect_of_rest() {
    assert_eq!(Dialect::of("/v1/messages"), Some(Dialect::Anthropic));
    assert_eq!(Dialect::of("/v1/chat/completions"), Some(Dialect::Chat));
    assert_eq!(Dialect::of("/v1/responses"), Some(Dialect::Responses));
    assert_eq!(Dialect::of("/v1/messages/count_tokens"), None);
    assert_eq!(Dialect::of("/v1/models"), None);
    assert_eq!(Dialect::of("/api/version"), None);
    assert_eq!(Dialect::Anthropic.api().as_str(), "anthropic");
    assert_eq!(Dialect::Chat.api().as_str(), "openai");
    assert_eq!(Dialect::Responses.api().as_str(), "openai");
}

#[test]
fn requesting_usage_adds_only_when_streaming_and_absent() {
    let out = requesting_usage(br#"{"model":"m","stream":true}"#).expect("rewritten");
    let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
    assert_eq!(v["stream_options"]["include_usage"], true);
    assert_eq!(v["model"], "m");
    assert!(requesting_usage(br#"{"model":"m","stream":false}"#).is_none());
    assert!(requesting_usage(
        br#"{"model":"m","stream":true,"stream_options":{"include_usage":false}}"#
    )
    .is_none());
    assert!(requesting_usage(b"not json").is_none());
}

#[test]
fn status_follows_http() {
    assert_eq!(status_for(200), Status::Ok);
    assert_eq!(status_for(204), Status::Ok);
    assert_eq!(status_for(400), Status::ClientError);
    assert_eq!(status_for(499), Status::ClientError);
    assert_eq!(status_for(500), Status::UpstreamError);
    assert_eq!(status_for(302), Status::UpstreamError);
}

#[test]
fn error_message_from_body() {
    assert_eq!(error_message(br#"{"error":"bad model"}"#, 400), "bad model");
    assert_eq!(
        error_message(br#"{"error":{"message":"boom","type":"x"}}"#, 500),
        "boom"
    );
    assert_eq!(error_message(b"  plain text\n", 502), "plain text");
    assert_eq!(error_message(b"", 503), "Upstream answered HTTP 503");
    let long = vec![b'a'; 900];
    assert_eq!(error_message(&long, 500).len(), 500);
}

#[test]
fn stream_meter_sees_the_terminal_event() {
    let sse = matrix("anthropic-stream-usage.sse");
    let mut m = StreamMeter::new(Dialect::Anthropic);
    for c in sse.chunks(7) {
        m.feed(c);
    }
    assert!(m.saw_terminal());
    assert_eq!(m.usage(), (Some(1200), Some(87)));
    let mut cut = StreamMeter::new(Dialect::Anthropic);
    cut.feed(&sse[..sse.len() / 2]);
    assert!(!cut.saw_terminal());

    let mut chat = StreamMeter::new(Dialect::Chat);
    chat.feed(&matrix("openai-stream-usage.sse"));
    assert!(chat.saw_terminal());
    let mut resp = StreamMeter::new(Dialect::Responses);
    resp.feed(b"data: {\"type\":\"response.created\"}\n\n");
    assert!(!resp.saw_terminal());
    resp.feed(b"data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}}\n\n");
    assert!(resp.saw_terminal());
    assert_eq!(resp.usage(), (Some(1), Some(2)));
}

// MARK: - Paths

#[test]
fn parse_valid_paths() {
    let p = ProxyPath::parse("/s/abc-1/ollama/v1/messages").unwrap();
    assert_eq!(p.session, "abc-1");
    assert_eq!(p.segment, Segment::Engine(EngineKind::Ollama));
    assert_eq!(p.rest, "/v1/messages");
    let p = ProxyPath::parse("/s/abc-1/auto/v1/responses").unwrap();
    assert_eq!(p.segment, Segment::Auto);
    assert_eq!(p.rest, "/v1/responses");
    let p = ProxyPath::parse("/s/abc/llamaCpp").unwrap();
    assert_eq!(p.segment, Segment::Engine(EngineKind::LlamaCpp));
    assert_eq!(p.rest, "");
    let p = ProxyPath::parse("/s/abc/mlx/").unwrap();
    assert_eq!(p.segment, Segment::Engine(EngineKind::Mlx));
    assert_eq!(p.rest, "/");
}

#[test]
fn parse_rejects() {
    for bad in [
        "/v1/messages",
        "/s//ollama/x",
        "/s/a/unknown/x",
        "/s/a b/ollama/x",
        "/s/a",
        "/s/a/llamacpp/x",
        "/x/a/ollama/v1",
    ] {
        assert!(ProxyPath::parse(bad).is_none(), "{bad}");
    }
}

#[test]
fn parse_accepts_session_placeholder_as_shell_session() {
    for ph in ["@LOCALIA_SESSION@", "%40LOCALIA_SESSION%40"] {
        let p = ProxyPath::parse(&format!("/s/{ph}/ollama/api/version")).unwrap();
        assert_eq!(p.session, "shell");
        assert_eq!(p.rest, "/api/version");
    }
}

// MARK: - Translation driver

#[test]
fn sse_parser_reports_comment_lines() {
    let mut p = SseParser::new();
    let lines = p.feed_lines(b": keepalive 1/2\r\n\r\ndata: {}\n\nevent: x\n");
    assert_eq!(
        lines,
        vec![SseLine::Comment, SseLine::Data("{}".to_string())]
    );
}

#[test]
fn engine_keepalive_is_a_ping_for_anthropic_only() {
    let sse = b": keepalive 1/3\n\n: keepalive 2/3\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
    let text =
        String::from_utf8(pipeline(sse, 5, &[], anthropic::Encoder::new("localia")).concat())
            .unwrap();
    // The opening ping, then one per keepalive line.
    assert_eq!(text.matches("event: ping").count(), 3, "{text}");
    let text =
        String::from_utf8(pipeline(sse, 5, &[], responses::Encoder::new("localia")).concat())
            .unwrap();
    assert_eq!(
        text.matches("event: response.in_progress").count(),
        1,
        "{text}"
    );
}

#[test]
fn translation_reports_how_the_engine_ended() {
    let done = b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
    let mut t = Translation::new(anthropic::Encoder::new("m"), &[]);
    t.start();
    t.feed(done);
    let end = t.end();
    assert!(String::from_utf8(end.concat())
        .unwrap()
        .contains("message_stop"));
    assert_eq!(t.engine_end(), EngineEnd::Complete);
    assert!(t.is_done());

    let mut t = Translation::new(anthropic::Encoder::new("m"), &[]);
    t.start();
    t.feed(b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n");
    let end = String::from_utf8(t.end().concat()).unwrap();
    assert!(end.contains("event: error"), "{end}");
    assert_eq!(t.engine_end(), EngineEnd::Cut);

    let mut t = Translation::new(responses::Encoder::new("m"), &[]);
    t.start();
    let out = String::from_utf8(
        t.feed(b"data: {\"error\":{\"message\":\"generation thread died\"}}\n\n")
            .concat(),
    )
    .unwrap();
    assert!(out.contains("response.failed"), "{out}");
    assert!(t.is_done());
    assert_eq!(t.engine_end(), EngineEnd::Failed);

    let mut t = Translation::new(anthropic::Encoder::new("m"), &[]);
    t.start();
    t.feed(b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n");
    let out = String::from_utf8(t.interrupt("connection reset").concat()).unwrap();
    assert!(
        out.contains("The local model server stopped: connection reset"),
        "{out}"
    );
    assert_eq!(t.engine_end(), EngineEnd::Cut);
    assert!(
        t.feed(b"data: [DONE]\n\n").is_empty(),
        "nothing after the end"
    );
}

#[test]
fn translation_ends_at_a_stop_sequence() {
    let sse = b"data: {\"choices\":[{\"delta\":{\"content\":\"one STOP two\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"three\"}}]}\n\n";
    let mut t = Translation::new(anthropic::Encoder::new("m"), &["STOP".to_string()]);
    t.start();
    let out = String::from_utf8(t.feed(sse).concat()).unwrap();
    assert!(out.contains("\"stop_reason\":\"stop_sequence\""), "{out}");
    assert!(!out.contains("three"));
    assert!(t.is_done());
    assert_eq!(t.engine_end(), EngineEnd::Complete);
}

#[test]
fn keepalive_before_start_opens_the_stream() {
    let mut t = Translation::new(anthropic::Encoder::new("m"), &[]);
    let out = String::from_utf8(t.keepalive().concat()).unwrap();
    assert!(out.starts_with("event: message_start"), "{out}");
    let out = String::from_utf8(t.keepalive().concat()).unwrap();
    assert_eq!(out, "event: ping\ndata: {\"type\":\"ping\"}\n\n");
}
