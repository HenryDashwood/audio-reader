package com.henrydashwood.magpie.data

/** Account address with a readable alternative for offline speech and TalkBack. */
data class NewsletterAddress(val address: String) {
    private val local get() = address.substringBefore('@')
    private val domain get() = address.substringAfter('@').replace(".", " dot ")
    val spelledOut get() = local.map { when (it) {
        '-' -> "hyphen"
        '.' -> "dot"
        '_' -> "underscore"
        else -> it.toString()
    } }.joinToString(", ") + ", at $domain"
    val spoken: String get() {
        val words = local.split('-')
        return if (words.size > 1 && words.all { it.isNotEmpty() && it.all(Char::isLetter) })
            words.joinToString(", ") + ", with hyphens between the words, at $domain"
        else spelledOut
    }
}

data class PendingNewsletter(val id: Int, val title: String, val senderAddress: String,
    val messageCount: Int, val latestTitle: String? = null, val latestAt: String? = null,
    val sessionRevision: Int = -1) {
    val messageCountLabel get() = "$messageCount ${if (messageCount == 1) "message" else "messages"}"
}

data class NewsletterSignup(val status: String, val spokenResponse: String, val address: String? = null,
    val publication: String? = null, val platform: String? = null, val reason: String? = null) {
    val submitted get() = status == "submitted"
}

interface NewsletterApi {
    suspend fun newsletterAddress(token: String): NewsletterAddress
    suspend fun pendingNewsletters(token: String): List<PendingNewsletter>
    suspend fun approveNewsletter(token: String, feedId: Int): LibraryFeed
    suspend fun blockNewsletter(token: String, feedId: Int)
    suspend fun signUpForNewsletter(token: String, url: String): NewsletterSignup
}

interface NewsletterRepository {
    suspend fun newsletterAddress(): NewsletterAddress
    suspend fun pendingNewsletters(): List<PendingNewsletter>
    suspend fun approveNewsletter(item: PendingNewsletter)
    suspend fun blockNewsletter(item: PendingNewsletter)
    suspend fun signUpForNewsletter(url: String): NewsletterSignup
}
