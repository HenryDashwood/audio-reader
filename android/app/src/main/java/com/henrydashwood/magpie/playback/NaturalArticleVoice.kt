package com.henrydashwood.magpie.playback

import android.content.Context
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** The natural voice reading an article's passages: each passage rendered sentence by sentence into one WAV. */
internal class NaturalArticleVoice(private val context: Context, private val folder: File, private val voice: NaturalVoice) : ArticleVoice {
    override val name = NaturalVoiceStore.PREFIX + voice.id

    override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> = NaturalVoiceEngines.use(context, folder, voice) { engine ->
        val pieces = render(chunk.text, 0, engine)
        val samples = FloatArray(pieces.sumOf { it.first.samples.size }.coerceAtLeast(NaturalVoiceEngine.SAMPLE_RATE / 4))
        val frames = mutableListOf<SpeechFrame>()
        var at = 0
        for ((sentence, offset) in pieces) {
            sentence.samples.copyInto(samples, at)
            sentence.words.forEach { frames += SpeechFrame(at + it.samples.first, offset + it.characters.first, offset + it.characters.last + 1) }
            at += sentence.samples.size
        }
        writeWave(destination, samples, NaturalVoiceEngine.SAMPLE_RATE)
        frames
    }

    // The engine is shared, and released when the voice is removed or switched.
    override fun close() = Unit

    companion object {
        /** Renders `text`, splitting it at the best place near the middle, and again, until each part fits the body. */
        suspend fun render(text: String, offset: Int, engine: NaturalVoiceEngine): List<Pair<NaturalVoiceEngine.Sentence, Int>> {
            currentCoroutineContext().ensureActive()
            return try {
                listOf(engine.render(text) to offset)
            } catch (_: NaturalVoiceEngine.NothingToSay) {
                emptyList()
            } catch (tooLong: NaturalVoiceEngine.TooLong) {
                val cut = splitPoint(text) ?: throw tooLong
                render(text.substring(0, cut), offset, engine) + render(text.substring(cut), offset + cut, engine)
            }
        }

        /** Where to split an over-long sentence: after the clause punctuation nearest the middle, else the space. */
        fun splitPoint(text: String): Int? {
            val middle = text.length / 2
            val spaces = (1 until text.length).filter { text[it] == ' ' }
            val clauses = spaces.filter { text[it - 1] in ",;:—–" }
            return (clauses.ifEmpty { spaces }).minByOrNull { Math.abs(it - middle) }?.plus(1)
        }
    }
}

/** One engine for the whole app, as loading one takes seconds and hundreds of megabytes; callers take turns. */
internal object NaturalVoiceEngines {
    private val mutex = Mutex()
    private var engine: Pair<File, NaturalVoiceEngine>? = null

    suspend fun <T> use(context: Context, folder: File, voice: NaturalVoice, block: suspend (NaturalVoiceEngine) -> T): T =
        mutex.withLock {
            withContext(Dispatchers.Default) {
                val current = engine?.takeIf { it.first == folder && it.second.voice == voice }?.second ?: run {
                    engine?.second?.close()
                    engine = null
                    NaturalVoiceEngine(folder, voice, context.cacheDir).also { engine = folder to it }
                }
                block(current)
            }
        }

    /** Frees the models, before the voice is removed. */
    suspend fun release() = mutex.withLock { engine?.second?.close(); engine = null }

    /** Frees the models once any sentence being read has finished: when playback stops for good. */
    fun releaseWhenIdle() { CoroutineScope(Dispatchers.Default).launch { release() } }
}
