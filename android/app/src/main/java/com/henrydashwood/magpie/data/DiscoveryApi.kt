package com.henrydashwood.magpie.data

/** Discovery reuses the authenticated backend. Previewing never subscribes. */
data class SourceResult(val title: String, val url: String, val publisher: String? = null,
    val count: Int? = null, val description: String? = null, val format: String? = null,
    val audioCount: Int? = null, val recentTitle: String? = null, val primary: Boolean = false)
data class RemotePreview(val feed: LibraryFeed, val episodes: List<RemoteEpisode>, val subscribed: Boolean)
data class SourcePreview(val feed: LibraryFeed, val itemIds: List<String>, val subscribed: Boolean, val sessionRevision: Int = 0)
data class SourceMatches(val sources: List<SourceResult>, val itemIds: List<String>, val error: String? = null)

interface DiscoveryApi {
    suspend fun directory(token: String, query: String): List<SourceResult>
    suspend fun discover(token: String, url: String): List<SourceResult>
    suspend fun preview(token: String, url: String): RemotePreview
    suspend fun webSearch(token: String, query: String): SourceResult?
    suspend fun aiConsent(token: String): Boolean
    suspend fun setAIConsent(token: String, granted: Boolean): Boolean
}

interface SourceRepository {
    suspend fun findSources(query: String): SourceMatches
    suspend fun discoverSources(url: String): List<SourceResult>
    suspend fun previewSource(url: String): SourcePreview
    suspend fun followSource(preview: SourcePreview): SourcePreview
    suspend fun findPublication(query: String): SourceResult?
    suspend fun aiConsent(): Boolean
    suspend fun setAIConsent(granted: Boolean): Boolean
}
