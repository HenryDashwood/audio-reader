package com.henrydashwood.magpie.playback

import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import com.henrydashwood.magpie.data.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first

/** Read-only assistant catalogue. Scoped folder/item IDs cannot cross accounts. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class MediaLibraryCatalog(private val library: AccountLibrary, private val store: PreviewStore) {
    fun root() = folder(ROOT, "Magpie", "Podcasts and articles")
    private fun prefix(state: LibraryState) = "library:${state.owner ?: "sample"}:"
    private suspend fun ready(): LibraryState {
        val initial = library.state.value
        val state = library.state.first { !it.loading }
        if (state.revision != initial.revision) throw CancellationException("Account changed")
        check(!state.live || state.owner != null) { "Open Magpie and sign in to load your library." }
        return state
    }
    private fun check(state: LibraryState) {
        if (library.state.value.revision != state.revision || library.state.value.owner != state.owner)
            throw CancellationException("Account changed")
    }
    fun folders(state: LibraryState) = listOf(
        folder(prefix(state) + "latest", if (state.live) "Latest" else "Latest samples"),
        folder(prefix(state) + "saved", if (state.live) "Saved" else "Saved samples"),
        folder(prefix(state) + "following", if (state.live) "Following" else "Sample sources"),
    )
    private fun source(state: LibraryState, feed: LibraryFeed) = folder(prefix(state) + "feed:" + feed.id, feed.title)
    fun containerIds(state: LibraryState) = (folders(state).map { it.mediaId } + state.feeds.map { source(state, it).mediaId }).toSet()
    private fun path(id: String, state: LibraryState): String {
        require(id.startsWith(prefix(state))) { "This library belongs to another account. Browse Magpie again." }
        return id.removePrefix(prefix(state))
    }
    suspend fun item(id: String): MediaItem {
        if (id == ROOT) return root()
        val state = ready()
        if (id.startsWith("library:")) {
            folders(state).firstOrNull { it.mediaId == id }?.let { return it }
            val path = path(id, state)
            require(path.startsWith("feed:")) { "This library folder is unavailable." }
            return source(state, state.feeds.firstOrNull { it.id == path.removePrefix("feed:") }
                ?: throw IllegalArgumentException("That show is no longer followed."))
        }
        val item = library.shortcutItem(id); check(state)
        return media(item)
    }
    suspend fun children(id: String, page: Int, size: Int): List<MediaItem> {
        validatePage(page, size)
        val state = ready()
        if (id == ROOT) return paginate(folders(state), page, size)
        val path = path(id, state)
        if (path == "following") return paginate(state.feeds.map { source(state, it) }, page, size)
        val items = when {
            path == "latest" -> library.shortcutItems().filter { !it.completed && !it.dismissed &&
                (state.live || it.id !in store.finished && it.id !in store.dismissedFromLatest) }
            path == "saved" -> library.shortcutItems(savedOnly = true).filter { state.live || it.id in store.saved }
            path.startsWith("feed:") -> library.shortcutItems(path.removePrefix("feed:"))
            else -> throw IllegalArgumentException("This library folder is unavailable.")
        }
        check(state)
        return paginate(items.map(::media), page, size)
    }
    suspend fun search(query: String): List<LibraryItem> {
        val text = query.trim()
        require(text.isNotEmpty() && text.length <= 200) { "Choose a search between one and 200 characters." }
        val state = ready()
        val result = library.shortcutItems(query = text); check(state)
        return result
    }
    suspend fun resolve(request: MediaItem): LibraryItem {
        require(request.localConfiguration == null && request.requestMetadata.mediaUri == null) { "Choose an item from your Magpie library." }
        val state = ready()
        val query = request.requestMetadata.searchQuery
        val item = if (query != null) {
            require(query.length <= 200) { "Choose a shorter search." }
            val text = query.trim()
            val feeds = state.feeds.filter { text.isNotEmpty() && it.title.equals(text, ignoreCase = true) }
            require(feeds.size <= 1) { "Several shows match. Open Magpie to choose one." }
            val matches = library.shortcutItems(feeds.singleOrNull()?.id, if (feeds.isEmpty()) text else "")
                .filter { it.captureError == null }
            matches.firstOrNull { text.isNotEmpty() && it.title.equals(text, ignoreCase = true) }
                ?: matches.firstOrNull { !it.completed && !it.dismissed &&
                    (state.live || it.id !in store.finished && it.id !in store.dismissedFromLatest) }
                ?: throw IllegalArgumentException("There is nothing matching that request to listen to.")
        } else {
            require(request.mediaId.isNotBlank() && request.mediaId.length <= 256) { "Choose an item from your Magpie library." }
            library.shortcutItem(request.mediaId)
        }
        check(state)
        require(item.captureError == null) { "Open Magpie to retry this article capture." }
        val loaded = if (item.textLoaded) item else library.content(item.id)
        check(state)
        return loaded
    }
    companion object {
        const val ROOT = "magpie-library"
        // Legacy MediaBrowser uses Int.MAX_VALUE to request an unpaged folder.
        // Pagination slices the bounded repository result and never allocates by size.
        fun validatePage(page: Int, size: Int) { require(page >= 0 && size > 0) { "Choose a valid library page." } }
        fun <T> paginate(items: List<T>, page: Int, size: Int): List<T> {
            validatePage(page, size)
            val start = page.toLong() * size
            return if (start >= items.size) emptyList() else items.subList(start.toInt(), minOf(items.size.toLong(), start + size).toInt())
        }
        fun media(item: LibraryItem): MediaItem = MediaItem.Builder().setMediaId(item.id).setMediaMetadata(
            MediaMetadata.Builder().setTitle(item.title).setArtist(item.source)
                .setDescription(item.description.take(500)).setIsBrowsable(false).setIsPlayable(item.captureError == null)
                .setDurationMs(item.durationSeconds?.toLong()?.times(1000)).build(),
        ).build()
        private fun folder(id: String, title: String, description: String? = null) = MediaItem.Builder().setMediaId(id)
            .setMediaMetadata(MediaMetadata.Builder().setTitle(title).setDescription(description)
                .setIsBrowsable(true).setIsPlayable(false).build()).build()
    }
}
