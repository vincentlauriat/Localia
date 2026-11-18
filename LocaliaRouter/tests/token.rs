use localia_router::token;
use std::os::unix::fs::PermissionsExt;

fn mode(p: &std::path::Path) -> u32 {
    std::fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn creates_a_64_hex_token_with_mode_0600() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("token");
    let t = token::load_or_create(&p).unwrap();
    assert_eq!(t.len(), 64);
    assert!(t.chars().all(|c| c.is_ascii_hexdigit()));
    assert_eq!(mode(&p), 0o600);
}

#[test]
fn reapplies_0600_to_an_existing_token() {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("token");
    std::fs::write(&p, "ab12").unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(token::load_or_create(&p).unwrap(), "ab12");
    assert_eq!(mode(&p), 0o600);
}
