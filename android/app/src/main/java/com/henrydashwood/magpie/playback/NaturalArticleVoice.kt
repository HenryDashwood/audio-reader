package com.henrydashwood.magpie.playback

import android.content.Context
import android.util.Log
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.delay
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
                // Each half must be strictly shorter, or the recursion never ends.
                if (cut <= 0 || cut >= text.length) throw tooLong
                render(text.substring(0, cut), offset, engine) + render(text.substring(cut), offset + cut, engine)
            }
        }

        /**
         * Where to split an over-long sentence: after the clause punctuation nearest the middle, else the space.
         *
         * Only a space with something to say on both sides counts. A first half keeps the space it was cut after,
         * so "…accurate predictions, " ends in one: choosing it again split the half into itself and nothing, and
         * the voice rendered the same text for ever.
         */
        fun splitPoint(text: String): Int? {
            val middle = text.length / 2
            fun speaks(part: String) = part.any { it.isLetterOrDigit() }
            val spaces = (1 until text.length).filter {
                text[it] == ' ' && speaks(text.substring(0, it)) && speaks(text.substring(it + 1))
            }
            val clauses = spaces.filter { text[it - 1] in ",;:—–" }
            return (clauses.ifEmpty { spaces }).minByOrNull { Math.abs(it - middle) }?.plus(1)
        }
    }
}

/** One engine for the whole app, as loading one takes seconds and hundreds of megabytes; callers take turns. */
internal object NaturalVoiceEngines {
    @Volatile private var mutex = Mutex()
    @Volatile private var engine: Pair<File, NaturalVoiceEngine>? = null

    suspend fun <T> use(context: Context, folder: File, voice: NaturalVoice, block: suspend (NaturalVoiceEngine) -> T): T =
        mutex.withLock {
            withContext(Dispatchers.Default) {
                val current = engine?.takeIf { it.first == folder && it.second.voice == voice }?.second ?: run {
                    engine?.second?.close()
                    engine = null
                    NaturalVoiceEngine(folder, voice, context.cacheDir).also { engine = folder to it }
                }
                try { block(current) } finally {
                    // Abandoned while this call hung: nobody else holds it now, so it goes when the call finally returns.
                    if (engine?.second !== current) current.close()
                }
            }
        }

    /**
     * Gives up on an engine stuck inside a render, as iOS does: a native call can't be interrupted, and it holds the
     * lock, so every later passage would wait behind it. The next caller gets a new lock and loads a new engine; the
     * stuck one is closed if its call ever returns.
     */
    fun abandon() { engine = null; mutex = Mutex() }

    /**
     * Starts loading the selected natural speaker's models while the article's text is fetched, as iOS does, so the
     * first passage doesn't wait for both in turn. Nothing to do for a Google voice; a failure here is left for the
     * first passage to meet and fall back from.
     */
    fun warmUp(context: Context, selection: String?) {
        val speaker = selection?.takeIf { it.startsWith(NaturalVoiceStore.PREFIX) }?.removePrefix(NaturalVoiceStore.PREFIX) ?: return
        val app = context.applicationContext
        CoroutineScope(Dispatchers.Default).launch {
            val folder = NaturalVoiceStore.folder(app) ?: return@launch
            runCatching { use(app, folder, NaturalVoice(speaker)) { } }
                .onFailure { Log.w("NaturalVoice", "Could not load the natural voice ahead of time: ${it.message}") }
        }
    }

    /** Frees the models, before the voice is removed. */
    suspend fun release() = mutex.withLock { engine?.second?.close(); engine = null }

    /** Frees the models once any sentence being read has finished: when playback stops for good. */
    fun releaseWhenIdle() { CoroutineScope(Dispatchers.Default).launch { release() } }
}

/**
 * Reads a passage with the natural voice, or with the Google voice if the natural one fails or hangs on it, as iOS
 * falls back to the system voice. Playback carries on instead of stopping on "Open the item and try again", and the
 * next passage tries the natural voice again. `limit` allows the passage's own length in real time, as a phone that
 * can't use its GPU renders at little better than that, plus time to load the models: about 20 s for a sentence and
 * 48 s for the longest passage. A hang is that much silence before the Google voice takes over.
 */
internal class FallbackArticleVoice(private val primary: ArticleVoice,
    private val limit: (TextChunk) -> Long = { 15_000L + it.text.length * 1_000L / 15 },
    private val abandon: () -> Unit = NaturalVoiceEngines::abandon,
    private val openFallback: suspend () -> ArticleVoice) : ArticleVoice {
    override val name = primary.name
    private var fallback: ArticleVoice? = null  // RenderedArticle synthesises one passage at a time
    private val detached = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile private var closed = false

    override suspend fun synthesize(chunk: TextChunk, destination: File): List<SpeechFrame> {
        // Its own file and its own scope: a hung render can neither hold this call nor write over the fallback later.
        val own = File(destination.path + ".natural")
        val outcome = Any()
        var givenUp = false  // Guarded by `outcome`: once set, the attempt may no longer save its audio
        val attempt = detached.async {
            try {
                val frames = primary.synthesize(chunk, own)
                synchronized(outcome) { check(!givenUp && own.renameTo(destination)) { "Could not save this passage." } }
                frames
            } finally { own.delete() }
        }
        fun giveUp() { synchronized(outcome) { givenUp = true }; attempt.cancel() }
        val allowed = limit(chunk)
        val reason = try {
            return withTimeout(allowed) { attempt.await() }
        } catch (timeout: TimeoutCancellationException) {
            giveUp(); abandon(); "no result after ${allowed / 1000} s"
        } catch (cancelled: CancellationException) {
            giveUp(); throw cancelled
        } catch (error: Exception) {
            error.message ?: error.javaClass.simpleName
        }
        currentCoroutineContext().ensureActive()
        check(!closed) { "This article is no longer open." }
        Log.w(TAG, "Natural voice failed on a passage ($reason); reading it with the Google voice")
        val voice = fallback ?: openFallback().also { fallback = it }
        return voice.synthesize(chunk, destination)
    }

    override fun close() { closed = true; detached.cancel(); primary.close(); fallback?.close(); fallback = null }

    private companion object { const val TAG = "NaturalVoice" }
}

/**
 * Frees the natural voice once the player has been still for `after`: the models take over a gigabyte, and a paused
 * article could otherwise keep them until the service ends. Playing again before then keeps them. Resuming after a
 * release plays what is already rendered while the models load again, which takes a few seconds.
 */
internal class IdleRelease(private val scope: CoroutineScope, private val after: Long = 5 * 60_000L,
    private val release: suspend () -> Unit = { withContext(Dispatchers.Default) { NaturalVoiceEngines.release() } }) {
    private var pending: Job? = null

    fun playing(isPlaying: Boolean) {
        pending?.cancel()
        pending = if (isPlaying) null else scope.launch { delay(after); release() }
    }

    fun cancel() { pending?.cancel(); pending = null }
}
