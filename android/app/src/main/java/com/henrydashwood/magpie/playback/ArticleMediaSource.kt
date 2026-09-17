package com.henrydashwood.magpie.playback

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Timeline
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.FileDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.source.ConcatenatingMediaSource2
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import java.io.IOException
import kotlinx.coroutines.runBlocking

/** A whole article is one Media3 item/window, with independently loaded audio periods. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class ArticleMediaSourceFactory(context: Context, private val renderer: ArticleRenderer,
    private val fallback: MediaSource.Factory = DefaultMediaSourceFactory(context)) : MediaSource.Factory by fallback {
    override fun createMediaSource(mediaItem: MediaItem): MediaSource {
        val uri = mediaItem.localConfiguration?.uri
        if (uri?.scheme != "magpie-article") return fallback.createMediaSource(mediaItem)
        val audio = renderer.find(uri.toString()) ?: throw IllegalStateException("This article is no longer open.")
        val builder = ConcatenatingMediaSource2.Builder().setMediaItem(mediaItem)
        audio.chunks.forEachIndexed { index, chunk ->
            val factory = DataSource.Factory { ArticleDataSource(audio, index) }
            val part = MediaItem.fromUri("$uri/$index")
            builder.add(ProgressiveMediaSource.Factory(factory).createMediaSource(part), chunk.endMs - chunk.startMs)
        }
        return builder.build()
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class ArticleDataSource(private val audio: RenderedArticle, private val index: Int) : DataSource {
    private val file = FileDataSource()
    private var lease: RenderedArticle.Lease? = null
    private var sourceUri: Uri? = null
    override fun addTransferListener(transferListener: TransferListener) = file.addTransferListener(transferListener)
    override fun getUri(): Uri? = sourceUri
    override fun open(dataSpec: DataSpec): Long {
        try {
            // ExoPlayer calls this on its loader thread. Interrupting that loader
            // cancels the coroutine and the pending offline synthesis request.
            val opened = runBlocking { audio.acquire(index) }
            lease = opened; sourceUri = dataSpec.uri
            return file.open(dataSpec.buildUpon().setUri(Uri.fromFile(opened.file)).build())
        } catch (failure: Exception) {
            close()
            throw IOException(failure.message ?: "Could not prepare this article passage.", failure)
        }
    }
    override fun read(buffer: ByteArray, offset: Int, length: Int) = file.read(buffer, offset, length)
    override fun close() {
        try { file.close() } finally { lease?.close(); lease = null; sourceUri = null }
    }
}

/** Use the player's published period offsets, which may still include estimates. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun RenderedArticle.playerChunks(timeline: Timeline): List<TimedChunk> {
    if (timeline.periodCount != textChunks.size) return chunks
    return textChunks.indices.map { playerChunk(timeline, it) }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun RenderedArticle.playerChunk(timeline: Timeline, index: Int): TimedChunk {
    if (timeline.periodCount != textChunks.size) return chunks[index]
    val period = Timeline.Period()
    timeline.getPeriod(index, period)
    val start = period.positionInWindowMs
    val duration = if (period.durationMs == C.TIME_UNSET) duration(index) else period.durationMs
    return TimedChunk(textChunks[index], start, start + duration)
}

/** A long article should not allocate every passage on each half-second clock update. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal fun RenderedArticle.playerBookmark(timeline: Timeline, positionMs: Long, version: String): ArticleBookmark {
    if (timeline.periodCount != textChunks.size) return checkNotNull(bookmarkAt(chunks, positionMs, version))
    val period = Timeline.Period()
    var lower = 0
    var upper = textChunks.lastIndex
    while (lower < upper) {
        val middle = (lower + upper + 1) / 2
        timeline.getPeriod(middle, period)
        if (period.positionInWindowMs <= positionMs) lower = middle else upper = middle - 1
    }
    return ArticleBookmark(version, textChunks[lower].startUtf16)
}
