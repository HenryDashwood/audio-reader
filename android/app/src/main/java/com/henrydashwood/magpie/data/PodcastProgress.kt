package com.henrydashwood.magpie.data

import java.util.UUID

/** Immutable once sent: retry the exact ID/body after a lost acknowledgement. */
data class PodcastProgressReport(val expectedRevision: String, val seconds: Double, val completed: Boolean,
    val requestId: String = UUID.randomUUID().toString()) {
    init {
        require(expectedRevision.matches(Regex("[a-f0-9]{64}")))
        require(seconds.isFinite() && seconds >= 0)
        require(requestId.matches(Regex("[a-zA-Z0-9-]{1,64}")))
    }
}

/** A retry can acknowledge an older write while returning newer device/filing state. */
data class PodcastProgressReceipt(val episode: RemoteEpisode, val acceptedRevision: String) {
    val changedSinceAcceptance: Boolean get() = episode.progressRevision != acceptedRevision
}

interface PodcastProgressApi {
    suspend fun podcastProgress(token: String, episodeId: Int, report: PodcastProgressReport): PodcastProgressReceipt
}
