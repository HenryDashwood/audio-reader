package com.henrydashwood.magpie.data

import com.henrydashwood.magpie.voice.*
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class AccountLibraryTest {
    @Test fun cancelledRefreshKeepsExistingDataAndReleasesLoadingState() = runTest {
        val api = Api()
        val library = AccountLibrary(api, "https://voice.invalid")
        library.changeSession("alice")
        val before = library.state.value
        api.gate = CompletableDeferred()
        val refreshing = launch { library.refresh() }
        runCurrent(); assertTrue(library.state.value.loading)
        refreshing.cancel(); refreshing.join()
        assertFalse(library.state.value.loading)
        assertEquals(before.items, library.state.value.items)
        api.gate!!.complete(Unit)
        library.refresh()
        assertFalse(library.state.value.loading)
    }
    @Test fun cancellingAnOldRefreshCannotClearTheNewAccountsLoadingState() = runTest {
        val api = Api()
        val library = AccountLibrary(api, "https://voice.invalid")
        library.changeSession("alice")
        api.gate = CompletableDeferred()
        val refreshing = launch { library.refresh() }
        runCurrent()
        val changing = launch { library.changeSession("bob") }
        runCurrent()
        refreshing.cancel(); refreshing.join(); runCurrent()
        assertTrue(library.state.value.loading)
        assertTrue(library.state.value.items.isEmpty())
        api.gate!!.complete(Unit); changing.join()
        assertFalse(library.state.value.loading)
    }
    private class Api : LibraryApi, DiscoveryApi, SourceManagementApi, SavedArticleApi, VoiceApi, NewsletterApi {
        var newsletterGate: CompletableDeferred<Unit>? = null
        val newsletterChanges = mutableListOf<Pair<String, Int>>()
        val signupUrls = mutableListOf<String>()
        override suspend fun newsletterAddress(token: String): NewsletterAddress {
            newsletterGate?.await(); return NewsletterAddress("$token@magpie.example")
        }
        override suspend fun pendingNewsletters(token: String) = listOf(PendingNewsletter(30, "Morning", "editor@example.com", 2))
        override suspend fun approveNewsletter(token: String, feedId: Int): LibraryFeed {
            newsletterChanges += token to feedId; newsletterGate?.await()
            val feed = LibraryFeed(feedId.toString(), "Morning", 2, true)
            subscribed[token] = listOf(feed)
            return feed
        }
        override suspend fun blockNewsletter(token: String, feedId: Int) { newsletterChanges += token to feedId }
        override suspend fun signUpForNewsletter(token: String, url: String): NewsletterSignup {
            signupUrls += url; newsletterGate?.await()
            return NewsletterSignup("unsupported", "Sign up on the website.", "$token@magpie.example")
        }
        var voiceGate: CompletableDeferred<Unit>? = null
        val voiceCancellations = mutableListOf<Pair<String, String>>()
        override fun events(token: String, request: VoiceRequest) = flow {
            emit(VoiceEvent.Delta("Working"))
            voiceGate?.await()
            emit(VoiceEvent.Result(VoiceResponse(VoiceAction.Unknown, "Done")))
        }
        override suspend fun cancel(token: String, requestId: String) { voiceCancellations += token to requestId }
        var textGate: CompletableDeferred<Unit>? = null
        var userFailure = false
        var grouped = false
        var unsubscribed = false
        var failRefreshAfterChange = false
        var changeGate: CompletableDeferred<Unit>? = null
        var sourceWrites = 0
        var directoryFailure = false
        var subscriptions = 0
        var discovered: List<SourceResult>? = null
        var discoveryGate: CompletableDeferred<Unit>? = null
        var canonicalUrl: String? = null
        var loseSubscribeReply = false
        val subscribed = mutableMapOf<String, List<LibraryFeed>>()
        var fail = false
        var gate: CompletableDeferred<Unit>? = null
        var oldSearch: CompletableDeferred<Unit>? = null
        var episodeGate: CompletableDeferred<Unit>? = null
        var contentId = 7
        var requestedContent: Int? = null
        var saves = 0
        var filings = 0
        var positions = 0
        var texts = 0
        var latestRows = listOf(RemoteEpisode(1, "Episode", source = "Same title", feedUrl = "https://one.example/feed", audioUrl = "https://one.example/audio.mp3", positionSeconds = 42.5))
        var savedRows = listOf(RemoteEpisode(2, "Saved article", contentId = 7))
        override suspend fun userId(token: String): String { if (userFailure) throw IOException(); return token }
        override suspend fun feeds(token: String): List<LibraryFeed> {
            gate?.await()
            if (fail) throw IOException()
            return if (unsubscribed) emptyList() else listOf(LibraryFeed("1", "Same title", 80, false, "https://one.example/feed"), LibraryFeed("2", "Same title", 0, true)).filterNot { grouped && it.id == "2" } + subscribed[token].orEmpty()
        }
        override suspend fun latest(token: String) = latestRows
        override suspend fun saved(token: String) = savedRows
        override suspend fun episodes(token: String, feedId: String, query: String) = latestRows
        override suspend fun episode(token: String, episodeId: Int): RemoteEpisode {
            val snapshot = (latestRows + savedRows).first { it.id == episodeId }
            episodeGate?.await()
            return snapshot
        }
        override suspend fun search(token: String, query: String): List<RemoteEpisode> {
            if (query == "old") oldSearch?.await()
            return listOf(RemoteEpisode(if (query == "old") 10 else 11, query))
        }
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText {
            texts++; requestedContent = contentId
            val version = this.contentId
            textGate?.await()
            return RemoteText(episodeId, version, "Full saved text", "<p>Full saved text</p>", 3)
        }
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode {
            saves++; if (fail) throw IOException(); return savedRows.first()
        }
        override suspend fun remove(token: String, episodeId: Int) { if (fail) throw IOException() }
        override suspend fun capture(token: String, article: PendingArticle) = save(token, null, article.url)
        override suspend fun retrySaved(token: String, episodeId: Int) = save(token, episodeId, null)
        override suspend fun replaceSaved(token: String, episodeId: Int): RemoteEpisode {
            if (fail) throw IOException()
            contentId++
            savedRows = savedRows.map { if (it.id == episodeId) it.copy(contentId = contentId, completed = false) else it }
            return savedRows.first { it.id == episodeId }
        }
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { if (fail) throw IOException(); filings++ }
        override suspend fun clearLatest(token: String) {}
        override suspend fun subscribe(token: String, url: String): LibraryFeed {
            subscriptions++
            if (subscribed[token].orEmpty().isNotEmpty()) throw com.henrydashwood.magpie.auth.AccountFailure(409, "Already subscribed")
            val feed = LibraryFeed("3", "New feed", 0, true, canonicalUrl ?: url)
            subscribed[token] = listOf(feed)
            if (loseSubscribeReply) { loseSubscribeReply = false; throw IOException("Reply lost") }
            return feed
        }
        override suspend fun directory(token: String, query: String): List<SourceResult> {
            if (directoryFailure) throw IOException()
            return listOf(SourceResult("New feed", "https://new.example/feed"))
        }
        override suspend fun discover(token: String, url: String): List<SourceResult> {
            discoveryGate?.await()
            return discovered ?: listOf(SourceResult("New feed", url))
        }
        override suspend fun preview(token: String, url: String) = RemotePreview(LibraryFeed("3", "New feed", 2, true, url),
            listOf(RemoteEpisode(99, "Preview article"), savedRows.first().copy(contentId = 100)), false)
        override suspend fun webSearch(token: String, query: String): SourceResult? = null
        override suspend fun aiConsent(token: String) = false
        override suspend fun setAIConsent(token: String, granted: Boolean) = granted
        override suspend fun feedSources(token: String, feedId: String) = listOf(FeedSource("1", "Same title", "https://one.example/feed", "rss", primary = true)) +
            if (grouped) listOf(FeedSource("2", "Same title", "https://two.example/feed", "rss")) else emptyList()
        override suspend fun changeSources(token: String, feedId: String, sourceId: String?, change: SourceChange) {
            sourceWrites++; changeGate?.await()
            if (fail) throw IOException()
            grouped = change == SourceChange.Combine
            unsubscribed = change == SourceChange.Unsubscribe
            if (failRefreshAfterChange) fail = true
        }
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) { positions++ }
    }
    @Test fun loadsDistinctFeedsLatestAndSavedIncludingEmptyFeeds() = runTest {
        val api = Api(); val library = AccountLibrary(api, "https://staging.example")
        library.changeSession("alice")
        val state = library.state.value
        assertTrue(state.live)
        assertEquals(listOf("1", "2"), state.feeds.map { it.id })
        assertEquals(2, state.items.size)
        assertEquals(1, state.savedIds.size)
        assertEquals(42_500, state.items.first { it.episodeId == 1 }.remotePositionMs)
        assertFalse(state.items.any { it.id == "walking" })
        assertEquals(0, api.texts) // Full articles are fetched on demand.
    }
    @Test fun replacementInvalidatesTextButFailedReplacementPreservesTheLoadedCopy() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val old = library.content(library.state.value.savedIds.single())
        api.fail = true
        assertTrue(runCatching { library.prepareSaved(old, true, library.state.value.revision) }.isFailure)
        assertEquals(old, library.state.value.items.first { it.id == old.id })
        api.fail = false
        val updated = library.prepareSaved(old, true, library.state.value.revision)
        assertEquals(8, updated.contentId); assertFalse(updated.textLoaded); assertEquals("", updated.text)
        assertEquals(old.id, updated.id)
        assertTrue(runCatching { library.played(old, true) }.isFailure)
        assertEquals(0, api.filings) // An old playback completion must not finish the replacement.
        val loaded = library.content(updated.id); assertEquals(8, loaded.contentId)
        api.latestRows = listOf(api.savedRows.single().copy(contentId = 7))
        library.search("1", "")
        assertEquals(8, library.state.value.items.first { it.id == old.id }.contentId)
    }
    @Test fun lateTextReplyCannotRestoreVersionReplacedWhileLoading() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val old = library.state.value.items.first { it.id in library.state.value.savedIds }
        api.textGate = CompletableDeferred()
        val loading = launch { library.content(old.id) }; runCurrent()
        library.prepareSaved(old, true, library.state.value.revision)
        api.textGate!!.complete(Unit); loading.join()
        assertEquals(8, library.state.value.items.first { it.id == old.id }.contentId)
        assertFalse(library.state.value.items.first { it.id == old.id }.textLoaded)
    }
    @Test fun cachedIdentitySupportsOfflineSameSessionButNeverAnotherTokenOrServer() = runTest {
        val identities = object : AccountIdentityStore {
            val rows = mutableMapOf<String, String>()
            override fun owner(sessionKey: String) = rows[sessionKey]
            override suspend fun remember(sessionKey: String, owner: String) { rows[sessionKey] = owner }
        }
        val api = Api(); val library = AccountLibrary(api, "one", identityStore = identities)
        library.changeSession("alice"); val owner = library.state.value.owner
        api.fail = true; api.userFailure = true
        val offline = AccountLibrary(api, "one", identityStore = identities); offline.changeSession("alice")
        assertEquals(owner, offline.state.value.owner); assertNotNull(offline.state.value.error)
        offline.changeSession("bob"); assertNull(offline.state.value.owner)
        val other = AccountLibrary(api, "two", identityStore = identities); other.changeSession("alice"); assertNull(other.state.value.owner)
    }
    @Test fun failedLoadNeverShowsSamplesAndRefreshFailureKeepsTheCurrentAccount() = runTest {
        val api = Api().apply { fail = true }; val library = AccountLibrary(api, "server")
        library.changeSession("alice")
        assertTrue(library.state.value.live)
        assertTrue(library.state.value.items.isEmpty())
        assertNotNull(library.state.value.error)
        library.search(null, "")
        assertNotNull(library.state.value.error)
        api.fail = false; library.refresh()
        val items = library.state.value.items
        api.fail = true; library.refresh()
        assertEquals(items, library.state.value.items)
        assertNotNull(library.state.value.error)
    }
    @Test fun lateAccountReplyCannotRestoreTheSignedOutLibrary() = runTest {
        val api = Api().apply { gate = CompletableDeferred() }; val library = AccountLibrary(api, "server")
        val loading = launch { library.changeSession("alice") }; runCurrent()
        library.changeSession(null)
        api.gate!!.complete(Unit); loading.join()
        assertFalse(library.state.value.live)
        assertTrue(library.state.value.items.any { it.id == "walking" })
        assertNull(library.state.value.owner)
    }
    @Test fun accountsAndServersUseSeparateItemAndBookmarkNamespaces() = runTest {
        val api = Api(); val library = AccountLibrary(api, "one")
        library.changeSession("alice"); val alice = library.state.value.items.first()
        library.changeSession("bob")
        assertNotEquals(alice.id, library.state.value.items.first().id)
        assertTrue(runCatching { library.save(alice) }.isFailure)
        assertEquals(0, api.saves)
        val other = AccountLibrary(api, "two"); other.changeSession("alice")
        assertNotEquals(alice.id, other.state.value.items.first().id)
    }
    @Test fun articleReadsPinTheSavedVersionAndRejectAnUnexpectedVersion() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val item = library.state.value.items.first { it.episodeId == 2 }
        api.contentId = 9
        assertTrue(runCatching { library.content(item.id) }.isFailure)
        assertFalse(library.state.value.items.first { it.id == item.id }.textLoaded)
        api.contentId = 7
        val loaded = library.content(item.id)
        assertEquals(7, api.requestedContent)
        assertTrue(loaded.textLoaded)
        assertEquals("Full saved text", loaded.text)
        assertNotEquals(item.contentVersion, loaded.contentVersion)
    }
    @Test fun failedWritesDoNotPretendTheLibraryChanged() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val item = library.state.value.items.first { it.episodeId == 2 }
        api.fail = true
        assertTrue(runCatching { library.remove(item) }.isFailure)
        assertTrue(item.id in library.state.value.savedIds)
        assertTrue(runCatching { library.played(item, true) }.isFailure)
        assertFalse(library.state.value.items.first { it.id == item.id }.completed)
    }
    @Test fun clearLatestPreservesSavedItemsAndDoesNotMarkThemPlayed() = runTest {
        val library = AccountLibrary(Api(), "server"); library.changeSession("alice")
        val saved = library.state.value.savedIds
        library.clearLatest()
        assertTrue(library.state.value.latestIds.isEmpty())
        assertEquals(saved, library.state.value.savedIds)
        assertTrue(library.state.value.items.none { it.completed })
    }
    @Test fun olderSearchResultsCannotReplaceTheNewQuery() = runTest {
        val api = Api().apply { oldSearch = CompletableDeferred() }; val library = AccountLibrary(api, "server")
        library.changeSession("alice")
        val old = launch { library.search(null, "old") }; runCurrent()
        library.search(null, "new")
        val results = library.state.value.searchResults
        api.oldSearch!!.complete(Unit); old.join()
        assertEquals(results, library.state.value.searchResults)
        assertTrue(results.single().endsWith(":11"))
    }
    @Test fun renderedArticleSecondsCanNeverReachThePositionEndpoint() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        assertTrue(runCatching { library.reportPodcast(library.state.value.items.first { it.episodeId == 2 }, 20.0, false) }.isFailure)
        assertEquals(0, api.positions)
        library.reportPodcast(library.state.value.items.first { it.episodeId == 1 }, 42.5, false)
        assertEquals(1, api.positions)
    }
    @Test fun previewDoesNotFollowOrReplaceSavedVersionsAndRejectsAnotherSessionsSubscription() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val saved = library.state.value.savedIds
        val latest = library.state.value.latestIds
        val feeds = library.state.value.feeds
        val preview = library.previewSource("https://new.example/feed")
        assertEquals(feeds, library.state.value.feeds); assertEquals(saved, library.state.value.savedIds)
        assertEquals(latest, library.state.value.latestIds); assertEquals(0, api.subscriptions)
        assertEquals(7, library.state.value.items.first { it.id in saved }.contentId)
        assertTrue(library.state.value.items.any { it.episodeId == 99 })
        library.followSource(preview); assertEquals(1, api.subscriptions)
        assertTrue(library.state.value.feeds.any { it.id == "3" })
        library.changeSession("bob")
        assertTrue(runCatching { library.followSource(preview) }.isFailure); assertEquals(1, api.subscriptions)
    }
    @Test fun followingPublicationRequiresAChoiceAndReturnsTheCanonicalSubscription() = runTest {
        val api = Api().apply {
            discovered = listOf(SourceResult("Audio", "https://new.example/audio"), SourceResult("Text", "https://new.example/text"))
            canonicalUrl = "https://canonical.example/feed"
        }
        val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val choice = library.followPublication("https://new.example")
        assertNull(choice.feed); assertEquals(2, choice.choices.size); assertEquals(0, api.subscriptions)
        val followed = library.followPublication("https://new.example", choice.choices.last().id)
        assertEquals("3", followed.feed!!.id); assertEquals(api.canonicalUrl, followed.feed.url)
        assertTrue(followed.choices.isEmpty()); assertFalse(followed.alreadyFollowed)
        assertTrue(library.state.value.feeds.contains(followed.feed)); assertEquals(1, api.subscriptions)
    }
    @Test fun publicationChoicesRejectInvalidMissingChangedAndCrossAccountTargets() = runTest {
        val api = Api().apply { discovered = listOf(SourceResult("One", "https://new.example/one"), SourceResult("Two", "https://new.example/two")) }
        val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val choice = library.followPublication("https://new.example").choices.first()
        assertTrue(runCatching { library.followPublication("file:///secret") }.isFailure)
        assertTrue(runCatching { library.followPublication("https://other.example", choice.id) }.isFailure)
        library.changeSession("bob")
        assertTrue(runCatching { library.followPublication("https://new.example", choice.id) }.isFailure)
        val current = library.followPublication("https://new.example").choices.first()
        api.discovered = api.discovered!!.drop(1)
        assertTrue(runCatching { library.followPublication("https://new.example", current.id) }.isFailure)
        api.discovered = emptyList()
        assertTrue(runCatching { library.followPublication("https://new.example") }.isFailure)
        assertEquals(0, api.subscriptions)
    }
    @Test fun retryAfterLostSubscriptionReplyRecognizesTheCanonicalFeed() = runTest {
        val api = Api().apply { canonicalUrl = "https://canonical.example/feed"; loseSubscribeReply = true }
        val library = AccountLibrary(api, "server"); library.changeSession("alice")
        assertTrue(runCatching { library.followPublication("https://new.example/feed") }.isFailure)
        val retry = library.followPublication("https://new.example/feed")
        assertTrue(retry.alreadyFollowed); assertEquals(api.canonicalUrl, retry.feed!!.url)
        assertEquals(1, api.subscribed["alice"]!!.size); assertEquals(2, api.subscriptions)
    }
    @Test fun followingAnExistingPublicationDoesNotWriteAgain() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val result = library.followPublication("https://one.example/feed")
        assertEquals("1", result.feed!!.id); assertTrue(result.alreadyFollowed); assertEquals(0, api.subscriptions)
    }
    @Test fun accountChangesAndCancellationDuringDiscoveryCannotSubscribe() = runTest {
        val api = Api().apply { discoveryGate = CompletableDeferred() }
        val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val old = launch { library.followPublication("https://new.example/feed") }; runCurrent()
        library.changeSession("bob"); api.discoveryGate!!.complete(Unit); old.join()
        assertTrue(old.isCancelled); assertEquals(0, api.subscriptions)
        api.discoveryGate = CompletableDeferred()
        val cancelled = launch { library.followPublication("https://new.example/feed") }; runCurrent()
        cancelled.cancel(); cancelled.join(); api.discoveryGate!!.complete(Unit)
        assertEquals(0, api.subscriptions)
    }
    @Test fun newsletterRowsBelongToTheirSessionAndApprovalRefreshesFollowing() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val row = library.pendingNewsletters().single()
        assertEquals(library.state.value.revision, row.sessionRevision)
        library.approveNewsletter(row)
        assertTrue(library.state.value.feeds.any { it.id == "30" })
        library.changeSession("bob")
        assertTrue(runCatching { library.blockNewsletter(row) }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
        assertEquals(listOf("alice" to 30), api.newsletterChanges)
    }
    @Test fun lateNewsletterApprovalCannotPublishIntoTheNextAccount() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val row = library.pendingNewsletters().single(); api.newsletterGate = CompletableDeferred()
        val old = launch { library.approveNewsletter(row) }; runCurrent()
        val switching = launch { library.changeSession("bob") }; runCurrent()
        api.newsletterGate!!.complete(Unit); old.join(); switching.join()
        assertTrue(old.isCancelled); assertTrue(library.state.value.feeds.none { it.id == "30" })
        assertEquals(listOf("alice" to 30), api.newsletterChanges)
    }
    @Test fun addressAndSignupResponsesCannotSurviveAnAccountChange() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        assertTrue(runCatching { library.signUpForNewsletter("file:///private") }.isFailure)
        assertTrue(api.signupUrls.isEmpty())
        api.newsletterGate = CompletableDeferred()
        val address = launch { library.newsletterAddress(); fail("Old address escaped") }
        val signup = launch { library.signUpForNewsletter("https://publisher.example"); fail("Old signup escaped") }
        runCurrent(); library.changeSession("bob"); api.newsletterGate!!.complete(Unit)
        address.join(); signup.join()
        assertTrue(address.isCancelled); assertTrue(signup.isCancelled)
    }
    @Test fun directoryFailureKeepsLibrarySearchResultsAndReportsThePartialFailure() = runTest {
        val api = Api().apply { directoryFailure = true }; val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val results = library.findSources("new")
        assertTrue(results.sources.isEmpty()); assertEquals(1, results.itemIds.size); assertNotNull(results.error)
        assertTrue(library.state.value.items.any { it.id in results.itemIds && it.title == "new" })
    }
    @Test fun sourceChangesRefreshFollowingWithoutRemovingSavedItemsOrText() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val revision = library.state.value.revision
        val article = library.content(library.state.value.savedIds.single())
        val before = library.state.value
        val group = library.sourceGroup("1", revision)
        assertEquals(listOf("2"), group.available.map { it.id })
        library.changeSourceGroup("1", "2", SourceChange.Combine, revision)
        assertEquals(listOf("1"), library.state.value.feeds.map { it.id })
        assertTrue(library.state.value.catalogRevision > before.catalogRevision)
        library.changeSourceGroup("1", "2", SourceChange.Separate, revision)
        assertEquals(2, library.state.value.feeds.size)
        library.changeSourceGroup("1", null, SourceChange.Unsubscribe, revision)
        assertTrue(library.state.value.feeds.isEmpty()); assertEquals(before.savedIds, library.state.value.savedIds)
        assertEquals(article, library.state.value.items.first { it.id == article.id })
        assertEquals(42_500, library.state.value.items.first { it.episodeId == 1 }.remotePositionMs)
    }
    @Test fun sourceMutationFailuresAreDistinctFromRefreshFailures() = runTest {
        val api = Api(); val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val before = library.state.value; api.fail = true
        assertTrue(runCatching { library.changeSourceGroup("1", "2", SourceChange.Combine, before.revision) }.isFailure)
        assertEquals(before, library.state.value)
        api.fail = false; api.failRefreshAfterChange = true
        library.changeSourceGroup("1", "2", SourceChange.Combine, before.revision)
        assertFalse(library.state.value.feeds.any { it.id == "2" }); assertNotNull(library.state.value.error)
    }
    @Test fun lateSourceWritesCannotRestoreAnOldAccountOrOldSearchResults() = runTest {
        val api = Api().apply { changeGate = CompletableDeferred() }; val library = AccountLibrary(api, "server"); library.changeSession("alice")
        val revision = library.state.value.revision
        val pending = launch { library.changeSourceGroup("1", "2", SourceChange.Combine, revision) }; runCurrent()
        library.changeSession(null); api.changeGate!!.complete(Unit); pending.join()
        assertFalse(library.state.value.live); assertEquals(0, library.state.value.catalogRevision)
        library.changeSession("bob")
        assertTrue(runCatching { library.changeSourceGroup("1", "2", SourceChange.Combine, revision) }.isFailure)
        assertEquals(1, api.sourceWrites)
        api.oldSearch = CompletableDeferred()
        val search = launch { library.search(null, "old") }; runCurrent()
        library.changeSourceGroup("1", "2", SourceChange.Combine, library.state.value.revision)
        api.oldSearch!!.complete(Unit); search.join()
        assertTrue(library.state.value.searchResults.isEmpty())
    }
    @Test fun voiceRepliesAreRejectedAfterAccountChangeAndCancellationKeepsOriginalAccount() = runTest {
        val api = Api().apply { voiceGate = CompletableDeferred() }
        val library = AccountLibrary(api, "https://voice.invalid")
        library.changeSession("alice")
        val request = VoiceRequest("Do something")
        val operation = library.voiceOperation(request, library.state.value.revision)
        val deltas = mutableListOf<String>()
        var failure: Throwable? = null
        val job = launch { failure = runCatching { operation.response(deltas::add) }.exceptionOrNull() }
        runCurrent(); assertEquals(listOf("Working"), deltas)
        library.changeSession("bob")
        api.voiceGate!!.complete(Unit); job.join()
        assertTrue(failure is kotlinx.coroutines.CancellationException)
        operation.cancel()
        assertEquals(listOf("alice" to request.requestId), api.voiceCancellations)
        assertTrue(runCatching { operation.response() }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
    }
    @Test fun confirmedVoiceEpisodeCanEnterThePlayerCacheWithoutInventingSavedOrLatestMembership() = runTest {
        val library = AccountLibrary(Api(), "https://voice.invalid")
        library.changeSession("alice")
        val revision = library.state.value.revision
        val before = library.state.value
        val row = RemoteEpisode(99, "Requested episode", audioUrl = "https://example.com/audio.mp3")
        val item = library.acceptVoiceEpisode(row, revision)
        assertEquals(99, item.episodeId)
        assertEquals(before.savedIds, library.state.value.savedIds)
        assertEquals(before.latestIds, library.state.value.latestIds)
        library.changeSession("bob")
        assertTrue(runCatching { library.acceptVoiceEpisode(row, revision) }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
        assertFalse(library.state.value.items.any { it.episodeId == 99 })
    }

    @Test fun anOlderRefreshCannotOverwriteAConfirmedVoiceFiling() = runTest {
        val api = Api()
        val library = AccountLibrary(api, "https://voice.invalid")
        library.changeSession("alice")
        val filed = api.latestRows.first().copy(completed = true)
        api.gate = CompletableDeferred()
        val oldRefresh = launch { library.refresh() }
        runCurrent() // Latest has returned the old row; the feeds request is still pending.
        api.latestRows = emptyList()
        val adoption = launch { library.acceptVoiceEpisode(filed, library.state.value.revision) }
        runCurrent()
        api.gate!!.complete(Unit)
        oldRefresh.join(); adoption.join()
        library.refresh()
        assertTrue(library.state.value.items.first { it.episodeId == filed.id }.completed)
        assertTrue(library.state.value.latestIds.isEmpty())
    }

    @Test fun anOlderItemLookupCannotOverwriteAConfirmedFiling() = runTest {
        val api = Api()
        val library = AccountLibrary(api, "https://media.invalid")
        library.changeSession("alice")
        val item = library.state.value.items.first { it.episodeId == 1 }
        val filed = api.latestRows.first().copy(completed = true)
        api.episodeGate = CompletableDeferred()
        val lookup = launch { library.shortcutItem(item.id) }
        runCurrent() // The lookup captured an old, unplayed row and is still pending.
        val receipt = launch { library.acceptVoiceEpisode(filed, library.state.value.revision) }
        runCurrent()
        api.episodeGate!!.complete(Unit)
        lookup.join(); receipt.join()
        assertTrue(library.state.value.items.first { it.id == item.id }.completed)
    }

}
