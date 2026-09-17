package com.henrydashwood.magpie.data

import java.util.UUID

/** Coordinates in the exact server text, independent of the rendered audio timeline. */
data class RemoteArticleBookmark(val textVersion: String, val offsetUtf16: Int) {
    init { require(textVersion.matches(Regex("[a-f0-9]{64}")) && offsetUtf16 >= 0) }
}
data class ArticleProgressState(val textVersion: String, val contentId: Int?, val revision: String,
    val bookmark: RemoteArticleBookmark?) {
    init {
        require(textVersion.matches(Regex("[a-f0-9]{64}")) && revision.matches(Regex("[a-f0-9]{64}")))
        require(contentId == null || contentId > 0)
        require(bookmark == null || bookmark.textVersion == textVersion)
    }
}
data class ArticleProgressReport(val expectedRevision: String, val textVersion: String, val contentId: Int?,
    val offsetUtf16: Int, val completed: Boolean, val requestId: String = UUID.randomUUID().toString()) {
    init {
        require(expectedRevision.matches(Regex("[a-f0-9]{64}")) && textVersion.matches(Regex("[a-f0-9]{64}")))
        require(contentId == null || contentId > 0)
        require(offsetUtf16 >= 0 && requestId.matches(Regex("[a-zA-Z0-9-]{1,64}")))
    }
}
data class ArticleProgressReceipt(val episode: RemoteEpisode, val progress: ArticleProgressState, val acceptedRevision: String) {
    val changedSinceAcceptance: Boolean get() = progress.revision != acceptedRevision
}
interface ArticleProgressApi {
    suspend fun articleProgress(token: String, episodeId: Int, report: ArticleProgressReport): ArticleProgressReceipt
}
