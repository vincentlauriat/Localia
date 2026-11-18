use localia_router::config::*;
use localia_router::engine::EngineKind;
use localia_router::{token, version};
use std::os::unix::fs::PermissionsExt;

fn load_json(json: &str) -> ProxyConfig {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("config.json");
    std::fs::write(&p, json).unwrap();
    ProxyConfig::load(&p)
}

#[test]
fn config_clamps_retention() {
    assert_eq!(load_json(r#"{"retentionDays":400}"#).retention_days, 90);
    assert_eq!(load_json(r#"{"retentionDays":0}"#).retention_days, 1);
}

#[test]
fn config_defaults_on_corrupt_file() {
    assert_eq!(load_json("not json{"), ProxyConfig::default());
    let d = tempfile::tempdir().unwrap();
    assert_eq!(ProxyConfig::load(&d.path().join("missing.json")), ProxyConfig::default());
}

fn ollama_target() -> TargetSpec {
    TargetSpec { engine: EngineKind::Ollama, model: "qwen3".into(), context_tokens: 32768 }
}

#[test]
fn config_without_routing_keeps_saved_routing() {
    let saved = ProxyConfig {
        routing: Some(RoutingConfig { active: Some(ollama_target()), equivalents: vec![], mlx_model: None }),
        ..Default::default()
    };
    let incoming: ProxyConfig = serde_json::from_str(r#"{"logContent":true,"retentionDays":7}"#).unwrap();
    let merged = saved.clone().merged(incoming);
    assert!(merged.log_content);
    assert_eq!(merged.routing, saved.routing);
}

#[test]
fn engine_kind_serializes_as_swift_raw_values() {
    for (k, s) in [(EngineKind::Ollama, "ollama"), (EngineKind::LlamaCpp, "llamaCpp"), (EngineKind::Mlx, "mlx")] {
        assert_eq!(k.as_str(), s);
        let j = serde_json::to_string(&k).unwrap();
        assert_eq!(j, format!("\"{s}\""));
        assert_eq!(serde_json::from_str::<EngineKind>(&j).unwrap(), k);
    }
}

#[test]
fn config_save_roundtrips_sorted_and_atomic() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("config.json");
    let c = ProxyConfig {
        log_content: true,
        retention_days: 30,
        routing: Some(RoutingConfig {
            active: Some(TargetSpec { engine: EngineKind::LlamaCpp, model: "m".into(), context_tokens: 8 }),
            equivalents: vec![],
            mlx_model: None,
        }),
    };
    c.save(&p).unwrap();
    assert_eq!(ProxyConfig::load(&p), c);
    let text = std::fs::read_to_string(&p).unwrap();
    assert!(text.find("logContent").unwrap() < text.find("retentionDays").unwrap());
    assert!(text.find("retentionDays").unwrap() < text.find("routing").unwrap());
    assert!(!d.path().join("config.json.tmp").exists());
}

#[test]
fn token_is_created_once_with_0600() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("token");
    let t = token::load_or_create(&p).unwrap();
    assert_eq!(t.len(), 64);
    assert!(t.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode(), 0o100600);
    assert_eq!(token::load_or_create(&p).unwrap(), t);
}

#[test]
fn token_matches_is_exact() {
    assert!(token::matches("abc", "abc"));
    assert!(!token::matches("abd", "abc"));
    assert!(!token::matches("ab", "abc"));
    assert!(!token::matches("", ""));
}

#[test]
fn version_from_bundle_and_dev() {
    let d = tempfile::tempdir().unwrap();
    let macos = d.path().join("X.app/Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    std::fs::write(
        d.path().join("X.app/Contents/Info.plist"),
        r#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleVersion</key><string>9</string></dict></plist>"#,
    )
    .unwrap();
    let exe = macos.join("exe");
    std::fs::write(&exe, "").unwrap();
    assert_eq!(version::app_version_from(&exe), "9");
    assert_eq!(version::app_version_from(std::path::Path::new("/usr/bin/true")), "dev");
    assert_eq!(version::app_version_from(std::path::Path::new("exe")), "dev");
}
