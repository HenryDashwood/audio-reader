package com.henrydashwood.magpie.playback

import android.content.Context
import android.os.Build
import com.google.android.play.core.assetpacks.AssetPackManagerFactory
import com.henrydashwood.magpie.BuildConfig
import com.henrydashwood.magpie.data.PreviewStore
import java.io.File

/** One of the downloadable voice's speakers, by Kokoro's name for it. */
data class NaturalVoice(val id: String) {
    /** Kokoro's names start with the accent: "b" British, "a" American. */
    val isBritish get() = id.startsWith("b")
    val label: String get() {
        val name = id.substringAfterLast('_').replaceFirstChar { it.uppercase() }
        return "$name (${if (isBritish) "British" else "American"})"
    }
}

/** Where the downloadable voice is, and which of its speakers reads articles. */
object NaturalVoiceStore {
    /** The on-demand Play asset pack the voice arrives in. Its files sit under `NaturalVoice/`. */
    const val PACK = "natural_voice"
    /** How an article's voice selection names a natural speaker, beside Google voices' own names. */
    const val PREFIX = "natural:"

    /** What a usable voice folder holds, beside at least one speaker in `voices/`. */
    val requiredFiles = listOf(
        "vocab.json", "voice.json", "tokens.onnx", "prosody.onnx", "source.onnx", "body.tflite",
        "tagger.bin", "tagger_labels.txt", "us_gold.json", "us_silver.json", "gb_gold.json", "gb_silver.json",
        "lexicon_us.json", "lexicon_gb.json", "g2p_us.g2p", "g2p_gb.g2p",
    )

    /** The phonemizer is built for 64-bit ARM only: every current phone, and emulators on Apple silicon. */
    val isSupported: Boolean get() = "arm64-v8a" in Build.SUPPORTED_ABIS

    /**
     * The folder holding the voice's models, text files and speakers: the downloaded asset pack's.
     *
     * A debug build also takes a folder copied to its external files directory, which `adb push` can write, and
     * `adb shell chmod -R a+rwX` then lets the app read: see android/README.md.
     */
    fun folder(context: Context): File? {
        if (!isSupported) return null
        if (BuildConfig.DEBUG) context.getExternalFilesDir(null)?.let { File(it, "NaturalVoice") }?.takeIf(::isUsable)?.let { return it }
        val location = runCatching { AssetPackManagerFactory.getInstance(context).getPackLocation(PACK) }.getOrNull() ?: return null
        return location.assetsPath()?.let { File(it, "NaturalVoice") }?.takeIf(::isUsable)
    }

    /** Whether `folder` has everything the engine reads, so a partial or damaged download is never offered. */
    fun isUsable(folder: File) = requiredFiles.all { File(folder, it).isFile } && voices(folder).isNotEmpty()

    /** The speakers in the folder, British first. */
    fun voices(folder: File): List<NaturalVoice> = File(folder, "voices").list().orEmpty()
        .filter { it.endsWith(".bin") }.map { NaturalVoice(it.removeSuffix(".bin")) }
        .sortedWith(compareBy<NaturalVoice> { !it.isBritish }.thenBy { it.id })

    /** What reads articles: the chosen natural speaker while the voice is here, else the chosen Google voice. */
    fun articleVoice(context: Context, store: PreviewStore): String? {
        val chosen = store.naturalVoice ?: return store.voiceId
        val folder = folder(context) ?: return store.voiceId
        return if (voices(folder).any { it.id == chosen }) PREFIX + chosen else store.voiceId
    }
}
