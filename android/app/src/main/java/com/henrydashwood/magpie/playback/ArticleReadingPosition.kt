package com.henrydashwood.magpie.playback

/** Engine-supplied sample frames refer to the synthesized audio, not elapsed wall time. */
data class SpeechFrame(val frame: Int, val startUtf16: Int, val endUtf16: Int)
data class TimedSpeechRange(val startMs: Long, val startUtf16: Int, val endUtf16: Int)
data class ArticleReadingPosition(val itemId: String, val contentVersion: String, val startUtf16: Int, val endUtf16: Int)

fun timedSpeechRanges(chunk: TimedChunk, frames: List<SpeechFrame>, sampleRate: Long): List<TimedSpeechRange> {
    if (sampleRate <= 0) return emptyList()
    return frames.filter {
        it.frame >= 0 && it.startUtf16 >= 0 && it.endUtf16 > it.startUtf16 && it.endUtf16 <= chunk.text.text.length
    }.map {
        TimedSpeechRange(chunk.startMs + it.frame * 1000L / sampleRate,
            chunk.text.startUtf16 + it.startUtf16, chunk.text.startUtf16 + it.endUtf16)
    }.filter { it.startMs < chunk.endMs }.sortedBy { it.startMs }
}

fun readingRangeAt(chunks: List<TimedChunk>, ranges: List<TimedSpeechRange>, positionMs: Long): TimedSpeechRange? {
    val chunk = chunks.lastOrNull { it.startMs <= positionMs } ?: chunks.firstOrNull() ?: return null
    // Engines may omit range callbacks. Keep an honest chunk-start marker rather than
    // inventing word timings. Also avoid carrying the previous chunk's word into a gap.
    return ranges.lastOrNull { it.startMs <= positionMs && it.startMs >= chunk.startMs }
        ?: TimedSpeechRange(chunk.startMs, chunk.text.startUtf16, chunk.text.startUtf16 + 1)
}
