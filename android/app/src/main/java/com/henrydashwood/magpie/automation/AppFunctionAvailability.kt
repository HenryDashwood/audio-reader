package com.henrydashwood.magpie.automation

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunctionManager
import com.henrydashwood.magpie.data.AccountLibrary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

/** Discovery is a convenience; every invocation independently validates the current account. */
object AppFunctionAvailability {
    suspend fun observe(context: Context, library: AccountLibrary) {
        if (Build.VERSION.SDK_INT < 36) return
        observeSupported(context, library)
    }

    @RequiresApi(36)
    private suspend fun observeSupported(context: Context, library: AccountLibrary) {
        val manager = AppFunctionManager.getInstance(context) ?: return
        library.state.map { it.live && it.owner != null }.distinctUntilChanged().collectLatest { enabled ->
            // Package indexing can lag an install. Retry without blocking the account or player.
            for (attempt in 0..3) {
                try {
                    for (id in functionIds) manager.setAppFunctionEnabled(id,
                        if (enabled || id in localFunctionIds) AppFunctionManager.APP_FUNCTION_STATE_ENABLED else AppFunctionManager.APP_FUNCTION_STATE_DISABLED)
                    break
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (_: Exception) {
                    if (attempt == 3) Log.w("MagpieAppFunctions", "Could not update assistant action availability")
                    else delay((attempt + 1) * 1_000L)
                }
            }
        }
    }

    @get:RequiresApi(36)
    val localFunctionIds get() = setOf(MagpieAppFunctions.FUNCTION_ID_OPEN_MAGPIE_DESTINATION, MagpieAppFunctions.FUNCTION_ID_RUN_MAGPIE_REQUEST)

    @get:RequiresApi(36)
    val functionIds get() = listOf(
        MagpieAppFunctions.FUNCTION_ID_FOLLOW_PUBLICATION_URL,
        MagpieAppFunctions.FUNCTION_ID_RUN_MAGPIE_REQUEST,
        MagpieAppFunctions.FUNCTION_ID_LIST_SHOWS,
        MagpieAppFunctions.FUNCTION_ID_FIND_ITEMS,
        MagpieAppFunctions.FUNCTION_ID_GET_LISTENING_STATUS,
        MagpieAppFunctions.FUNCTION_ID_PAUSE_LISTENING,
        MagpieAppFunctions.FUNCTION_ID_SKIP_LISTENING,
        MagpieAppFunctions.FUNCTION_ID_SEEK_LISTENING,
        MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SPEED,
        MagpieAppFunctions.FUNCTION_ID_UNDO_LISTENING_SPEED,
        MagpieAppFunctions.FUNCTION_ID_SET_LISTENING_SLEEP_TIMER,
        MagpieAppFunctions.FUNCTION_ID_CANCEL_LISTENING_SLEEP_TIMER,
        MagpieAppFunctions.FUNCTION_ID_PLAY_LISTENING_ITEM,
        MagpieAppFunctions.FUNCTION_ID_CONTINUE_LISTENING,
        MagpieAppFunctions.FUNCTION_ID_PLAY_LATEST_LISTENING_ITEM,
        MagpieAppFunctions.FUNCTION_ID_FILE_LISTENING_ITEM,
        MagpieAppFunctions.FUNCTION_ID_UNDO_LAST_LIBRARY_ACTION,
        MagpieAppFunctions.FUNCTION_ID_OPEN_MAGPIE_DESTINATION,
        MagpieAppFunctions.FUNCTION_ID_OPEN_LISTENING_ITEM,
        MagpieAppFunctions.FUNCTION_ID_OPEN_FOLLOWED_SHOW,
    )
}
