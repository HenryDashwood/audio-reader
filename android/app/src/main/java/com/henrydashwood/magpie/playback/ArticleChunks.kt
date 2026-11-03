package com.henrydashwood.magpie.playback

data class TextChunk(val text: String, val startUtf16: Int, val endUtf16: Int)
data class ArticleBookmark(val contentVersion: String, val offsetUtf16: Int)
data class TimedChunk(val text: TextChunk, val startMs: Long, val endMs: Long)

/** Kotlin string indices are UTF-16. Keep original ranges; never rejoin normalized words. */
fun articleChunks(text: String, limit: Int = 500): List<TextChunk> {
    require(limit >= 2)
    val chunks = mutableListOf<TextChunk>()
    var start = 0
    while (start < text.length) {
        while (start < text.length && text[start].isWhitespace()) start++
        if (start == text.length) break
        var end = minOf(start + limit, text.length)
        if (end < text.length) {
            val boundary = (end - 1 downTo start + limit / 2).firstOrNull {
                text[it].isWhitespace() && text[it - 1] in ".!?\n"
            } ?: (end - 1 downTo start + 1).firstOrNull { text[it].isWhitespace() }
            if (boundary != null) end = boundary
            if (Character.isHighSurrogate(text[end - 1]) && Character.isLowSurrogate(text[end])) end--
        }
        var trimmedEnd = end
        while (trimmedEnd > start && text[trimmedEnd - 1].isWhitespace()) trimmedEnd--
        if (trimmedEnd > start) chunks += TextChunk(text.substring(start, trimmedEnd), start, trimmedEnd)
        start = end
    }
    return chunks
}

/** Conservative resume: repeat the current chunk rather than silently skipping unheard words. */
fun bookmarkAt(chunks: List<TimedChunk>, positionMs: Long, version: String): ArticleBookmark? {
    val chunk = chunks.lastOrNull { it.startMs <= positionMs } ?: chunks.firstOrNull() ?: return null
    return ArticleBookmark(version, chunk.text.startUtf16)
}

fun resumeAt(chunks: List<TimedChunk>, bookmark: ArticleBookmark?, version: String): Long {
    if (bookmark == null || bookmark.contentVersion != version) return 0
    return chunks.lastOrNull { it.text.startUtf16 <= bookmark.offsetUtf16 }?.startMs ?: 0
}

/** Keep a sentence boundary even when an engine supplies no per-word audio markers. As on iOS, a "sentence" that ends
 *  in a title or abbreviation ("Mr.", "St.") or runs on into a number or a lower-case word continues the one before. */
fun articleNarrationChunks(text: String, limit: Int = 500): List<TextChunk> {
    val sentences = java.text.BreakIterator.getSentenceInstance(java.util.Locale.UK)
    sentences.setText(text)
    val ranges = mutableListOf<IntRange>()
    var start = sentences.first()
    var end = sentences.next()
    while (end != java.text.BreakIterator.DONE) {
        val last = ranges.lastOrNull()
        if (last != null && continuesSentence(text.substring(last.first, last.last + 1), text.substring(start, end))) {
            ranges[ranges.lastIndex] = last.first until end
        } else ranges += start until end
        start = end
        end = sentences.next()
    }
    return ranges.flatMap { range ->
        articleChunks(text.substring(range.first, range.last + 1), limit).map {
            it.copy(startUtf16 = it.startUtf16 + range.first, endUtf16 = it.endUtf16 + range.first)
        }
    }
}

private val leadingAbbreviations = setOf(
    "mr", "mrs", "ms", "dr", "st", "no", "mt", "ft", "prof", "gen", "gov", "sen", "rep", "rev", "capt", "lt", "col",
    "sgt", "maj", "fr", "fig", "vol", "ch", "pp", "p", "vs", "e.g", "i.e", "cf", "approx", "viz",
)

internal fun continuesSentence(sentence: String, next: String): Boolean {
    if ('\n' in sentence.substring(sentence.trimEnd().length)) return false  // A paragraph ends the sentence, whatever follows
    val first = next.trimStart().firstOrNull()
    if (first != null && (first.isDigit() || first.isLowerCase())) return true
    val lastWord = sentence.trim().split(' ').last()
    return lastWord.endsWith(".") && lastWord.dropLast(1).lowercase() in leadingAbbreviations
}

/** As on iOS: a few seconds in is the start, and so are an episode's last seconds (its outro). */
fun resumeFrom(savedMs: Long, durationMs: Long?): Long = when {
    savedMs <= 5_000 -> 0
    durationMs != null && durationMs > 0 && savedMs >= durationMs - 10_000 -> 0
    else -> savedMs
}
