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

/** Keep a sentence boundary even when an engine supplies no per-word audio markers. */
fun articleNarrationChunks(text: String, limit: Int = 500): List<TextChunk> {
    val sentences = java.text.BreakIterator.getSentenceInstance(java.util.Locale.UK)
    sentences.setText(text)
    val result = mutableListOf<TextChunk>()
    var start = sentences.first()
    var end = sentences.next()
    while (end != java.text.BreakIterator.DONE) {
        result += articleChunks(text.substring(start, end), limit).map {
            it.copy(startUtf16 = it.startUtf16 + start, endUtf16 = it.endUtf16 + start)
        }
        start = end
        end = sentences.next()
    }
    return result
}
