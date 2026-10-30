//! Cursor seals `cursorAuth/accessToken` as `cursor-safe-storage:v1:<base64>`.
//!
//! Under the hood that is Chromium/Electron OSCrypt: the editor's
//! `%APPDATA%\Cursor\Local State` holds `os_crypt.encrypted_key` (base64 of
//! `DPAPI` + a blob only this Windows user can unprotect), and each sealed
//! value is `v10` + 12-byte nonce + AES-256-GCM ciphertext||tag.
//!
//! Older Cursor builds wrote the JWT in the clear; those values pass through
//! unchanged. Unknown prefixes / versions yield `None` so the caller can
//! surface `needsAuth` instead of posting ciphertext as a session cookie.

use base64::Engine;

const SEALED_PREFIX: &str = "cursor-safe-storage:v1:";
const SEALED_ANY: &str = "cursor-safe-storage:";
const V10: &[u8] = b"v10";
const DPAPI_TAG: &[u8] = b"DPAPI";
const GCM_NONCE_LEN: usize = 12;
const GCM_TAG_LEN: usize = 16;
const WINDOWS_KEY_LEN: usize = 32;

/// Resolve a stored access-token value to the JWT the usage API expects.
pub fn decode_access_token(stored: &str) -> Option<String> {
    let trimmed = stored.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(payload) = trimmed.strip_prefix(SEALED_PREFIX) {
        return decrypt_v1(payload);
    }
    if trimmed.starts_with(SEALED_ANY) {
        // Future envelope we do not know how to open yet.
        return None;
    }
    Some(trimmed.to_string())
}

fn decrypt_v1(payload_b64: &str) -> Option<String> {
    #[cfg(windows)]
    {
        let key = windows_oscrypt_key()?;
        decrypt_windows_v10(&key, payload_b64)
    }
    #[cfg(not(windows))]
    {
        let _ = payload_b64;
        None
    }
}

/// Pure half: AES-256-GCM under a 32-byte OSCrypt key.
fn decrypt_windows_v10(key: &[u8; WINDOWS_KEY_LEN], payload_b64: &str) -> Option<String> {
    use ring::aead::{self, LessSafeKey, UnboundKey, AES_256_GCM};

    let raw = base64::engine::general_purpose::STANDARD
        .decode(payload_b64.trim())
        .ok()?;
    let body = raw.strip_prefix(V10)?;
    if body.len() < GCM_NONCE_LEN + GCM_TAG_LEN {
        return None;
    }
    let (nonce_bytes, sealed) = body.split_at(GCM_NONCE_LEN);
    let key = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).ok()?);
    let nonce = aead::Nonce::try_assume_unique_for_key(nonce_bytes).ok()?;
    let mut buf = sealed.to_vec();
    let plain = key.open_in_place(nonce, aead::Aad::empty(), &mut buf).ok()?;
    let text = std::str::from_utf8(plain).ok()?.trim();
    if text.is_empty() {
        return None;
    }
    Some(text.to_string())
}

/// `os_crypt.encrypted_key` from a Chromium `Local State` JSON document,
/// stripped of its `DPAPI` tag. Pure — the caller unprotects the blob.
fn windows_protected_key(local_state: &[u8]) -> Option<Vec<u8>> {
    let root: serde_json::Value = serde_json::from_slice(local_state).ok()?;
    let encoded = root
        .pointer("/os_crypt/encrypted_key")
        .and_then(|v| v.as_str())?;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(encoded.trim())
        .ok()?;
    let blob = raw.strip_prefix(DPAPI_TAG)?;
    if blob.is_empty() {
        return None;
    }
    Some(blob.to_vec())
}

#[cfg(windows)]
fn windows_oscrypt_key() -> Option<[u8; WINDOWS_KEY_LEN]> {
    let path = dirs::config_dir()?.join("Cursor").join("Local State");
    let raw = std::fs::read(path).ok()?;
    let protected = windows_protected_key(&raw)?;
    let key = dpapi_unprotect(&protected)?;
    <[u8; WINDOWS_KEY_LEN]>::try_from(key.as_slice()).ok()
}

