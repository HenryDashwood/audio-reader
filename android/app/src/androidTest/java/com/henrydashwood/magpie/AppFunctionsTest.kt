package com.henrydashwood.magpie

import android.content.Intent
import androidx.appfunctions.*
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.filters.SdkSuppress
import com.henrydashwood.magpie.automation.*
import com.henrydashwood.magpie.data.*
import com.henrydashwood.magpie.playback.PlaybackService
import kotlinx.coroutines.*
import org.junit.*
import org.junit.Assert.*

/** Goes through the platform manager and generated service, including schema serialization. */
@SdkSuppress(minSdkVersion = 36)
class AppFunctionsTest {
    private val app get() = ApplicationProvider.getApplicationContext<MagpieTestApplication>()
    private lateinit var library: AccountLibrary
    private lateinit var api: Api
    private lateinit var manager: AppFunctionManager
    private var scenario: ActivityScenario<MainActivity>? = null
    private var availability: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var findMetadata: androidx.appfunctions.metadata.AppFunctionMetadata
    private fun parameters() = AppFunctionData.Builder(findMetadata.parameters, findMetadata.components)
    private val key = ExecuteAppFunctionResponse.Success.PROPERTY_RETURN_VALUE
    private class Api : LibraryApi {
        val short = RemoteEpisode(1, "Short podcast", source = "Test show", audioUrl = "asset:///welcome.wav", durationSeconds = 120)
        val done = short.copy(id = 2, title = "Finished podcast", completed = true, durationSeconds = 60)
        val unknown = short.copy(id = 3, title = "Unknown length", durationSeconds = null)
        var gate: CompletableDeferred<Unit>? = null
        var queries = 0
        var texts = 0
        var cancelledQueries = 0
        override suspend fun userId(token: String) = "functions-$token"
        override suspend fun feeds(token: String) = listOf(LibraryFeed("10", "Test show", 3, false))
        override suspend fun latest(token: String) = listOf(short, done, unknown)
        override suspend fun saved(token: String) = emptyList<RemoteEpisode>()
        override suspend fun search(token: String, query: String): List<RemoteEpisode> {
            queries++
            try { gate?.await() } catch (failure: CancellationException) { cancelledQueries++; throw failure }
            return listOf(short, done, unknown)
        }
        override suspend fun episodes(token: String, feedId: String, query: String) = search(token, query)
        override suspend fun text(token: String, episodeId: Int, contentId: Int?): RemoteText { texts++; error("Lookup must not request text") }
        override suspend fun save(token: String, episodeId: Int?, url: String?): RemoteEpisode = error("Read only")
        override suspend fun remove(token: String, episodeId: Int) { error("Read only") }
        override suspend fun played(token: String, episodeId: Int, played: Boolean) { error("Read only") }
        override suspend fun clearLatest(token: String) { error("Read only") }
        override suspend fun subscribe(token: String, url: String): LibraryFeed = error("Read only")
        override suspend fun position(token: String, episodeId: Int, seconds: Double, completed: Boolean) {}
    }
    @Before fun prepare() = runBlocking {
        // The original API 36 image has only the legacy metadata indexer. The
        // current generated schema is verified on API 36.1 and later images.
        Assume.assumeTrue("Requires the current AppFunctions metadata indexer (API 36.1 test image)",
            android.os.Build.VERSION.SDK_INT_FULL >= android.os.Build.VERSION_CODES_FULL.BAKLAVA_1)
        api = Api(); library = AccountLibrary(api, "https://functions-fixture.invalid")
        withContext(Dispatchers.Main) { library.changeSession("one"); app.libraryOverride = library }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        manager = checkNotNull(AppFunctionManager.getInstance(app))
        // Wait for PackageManager/AppSearch indexing after installing the APK.
        withTimeout(60_000) {
            while (true) {
                try {
                    for (id in AppFunctionAvailability.functionIds) manager.setAppFunctionEnabled(id, AppFunctionManager.APP_FUNCTION_STATE_ENABLED)
                    break
                } catch (_: IllegalArgumentException) { delay(500) }
            }
        }
        findMetadata = manager.searchAppFunctions(AppFunctionSearchSpec(packageNames = setOf(app.packageName)))
            .first { it.id == MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS }
        availability = scope.launch { AppFunctionAvailability.observe(app, library) }
    }
    @After fun finish() = runBlocking {
        if (!::api.isInitialized) return@runBlocking
        api.gate?.complete(Unit)
        availability?.cancelAndJoin(); scope.cancel()
        scenario?.close()
        app.stopService(Intent(app, PlaybackService::class.java))
        withContext(Dispatchers.Main) { app.libraryOverride = null }
    }
    private suspend fun execute(id: String, data: AppFunctionData = AppFunctionData.EMPTY) = withTimeout(15_000) {
        manager.executeAppFunction(ExecuteAppFunctionRequest(app.packageName, id, data))
    }
    private suspend fun success(id: String, data: AppFunctionData = AppFunctionData.EMPTY): AppFunctionData {
        val result = execute(id, data)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Success)
        return (result as ExecuteAppFunctionResponse.Success).returnValue
    }
    @Test fun listAndFindUseScopedIdsAndPreserveTheDisplayedSearch() = runBlocking {
        withContext(Dispatchers.Main) { library.search(null, "existing") }
        val displayed = library.state.value.searchResults
        val shows = success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!
        assertEquals(1, shows.size)
        val showId = shows.single().getString("id")!!
        assertTrue(showId.startsWith(library.state.value.owner!!))
        val found = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters()
            .setString("showId", showId).setBoolean("unheardOnly", true).setDouble("maximumMinutes", 3.0).build())
            .getAppFunctionDataList(key)!!
        assertEquals(listOf("Short podcast"), found.map { it.getString("title") })
        assertEquals(120, found.single().getInt("durationSeconds"))
        assertEquals(displayed, library.state.value.searchResults)
        assertEquals(0, api.texts)
    }
    @Test fun defaultSearchIncludesUnknownDurationAndLimitsResults() = runBlocking {
        val found = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS).getAppFunctionDataList(key)!!
        assertEquals(3, found.size); assertNull(found.last().getIntOrNull("durationSeconds"))
        val limited = success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS,
            parameters().setInt("maxResults", 1).build()).getAppFunctionDataList(key)!!
        assertEquals(1, limited.size)
    }
    @Test fun invalidArgumentsDoNotQueryTheLibrary() = runBlocking {
        for (data in listOf(parameters().setInt("maxResults", 0).build(),
            parameters().setDouble("maximumMinutes", -1.0).build(),
            parameters().setString("query", "x".repeat(201)).build())) {
            val result = execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, data)
            assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionInvalidArgumentException)
        }
        assertEquals(0, api.queries)
    }
    @Test fun anOldAccountsShowCannotBeUsedAfterSwitchingAccounts() = runBlocking {
        val old = success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!.single().getString("id")!!
        withContext(Dispatchers.Main) { library.changeSession("two") }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("showId", old).build())
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionElementNotFoundException)
        assertEquals(0, api.queries)
    }
    @Test fun signedOutInvocationsCannotReadTheSampleLibraryEvenIfStillEnabled() = runBlocking {
        availability?.cancelAndJoin()
        withContext(Dispatchers.Main) { library.changeSession(null) }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionPermissionRequiredException)
    }
    @Test fun accountChangeDiscardsAnInFlightLookup() = runBlocking {
        availability?.cancelAndJoin()
        api.gate = CompletableDeferred()
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("query", "podcast").build()) }
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.queries } == 0) delay(20) }
        withContext(Dispatchers.Main) { library.changeSession(null); api.gate!!.complete(Unit) }
        val result = pending.await()
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionCancelledException)
        assertFalse(library.state.value.live)
        assertTrue(library.state.value.items.none { it.title == "Short podcast" })
    }
    @Test fun callerCancellationStopsTheLookupAndTheNextCallStillWorks() = runBlocking {
        api.gate = CompletableDeferred()
        val pending = async { execute(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS, parameters().setString("query", "podcast").build()) }
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.queries } == 0) delay(20) }
        pending.cancelAndJoin()
        withTimeout(5_000) { while (withContext(Dispatchers.Main) { api.cancelledQueries } == 0) delay(20) }
        withContext(Dispatchers.Main) { api.gate = null }
        assertEquals(3, success(MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS).getAppFunctionDataList(key)!!.size)
    }
    @Test fun discoveryDisablesAfterSignOutAndEnablesAfterSignIn() = runBlocking {
        val names = AppFunctionAvailability.functionIds.map { androidx.appfunctions.metadata.AppFunctionName(app.packageName, it) }
        withContext(Dispatchers.Main) { library.changeSession(null) }
        withTimeout(5_000) { while (manager.getAppFunctionStates(names).any { it.isEnabled }) delay(20) }
        val result = execute(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS)
        assertTrue(result.toString(), result is ExecuteAppFunctionResponse.Error && result.error is AppFunctionDisabledException)
        withContext(Dispatchers.Main) { library.changeSession("two") }
        withTimeout(5_000) { while (manager.getAppFunctionStates(names).any { !it.isEnabled }) delay(20) }
        assertEquals(1, success(MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS).getAppFunctionDataList(key)!!.size)
    }
    @Test fun listeningStatusDoesNotStartPlayback() = runBlocking {
        val result = success(MagpieAppFunctions.FUNCTION_ID_GET_LISTENING_STATUS).getAppFunctionData(key)!!
        assertFalse(result.getBoolean("playing")); assertNull(result.getAppFunctionData("item"))
        assertEquals(0.0, result.getDouble("positionSeconds"), 0.01)
    }
}
