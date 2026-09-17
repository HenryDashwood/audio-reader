package com.henrydashwood.magpie.data

import java.net.URI
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.ceil

data class ListeningPresentation(val label: String? = null, val started: Boolean = false, val fraction: Float? = null)

/** Article text coordinates never become publisher media seconds. */
fun listeningPresentation(item: LibraryItem, positionMs: Long = item.remotePositionMs,
    durationMs: Long = (item.durationSeconds?.toLong() ?: 0) * 1_000,
    completed: Boolean = item.completed, articleOffset: Int = item.articleBookmark?.offsetUtf16 ?: 0): ListeningPresentation {
    if (completed) return ListeningPresentation(if (item.kind == ContentKind.Article) "Read" else "Played", fraction = 1f)
    if (item.kind == ContentKind.Article) {
        val validOffset = if (item.textLoaded && item.articleBookmark != null && item.articleBookmark.textVersion != item.contentVersion) 0 else articleOffset
        val started = validOffset > 0 || positionMs > 60_000
        return ListeningPresentation(if (started) "In progress" else null, started && !item.dismissed,
            if (item.textLoaded && validOffset > 0 && item.text.isNotEmpty()) (validOffset.toFloat() / item.text.length).coerceIn(0f, 1f) else null)
    }
    val position = positionMs.coerceAtLeast(0)
    val started = position > 60_000
    val label = if (!started) null else if (durationMs > 0) {
        val left = (durationMs - position).coerceAtLeast(0)
        if (left < 60_000) "Less than a minute left" else "${ceil(left / 60_000.0).toInt()} min left"
    } else "In progress"
    return ListeningPresentation(label, started && !item.dismissed,
        if (durationMs > 0 && position > 0) (position.toDouble() / durationMs).coerceIn(0.0, 1.0).toFloat() else null)
}

fun publicationDate(value: String?, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String? {
    if (value == null) return null
    val instant = runCatching { Instant.parse(value) }.getOrElse {
        // Older server snapshots can contain UTC dates without an explicit offset.
        runCatching { LocalDateTime.parse(value).toInstant(ZoneOffset.UTC) }.getOrNull() ?: return null
    }
    return DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale).format(instant.atZone(zone))
}

fun publisherArtwork(value: String?): String? = value?.takeIf { runCatching {
    val uri = URI(it)
    uri.scheme == "https" && uri.host != null && uri.userInfo == null
}.getOrDefault(false) }