#[cfg(windows)]
fn dpapi_unprotect(blob: &[u8]) -> Option<Vec<u8>> {
    use windows::Win32::Foundation::{LocalFree, HLOCAL};
    use windows::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };

    let input = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(blob.len()).ok()?,
        pbData: blob.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    // SAFETY: `input` only reads `blob` for the duration of the call; on success
    // `output` owns a LocalAlloc buffer we copy and free exactly once.
    // windows 0.58 takes raw pointers (not Option wrappers).
    let ok = unsafe {
        CryptUnprotectData(
            &input,
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok.is_err() || output.pbData.is_null() {
        return None;
    }
    let plain = unsafe {
        std::slice::from_raw_parts(output.pbData, output.cbData as usize)
    }
    .to_vec();
    unsafe {
        let _ = LocalFree(HLOCAL(output.pbData as *mut _));
    };
    Some(plain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::aead::{self, LessSafeKey, UnboundKey, AES_256_GCM};

    fn seal_windows(key: &[u8; WINDOWS_KEY_LEN], nonce: [u8; GCM_NONCE_LEN], plain: &[u8]) -> String {
        let key = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).unwrap());
        let mut buf = plain.to_vec();
        let tag = key
            .seal_in_place_separate_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::empty(),
                &mut buf,
            )
            .unwrap();
        let mut out = Vec::with_capacity(V10.len() + nonce.len() + buf.len() + tag.as_ref().len());
        out.extend_from_slice(V10);
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&buf);
        out.extend_from_slice(tag.as_ref());
        base64::engine::general_purpose::STANDARD.encode(out)
    }

    #[test]
    fn plaintext_tokens_pass_through() {
        assert_eq!(
            decode_access_token("header.payload.sig").as_deref(),
            Some("header.payload.sig")
        );
    }

    #[test]
    fn unknown_safe_storage_version_is_refused() {
        assert_eq!(decode_access_token("cursor-safe-storage:v2:abc"), None);
        assert_eq!(decode_access_token("cursor-safe-storage:"), None);
    }

    #[test]
    fn windows_v10_round_trip_under_a_fixed_key() {
        let key = [0x11u8; WINDOWS_KEY_LEN];
        let nonce = [0x22u8; GCM_NONCE_LEN];
        let plain = b"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.sig";
        let sealed = seal_windows(&key, nonce, plain);
        assert_eq!(
            decrypt_windows_v10(&key, &sealed).as_deref(),
            Some(std::str::from_utf8(plain).unwrap())
        );
    }

    #[test]
    fn local_state_protected_key_strips_dpapi_tag() {
        let inner32 = [0xabu8; 32];
        let mut tagged = DPAPI_TAG.to_vec();
        tagged.extend_from_slice(&inner32);
        let encoded = base64::engine::general_purpose::STANDARD.encode(&tagged);
        let json = format!(r#"{{"os_crypt":{{"encrypted_key":"{encoded}"}}}}"#);
        assert_eq!(windows_protected_key(json.as_bytes()).as_deref(), Some(inner32.as_slice()));
    }

    #[cfg(windows)]
    #[test]
    fn live_cursor_store_decrypts_when_editor_is_signed_in() {
        let Some(path) = crate::cursor::store_url() else { return };
        let Ok(conn) = rusqlite::Connection::open_with_flags(
            &path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) else {
            return;
        };
        let Ok(stored) = conn.query_row(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            [],
            |r| r.get::<_, String>(0),
        ) else {
            return;
        };
        if !stored.starts_with(SEALED_PREFIX) {
            return;
        }
        let token = decode_access_token(&stored).expect("sealed Cursor token should decrypt");
        assert!(token.contains('.'), "decrypted value should look like a JWT");
        assert!(!token.starts_with(SEALED_ANY));
    }
}
