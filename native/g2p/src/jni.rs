//! The JNI functions behind `com.henrydashwood.magpie.playback.NativePhonemizer`.

use crate::Phonemizer;
use crate::ffi::{error_json, phonemize_json};
use jni::JNIEnv;
use jni::objects::{JClass, JString};
use jni::sys::{jboolean, jlong, jstring};
use std::path::Path;

fn throw(env: &mut JNIEnv, message: &str) {
    let _ = env.throw_new("java/lang/IllegalStateException", message);
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_henrydashwood_magpie_playback_NativePhonemizer_open(
    mut env: JNIEnv,
    _class: JClass,
    dir: JString,
    british: jboolean,
) -> jlong {
    let dir: String = match env.get_string(&dir) {
        Ok(s) => s.into(),
        Err(e) => {
            throw(&mut env, &e.to_string());
            return 0;
        }
    };
    match std::panic::catch_unwind(|| Phonemizer::open(Path::new(&dir), british != 0)) {
        Ok(Ok(p)) => Box::into_raw(Box::new(p)) as jlong,
        Ok(Err(e)) => {
            throw(&mut env, &e);
            0
        }
        Err(_) => {
            throw(&mut env, "the phonemizer panicked while loading");
            0
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_henrydashwood_magpie_playback_NativePhonemizer_phonemize(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    text: JString,
) -> jstring {
    let json = match env.get_string(&text) {
        Ok(text) => phonemize_json(unsafe { &*(handle as *const Phonemizer) }, &String::from(text)),
        Err(e) => error_json(&e.to_string()),
    };
    env.new_string(json).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_henrydashwood_magpie_playback_NativePhonemizer_close(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        drop(unsafe { Box::from_raw(handle as *mut Phonemizer) });
    }
}
