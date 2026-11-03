package com.henrydashwood.magpie.playback

import java.io.File
import org.json.JSONObject

/** One token as misaki splits the text. `start` and `end` are UTF-16 offsets into the text given; a written-out
 *  abbreviation ("Street" for "St.") covers the abbreviation. */
data class PhonemeToken(val text: String, val phonemes: String, val whitespace: String, val start: Int, val end: Int)
data class Phonemes(val phonemes: String, val tokens: List<PhonemeToken>)

/**
 * Text to the phonemes Kokoro reads, through native/g2p: misaki in Rust, with the lexicon and model the voice
 * download adds for words misaki can't say, and abbreviations written out first. The Rust side takes `&self` and
 * guards its one cache with a mutex, so one instance can be shared between threads.
 */
class NativePhonemizer(folder: File, british: Boolean) : AutoCloseable {
    private var handle = open(folder.path, british)

    fun phonemize(text: String): Phonemes {
        check(handle != 0L) { "The phonemizer is closed." }
        val json = JSONObject(phonemize(handle, text) ?: error("The voice could not read this text."))
        if (json.has("error")) error(json.getString("error"))
        val tokens = json.getJSONArray("tokens")
        return Phonemes(json.getString("phonemes"), List(tokens.length()) { i ->
            val token = tokens.getJSONObject(i)
            PhonemeToken(token.getString("text"), token.getString("phonemes"), token.getString("whitespace"),
                token.getInt("start"), token.getInt("end"))
        })
    }

    @Synchronized override fun close() {
        if (handle != 0L) { close(handle); handle = 0L }
    }

    private companion object {
        init { System.loadLibrary("magpie_g2p") }
        @JvmStatic external fun open(dir: String, british: Boolean): Long
        @JvmStatic external fun phonemize(handle: Long, text: String): String?
        @JvmStatic external fun close(handle: Long)
    }
}
