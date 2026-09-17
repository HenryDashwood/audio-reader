package com.henrydashwood.magpie.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.*
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

@OptIn(ExperimentalCoroutinesApi::class)
class SourceDiscoveryTest {
    private class Repository : SourceRepository, NewsletterRepository {
        var signupCalls = 0
        var signupGate: CompletableDeferred<Unit>? = null
        var signup = NewsletterSignup("unsupported", "Use your address on the website.", "quiet-heron@magpie.example")
        override suspend fun newsletterAddress() = NewsletterAddress("quiet-heron@magpie.example")
        override suspend fun pendingNewsletters() = emptyList<PendingNewsletter>()
        override suspend fun approveNewsletter(item: PendingNewsletter) {}
        override suspend fun blockNewsletter(item: PendingNewsletter) {}
        override suspend fun signUpForNewsletter(url: String): NewsletterSignup {
            signupCalls++; withContext(NonCancellable) { signupGate?.await() }; return signup
        }
        val source = SourceResult("A publication", "https://example.com/feed")
        var queries = mutableListOf<String>()
        var previewed = mutableListOf<String>()
        var discovered: String? = null
        var candidates = listOf(source, source.copy(title = "Comments", url = "https://example.com/comments"))
        var followed = 0
        var failFollow = false
        var consent = false
        var grants = 0
        var webRequests = 0
        var old: CompletableDeferred<Unit>? = null
        var consentGate: CompletableDeferred<Unit>? = null
        override suspend fun findSources(query: String): SourceMatches {
            queries += query
            if (query == "old") withContext(NonCancellable) { old?.await() }
            return SourceMatches(listOf(source.copy(title = query)), emptyList())
        }
        override suspend fun discoverSources(url: String): List<SourceResult> { discovered = url; return candidates }
        override suspend fun previewSource(url: String): SourcePreview {
            previewed += url
            return SourcePreview(LibraryFeed("7", source.title, 3, true, url), listOf("episode"), false)
        }
        override suspend fun followSource(preview: SourcePreview): SourcePreview {
            followed++; if (failFollow) throw IOException()
            return preview.copy(subscribed = true)
        }
        override suspend fun unfollowSource(preview: SourcePreview) = preview.copy(subscribed = false)
        override suspend fun findPublication(query: String): SourceResult? { webRequests++; return source }
        override suspend fun aiConsent(): Boolean { withContext(NonCancellable) { consentGate?.await() }; return consent }
        override suspend fun setAIConsent(granted: Boolean): Boolean { grants++; consent = granted; return consent }
    }
    @Test fun typingDebouncesAndAddressesNeverReachTheDirectory() = runTest {
        val repo = Repository(); val model = SourceDiscovery(backgroundScope, repo); model.open()
        model.edit("fi"); advanceTimeBy(200); model.edit("final"); advanceTimeBy(349); runCurrent()
        assertTrue(repo.queries.isEmpty())
        advanceTimeBy(1); runCurrent(); assertEquals(listOf("final"), repo.queries)
        model.edit("example.com"); advanceTimeBy(400); runCurrent()
        assertEquals(listOf("final"), repo.queries)
        model.submit(); runCurrent()
        assertEquals("https://example.com", repo.discovered)
        assertEquals(2, model.state.value.candidates!!.size)
        assertTrue(repo.previewed.isEmpty()); assertEquals(0, repo.followed)
    }
    @Test fun newsletterSignupIsExplicitAndPreservesManualFallbackWithoutAI() = runTest {
        val repo = Repository().apply { candidates = emptyList() }
        val model = SourceDiscovery(backgroundScope, repo); model.open(); model.edit("publisher.example"); model.submit(); runCurrent()
        assertEquals(0, repo.signupCalls); assertNotNull(model.state.value.error)
        model.signUpByEmail(); runCurrent()
        assertEquals(repo.signup, model.state.value.signup); assertFalse(model.state.value.signup!!.submitted)
        assertEquals(0, repo.grants); assertEquals(0, repo.webRequests)
        model.submit(); runCurrent(); assertNull(model.state.value.signup)
        repo.signup = repo.signup.copy(status = "submitted")
        model.signUpByEmail(); runCurrent(); assertTrue(model.state.value.signup!!.submitted)
    }
    @Test fun accountResetDiscardsALateNewsletterSignupReply() = runTest {
        val repo = Repository().apply { signupGate = CompletableDeferred() }
        val model = SourceDiscovery(backgroundScope, repo); model.open(); model.edit("publisher.example")
        model.signUpByEmail(); runCurrent(); assertTrue(model.state.value.following)
        model.reset(); repo.signupGate!!.complete(Unit); runCurrent()
        assertEquals(DiscoveryState(), model.state.value)
    }
    @Test fun onlyTheChosenFeedIsPreviewedAndFollowingRequiresAnExplicitSuccessfulWrite() = runTest {
        val repo = Repository(); val model = SourceDiscovery(backgroundScope, repo); model.open()
        model.edit("https://example.com"); model.submit(); runCurrent()
        model.select(repo.candidates[1]); runCurrent()
        assertEquals(listOf("https://example.com/comments"), repo.previewed)
        assertFalse(model.state.value.preview!!.subscribed); assertEquals(0, repo.followed)
        repo.failFollow = true; model.follow(); runCurrent()
        assertFalse(model.state.value.preview!!.subscribed); assertNotNull(model.state.value.error)
        repo.failFollow = false; model.follow(); runCurrent()
        assertTrue(model.state.value.preview!!.subscribed)
        model.follow(); runCurrent(); assertEquals(2, repo.followed)
    }
    @Test fun oneFeedOpensAPreviewButNoFeedsShowsAnHonestEmptyResult() = runTest {
        val repo = Repository(); val model = SourceDiscovery(backgroundScope, repo); model.open()
        repo.candidates = listOf(repo.source)
        model.edit("https://example.com"); model.submit(); runCurrent()
        assertNotNull(model.state.value.preview); assertEquals(0, repo.followed)
        model.back(); repo.candidates = emptyList(); model.edit("https://empty.example"); model.submit(); runCurrent()
        assertTrue(model.state.value.candidates!!.isEmpty()); assertNotNull(model.state.value.error)
    }
    @Test fun lateResultsCannotReplaceANewerQueryOrReopenAClosedScreen() = runTest {
        val repo = Repository().apply { old = CompletableDeferred() }; val model = SourceDiscovery(backgroundScope, repo); model.open()
        model.edit("old"); model.submit(); runCurrent()
        model.edit("new"); model.submit(); runCurrent()
        repo.old!!.complete(Unit); runCurrent()
        assertEquals("new", model.state.value.sources.single().title)
        model.reset(); advanceUntilIdle(); assertFalse(model.state.value.showing)
        assertTrue(model.state.value.sources.isEmpty())
    }
    @Test fun webSearchRequiresBothExplicitActionAndConsent() = runTest {
        val repo = Repository(); val model = SourceDiscovery(backgroundScope, repo); model.open()
        model.edit("publication"); model.submit(); runCurrent(); assertEquals(0, repo.webRequests)
        model.searchWeb(); runCurrent(); assertTrue(model.state.value.askingConsent); assertEquals(0, repo.webRequests)
        model.declineAI(); runCurrent(); assertEquals(0, repo.grants); assertEquals(0, repo.webRequests)
        model.searchWeb(); runCurrent(); model.allowAI(); runCurrent()
        assertEquals(1, repo.grants); assertEquals(1, repo.webRequests); assertNotNull(model.state.value.web)
    }
    @Test fun closingDuringConsentCheckCannotStartAnAIRequest() = runTest {
        val repo = Repository().apply { consent = true; consentGate = CompletableDeferred() }
        val model = SourceDiscovery(backgroundScope, repo); model.open(); model.edit("publication"); model.searchWeb(); runCurrent()
        model.close(); repo.consentGate!!.complete(Unit); runCurrent()
        assertEquals(0, repo.webRequests); assertFalse(model.state.value.showing)
    }
    @Test fun invalidAddressNeverStartsDiscovery() = runTest {
        val repo = Repository(); val model = SourceDiscovery(backgroundScope, repo); model.open()
        model.edit("file:///private/secret"); model.submit(); runCurrent()
        assertNull(repo.discovered); assertTrue(repo.queries.isEmpty()); assertNotNull(model.state.value.error)
    }
}
