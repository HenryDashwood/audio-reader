package com.henrydashwood.magpie.playback

import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Immutable text identity with a bounded, disposable cache of complete audio passages. */
class RenderedArticle internal constructor(val uri: String, private val directory: File,
    val textChunks: List<TextChunk>, private val voice: ArticleVoice, val voiceSelection: String?,
    private val onClose: (String) -> Unit) {
    val voiceName = voice.name
    @Volatile var closed = false
        private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val synthesis = Mutex()
    private val lock = Any()
    private data class Part(val file: File, var readers: Int = 0, var used: Long = 0)
    private val parts = mutableMapOf<Int, Part>()
    private var sequence = 0L
    private val durations = LongArray(textChunks.size) { estimateDuration(textChunks[it]) }
    private val markers = arrayOfNulls<List<TimedSpeechRange>>(textChunks.size)
    val chunks: List<TimedChunk> get() = synchronized(lock) {
        var start = 0L
        textChunks.mapIndexed { index, text -> TimedChunk(text, start, start + durations[index]).also { start = it.endMs } }
    }
    fun ranges(index: Int): List<TimedSpeechRange> = synchronized(lock) { markers[index].orEmpty() }
    internal fun duration(index: Int): Long = synchronized(lock) { durations[index] }
    internal val cachedFileCount: Int get() = synchronized(lock) { parts.size }

    class Lease internal constructor(val file: File, private val release: () -> Unit) : AutoCloseable {
        private var closed = false
        @Synchronized override fun close() { if (!closed) { closed = true; release() } }
    }

    /** Loader cancellation and closing the article both cancel pending synthesis. */
    suspend fun acquire(index: Int): Lease {
        require(index in textChunks.indices)
        val offered = java.util.concurrent.atomic.AtomicReference<Lease?>()
        val request = scope.async {
            val result = synthesis.withLock {
                check(!closed) { "This article is no longer open." }
                synchronized(lock) { parts[index]?.let { return@withLock lease(index, it).also(offered::set) } }
                val partial = File(directory, "${UUID.randomUUID()}.partial.wav")
                val file = File(directory, "$index.wav")
                var retained = false
                try {
                    withContext(Dispatchers.IO) { check(directory.isDirectory || directory.mkdirs()) { "Could not prepare article storage." } }
                    val frames = voice.synthesize(textChunks[index], partial)
                    val info = withContext(Dispatchers.IO) { inspectWave(partial) }
                    currentCoroutineContext().ensureActive()
                    check(!closed) { "This article is no longer open." }
                    val duration = (info.dataSize * 1000 / info.bytesPerSecond).coerceAtLeast(1)
                    val rate = (4..7).fold(0L) { value, byte -> value or ((info.format[byte].toLong() and 255) shl ((byte - 4) * 8)) }
                    withContext(Dispatchers.IO) { check(partial.renameTo(file)) { "Could not save this passage." } }
                    synchronized(lock) {
                        durations[index] = duration
                        markers[index] = timedSpeechRanges(TimedChunk(textChunks[index], 0, duration), frames, rate)
                        val part = Part(file)
                        parts[index] = part
                        retained = true
                        lease(index, part).also(offered::set)
                    }
                } finally {
                    withContext(NonCancellable + Dispatchers.IO) { partial.delete(); if (!retained) file.delete(); if (closed) directory.deleteRecursively() }
                }
            }
            result
        }
        return try { request.await().also { offered.set(null) } } catch (failure: Throwable) {
            request.cancel()
            request.invokeOnCompletion { offered.getAndSet(null)?.close() }
            throw failure
        }
    }

    // Called under lock; active file readers cannot be evicted.
    private fun lease(index: Int, part: Part): Lease {
        part.readers++; part.used = ++sequence
        evict()
        return Lease(part.file) { synchronized(lock) {
            if (parts[index] === part) { part.readers--; evict() }
        } }
    }
    private fun evict() {
        while (parts.size > 6) {
            val oldest = parts.filterValues { it.readers == 0 }.minByOrNull { it.value.used } ?: break
            parts.remove(oldest.key); oldest.value.file.delete()
        }
    }
    fun close() {
        if (closed) return
        closed = true; onClose(uri); scope.cancel(); voice.close()
        synchronized(lock) { parts.clear(); directory.deleteRecursively() }
    }
    companion object {
        /** Placeholder timeline only; bookmarks always retain original text coordinates. */
        fun estimateDuration(chunk: TextChunk): Long = (chunk.text.length * 1_000L / 15).coerceAtLeast(250)
    }
}
