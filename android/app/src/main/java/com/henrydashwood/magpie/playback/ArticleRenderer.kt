package com.henrydashwood.magpie.playback

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.henrydashwood.magpie.data.LibraryItem
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.*

/** One offline voice, owned by one article preparation/playback lifetime. */
internal interface ArticleVoice {
    val name: String
    suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame>
    fun close()
}

private class OfflineArticleVoice(private val tts: TextToSpeech) : ArticleVoice {
    override val name: String = tts.voice.name
    private val completions = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val speechFrames = ConcurrentHashMap<String, MutableList<SpeechFrame>>()
    init {
        tts.setSpeechRate(1f)
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) = Unit
            override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) {
                speechFrames[utteranceId]?.add(SpeechFrame(frame, start, end))
            }
            override fun onDone(utteranceId: String?) { completions.remove(utteranceId)?.complete(Unit) }
            @Deprecated("Android calls either overload depending on the engine")
            override fun onError(utteranceId: String?) = fail(utteranceId)
            override fun onError(utteranceId: String?, errorCode: Int) = fail(utteranceId)
            private fun fail(id: String?) {
                completions.remove(id)?.completeExceptionally(IllegalStateException("The voice could not prepare this passage. Please try again."))
            }
        })
    }
    override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> {
        val id = UUID.randomUUID().toString()
        val completion = CompletableDeferred<Unit>()
        val frames = java.util.Collections.synchronizedList(mutableListOf<SpeechFrame>())
        completions[id] = completion; speechFrames[id] = frames
        try {
            check(tts.synthesizeToFile(chunk.text, android.os.Bundle(), destination, id) == TextToSpeech.SUCCESS) { "The voice is busy. Please try again." }
            withTimeout(30_000) { completion.await() }
            return synchronized(frames) { frames.toList() }
        } finally {
            completions.remove(id); speechFrames.remove(id)
            tts.stop()
        }
    }
    override fun close() {
        tts.stop(); tts.shutdown()
        completions.values.forEach { it.cancel() }; completions.clear(); speechFrames.clear()
    }
    companion object {
        suspend fun open(context: Context, selected: String?): ArticleVoice {
            val tts = SpeechVoices.open(context)
            return try { SpeechVoices.select(tts, selected); OfflineArticleVoice(tts) }
            catch (error: Throwable) { tts.shutdown(); throw error }
        }
    }
}

/** Prepares only the resume passage; Media3 requests subsequent passages on demand. */
class ArticleRenderer internal constructor(private val context: Context,
    private val openVoice: suspend (String?) -> ArticleVoice = { OfflineArticleVoice.open(context, it) }) {
    private val articles = ConcurrentHashMap<String, RenderedArticle>()

    internal fun find(uri: String): RenderedArticle? = articles[uri]?.takeUnless { it.closed }

    suspend fun render(item: LibraryItem, selectedVoice: String? = null, startOffset: Int = 0,
        progress: (Int, Int) -> Unit): RenderedArticle {
        val chunks = withContext(Dispatchers.Default) {
            articleNarrationChunks(item.text, minOf(500, TextToSpeech.getMaxSpeechInputLength()))
        }
        check(chunks.isNotEmpty()) { "This article has no readable text." }
        val voice = openVoice(selectedVoice)
        val id = UUID.randomUUID().toString()
        val directory = File(context.cacheDir, "narration/$id")
        val audio = RenderedArticle("magpie-article://$id", directory, chunks, voice, selectedVoice) { articles.remove(it) }
        try {
            progress(0, 1)
            val first = chunks.indexOfLast { it.startUtf16 <= startOffset }.coerceAtLeast(0)
            audio.acquire(first).close()
            currentCoroutineContext().ensureActive()
            articles[audio.uri] = audio
            progress(1, 1)
            return audio
        } catch (error: Throwable) { audio.close(); throw error }
    }
    fun close() { articles.values.toList().forEach { it.close() }; articles.clear() }
}
