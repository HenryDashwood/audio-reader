package com.henrydashwood.magpie.playback

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.henrydashwood.magpie.data.LibraryItem
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

data class RenderedArticle(val file: File, val chunks: List<TimedChunk>, val voiceName: String, val voiceSelection: String?, val ranges: List<TimedSpeechRange> = emptyList())

/** A bounded prototype: prepare a short article fully before handing one audio item to Media3. */
class ArticleRenderer(private val context: Context) {
    private var engine: TextToSpeech? = null
    private val completions = ConcurrentHashMap<String, CompletableDeferred<Unit>>()
    private val speechFrames = ConcurrentHashMap<String, MutableList<SpeechFrame>>()
    private val directory = File(context.cacheDir, "narration").apply { mkdirs() }

    private suspend fun initialize(): TextToSpeech {
        engine?.let { return it }
        val tts = SpeechVoices.open(context)
        try {
            tts.setSpeechRate(1f)
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) {
                    speechFrames[utteranceId]?.add(SpeechFrame(frame, start, end))
                }
                override fun onDone(utteranceId: String?) { completions.remove(utteranceId)?.complete(Unit) }
                @Deprecated("Android calls either overload depending on the engine")
                override fun onError(utteranceId: String?) { fail(utteranceId) }
                override fun onError(utteranceId: String?, errorCode: Int) { fail(utteranceId) }
                private fun fail(id: String?) {
                    completions.remove(id)?.completeExceptionally(IllegalStateException("The voice could not prepare this article. Please try again."))
                }
            })
            engine = tts
            return tts
        } catch (error: Throwable) {
            tts.shutdown()
            throw error
        }
    }

    suspend fun render(item: LibraryItem, selectedVoice: String? = null, progress: (Int, Int) -> Unit): RenderedArticle {
        val tts = initialize()
        SpeechVoices.select(tts, selectedVoice)
        val chunks = articleNarrationChunks(item.text, minOf(500, TextToSpeech.getMaxSpeechInputLength()))
        check(chunks.isNotEmpty()) { "This article has no readable text." }
        check(item.text.length <= 30_000) { "This preview supports short articles up to 30,000 characters." }
        val work = File(directory, UUID.randomUUID().toString()).apply { mkdirs() }
        val destination = File(directory, "${UUID.randomUUID()}.wav")
        var published = false
        try {
            val frameLists = mutableListOf<List<SpeechFrame>>()
            val parts = chunks.mapIndexed { index, chunk ->
                progress(index, chunks.size)
                val part = File(work, "$index.wav")
                val id = UUID.randomUUID().toString()
                val completion = CompletableDeferred<Unit>()
                completions[id] = completion
                val frames = java.util.Collections.synchronizedList(mutableListOf<SpeechFrame>())
                speechFrames[id] = frames
                try {
                    check(tts.synthesizeToFile(chunk.text, android.os.Bundle(), part, id) == TextToSpeech.SUCCESS) { "The voice is busy. Please try again." }
                    withTimeout(30_000) { completion.await() }
                } finally { completions.remove(id); speechFrames.remove(id) }
                frameLists += synchronized(frames) { frames.toList() }
                part
            }
            val timeline = withContext(Dispatchers.IO) { joinWaves(parts, chunks, destination) }
            val ranges = withContext(Dispatchers.IO) {
                parts.indices.flatMap { index ->
                    val format = inspectWave(parts[index]).format
                    val sampleRate = (4..7).fold(0L) { value, byte ->
                        value or ((format[byte].toLong() and 255) shl ((byte - 4) * 8))
                    }
                    timedSpeechRanges(timeline[index], frameLists[index], sampleRate)
                }
            }
            published = true
            return RenderedArticle(destination, timeline, tts.voice.name, selectedVoice, ranges)
        } finally {
            tts.stop()
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) {
                work.deleteRecursively()
                if (!published) destination.delete()
            }
        }
    }

    fun close() {
        engine?.stop()
        engine?.shutdown()
        engine = null
        completions.values.forEach { it.cancel() }
        completions.clear()
        speechFrames.clear()
    }

}
