package com.henrydashwood.magpie.data

/** Durable account content only; never persists tokens, transient searches or execution state. */
data class LibrarySnapshot(val owner: String, val items: List<LibraryItem>, val feeds: List<LibraryFeed>,
    val latestIds: List<String>, val savedIds: List<String>, val feedItems: Map<String, List<String>>) {
    fun restore(revision: Int): LibraryState {
        require(items.all { (it.episodeId ?: 0) > 0 && it.id == "$owner:episode:${it.episodeId}" })
        val ids = items.map { it.id }.toSet()
        require(ids.size == items.size && (latestIds + savedIds + feedItems.values.flatten()).all { it in ids })
        return LibraryState(live = true, revision = revision, owner = owner, items = items, feeds = feeds,
            latestIds = latestIds, savedIds = savedIds, feedItems = feedItems, loading = true)
    }
    companion object {
        fun from(state: LibraryState) = LibrarySnapshot(checkNotNull(state.owner), state.items, state.feeds,
            state.latestIds, state.savedIds, state.feedItems)
    }
}

interface LibraryCache {
    suspend fun load(owner: String): LibrarySnapshot?
    suspend fun save(snapshot: LibrarySnapshot)
    suspend fun clear(owner: String)
}
