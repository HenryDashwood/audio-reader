package com.henrydashwood.magpie.playback

/** Engine-supplied sample frames refer to the synthesized audio, not elapsed wall time. */
data class SpeechFrame(val frame: Int, val startUtf16: Int, val endUtf16: Int)
data class TimedSpeechRange(val startMs: Long, val startUtf16: Int, val endUtf16: Int)
data class ArticleReadingPosition(val itemId: String, val contentVersion: String, val startUtf16: Int, val endUtf16: Int)

/**
 * Google's speech engine on a Pixel 10a (Android 16) delivers onRangeStart(start, end, frame)
 * rotated, as (frame, start, end): the first word of a passage arrives as start=360, end=0,
 * frame=3. Without this, every word timing is out of range and the marker only moves per passage.
 * The rotation is accepted only when the documented order fails and every rotated range fits.
 */
internal fun engineSpeechFrames(frames: List<SpeechFrame>, textLength: Int): List<SpeechFrame> {
    fun SpeechFrame.fits() = frame >= 0 && startUtf16 >= 0 && endUtf16 > startUtf16 && endUtf16 <= textLength
    if (frames.all { it.fits() }) return frames
    val rotated = frames.map { SpeechFrame(frame = it.startUtf16, startUtf16 = it.endUtf16, endUtf16 = it.frame) }
    return if (rotated.all { it.fits() }) rotated else frames
}

fun timedSpeechRanges(chunk: TimedChunk, frames: List<SpeechFrame>, sampleRate: Long): List<TimedSpeechRange> {
    if (sampleRate <= 0) return emptyList()
    return engineSpeechFrames(frames, chunk.text.text.length).filter {
        it.frame >= 0 && it.startUtf16 >= 0 && it.endUtf16 > it.startUtf16 && it.endUtf16 <= chunk.text.text.length
    }.map {
        TimedSpeechRange(chunk.startMs + it.frame * 1000L / sampleRate,
            chunk.text.startUtf16 + it.startUtf16, chunk.text.startUtf16 + it.endUtf16)
    }.filter { it.startMs < chunk.endMs }.sortedBy { it.startMs }
}

/**
 * Real milliseconds until the marker next has something to show: the next word's start in `ranges`, or the end of
 * `chunk`, at `speed`, never more than `longest` (pauses, seeks and speed changes are caught by then), and at least a
 * few milliseconds so a word due now is shown on the next pass rather than in a tight loop.
 */
internal fun msUntilNextWord(ranges: List<TimedSpeechRange>, chunk: TimedChunk, positionMs: Long, speed: Float, longest: Long): Long {
    val next = ranges.firstOrNull { it.startMs > positionMs }?.startMs ?: chunk.endMs
    if (next <= positionMs || speed <= 0f) return longest
    return ((next - positionMs) / speed).toLong().plus(1).coerceIn(4, longest)
}

/**
 * The player's position between its own updates. At 2× on a Pixel 10a ExoPlayer's position moves in steps of about
 * 250 ms of audio, roughly as often as it tops up the audio output, so a marker following it moved up to a word late
 * and skipped short words, where iOS's follows the audio clock. Speed applied by the AudioTrack instead made the steps
 * longer, not shorter. A step lands where the audio is heard (measured with a microphone), so between steps this runs
 * on from the last one at the playback speed, never more than `cap` ahead of it in case a step is late. With it, the
 * marker needs no delay or lead of its own, as on iOS.
 */
internal class SmoothedPosition(private val cap: Long = 400) {
    private var reported = -1L
    private var reportedAt = 0L

    fun position(reportedMs: Long, playing: Boolean, speed: Float, nowMs: Long): Long {
        if (reportedMs != reported || !playing) {
            reported = reportedMs; reportedAt = nowMs
            return reportedMs
        }
        return reportedMs + ((nowMs - reportedAt) * speed).toLong().coerceIn(0, cap)
    }
}

fun readingRangeAt(chunks: List<TimedChunk>, ranges: List<TimedSpeechRange>, positionMs: Long): TimedSpeechRange? {
    val chunk = chunks.lastOrNull { it.startMs <= positionMs } ?: chunks.firstOrNull() ?: return null
    // Engines may omit range callbacks. Keep an honest chunk-start marker rather than
    // inventing word timings. Also avoid carrying the previous chunk's word into a gap.
    return ranges.lastOrNull { it.startMs <= positionMs && it.startMs >= chunk.startMs }
        ?: TimedSpeechRange(chunk.startMs, chunk.text.startUtf16, chunk.text.startUtf16 + 1)
}
