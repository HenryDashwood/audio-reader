//! The C interface Swift calls. Results are JSON strings the caller frees with `magpie_g2p_free_string`.

use crate::Phonemizer;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

/// `{"phonemes": …, "tokens": [{"text", "phonemes", "whitespace"}]}`, or `{"error": …}`.
pub(crate) fn phonemize_json(p: &Phonemizer, text: &str) -> String {
    match catch_unwind(AssertUnwindSafe(|| p.phonemize(text))) {
        Ok(Ok(out)) => serde_json::to_string(&out).unwrap_or_else(|e| error_json(&e.to_string())),
        Ok(Err(e)) => error_json(&e),
        Err(_) => error_json("the phonemizer panicked"),
    }
}

pub(crate) fn error_json(message: &str) -> String {
    serde_json::json!({ "error": message }).to_string()
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

/// Load the phonemizer for one accent from the voice's folder. Null on failure, with `*error` set to a message the
/// caller frees with `magpie_g2p_free_string` (when `error` isn't null).
///
/// # Safety
/// `dir` is a NUL-terminated UTF-8 path; `error` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_g2p_open(dir: *const c_char, british: bool, error: *mut *mut c_char) -> *mut Phonemizer {
    let fail = |message: String| {
        if !error.is_null() {
            unsafe { *error = into_c(message) };
        }
        std::ptr::null_mut()
    };
    let Ok(dir) = (unsafe { CStr::from_ptr(dir) }).to_str() else { return fail("the path isn't UTF-8".into()) };
    match catch_unwind(|| Phonemizer::open(Path::new(dir), british)) {
        Ok(Ok(p)) => Box::into_raw(Box::new(p)),
        Ok(Err(e)) => fail(e),
        Err(_) => fail("the phonemizer panicked while loading".into()),
    }
}

/// Phonemes for `text`, as JSON. Safe to call from several threads at once.
///
/// # Safety
/// `p` came from `magpie_g2p_open` and hasn't been closed; `text` is NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_g2p_phonemize(p: *const Phonemizer, text: *const c_char) -> *mut c_char {
    let p = unsafe { &*p };
    into_c(match (unsafe { CStr::from_ptr(text) }).to_str() {
        Ok(text) => phonemize_json(p, text),
        Err(_) => error_json("the text isn't UTF-8"),
    })
}

/// # Safety
/// `s` came from this library and hasn't been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_g2p_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// # Safety
/// `p` came from `magpie_g2p_open` and no call on it is in progress.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn magpie_g2p_close(p: *mut Phonemizer) {
    if !p.is_null() {
        drop(unsafe { Box::from_raw(p) });
    }
}
