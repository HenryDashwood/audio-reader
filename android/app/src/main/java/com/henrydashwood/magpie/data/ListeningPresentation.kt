package com.henrydashwood.magpie.data

import java.net.URI
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

data class ListeningPresentation(val label: String? = null, val started: Boolean = false, val fraction: Float? = null)

/** Article text coordinates never become publisher media seconds. */
fun listeningPresentation(item: LibraryItem, positionMs: Long = item.remotePositionMs,
    durationMs: Long = (item.durationSeconds?.toLong() ?: 0) * 1_000,
    completed: Boolean = item.completed, articleOffset: Int = item.articleBookmark?.offsetUtf16 ?: 0): ListeningPresentation {
    // Labels match iOS (ListeningProgress): "Played" once finished, "N min left" for a started podcast
    // of known length, and nothing otherwise. "Started" still decides Continue listening.
    if (completed) return ListeningPresentation("Played", fraction = 1f)
    if (item.kind == ContentKind.Article) {
        val validOffset = if (item.textLoaded && item.articleBookmark != null && item.articleBookmark.textVersion != item.contentVersion) 0 else articleOffset
        val started = validOffset > 0 || positionMs > 60_000
        return ListeningPresentation(null, started && !item.dismissed,
            if (item.textLoaded && validOffset > 0 && item.text.isNotEmpty()) (validOffset.toFloat() / item.text.length).coerceIn(0f, 1f) else null)
    }
    val position = positionMs.coerceAtLeast(0)
    val started = position > 60_000
    val label = if (!started || durationMs <= 0) null
        else "${maxOf(1, Math.round((durationMs - position).coerceAtLeast(0) / 60_000.0).toInt())} min left"
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

/** A list row's date, as iOS shows it: day and short month, no year ("25 Sep"). */
fun shortPublicationDate(value: String?, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String? {
    if (value == null) return null
    val instant = runCatching { Instant.parse(value) }.getOrElse {
        runCatching { LocalDateTime.parse(value).toInstant(ZoneOffset.UTC) }.getOrNull() ?: return null
    }
    // Java's British English abbreviates September as "Sept"; iOS writes "Sep".
    val pattern = if (locale.country == "US") "MMM d" else "d MMM"
    val months = if (locale.language == "en") Locale.US else locale
    return DateTimeFormatter.ofPattern(pattern, months).format(instant.atZone(zone))
}

/** The reader's byline date, as on iOS: "12 March 2026". */
fun longPublicationDate(value: String?, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String? {
    if (value == null) return null
    val instant = runCatching { Instant.parse(value) }.getOrElse {
        runCatching { LocalDateTime.parse(value).toInstant(ZoneOffset.UTC) }.getOrNull() ?: return null
    }
    return DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(locale).format(instant.atZone(zone))
}
