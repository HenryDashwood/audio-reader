package com.henrydashwood.magpie.playback

import android.content.Context
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import com.google.android.gms.tasks.Task
import com.google.android.play.core.assetpacks.AssetPackException
import com.google.android.play.core.assetpacks.AssetPackManagerFactory
import com.google.android.play.core.assetpacks.AssetPackState
import com.google.android.play.core.assetpacks.AssetPackStateUpdateListener
import com.google.android.play.core.assetpacks.model.AssetPackErrorCode
import com.google.android.play.core.assetpacks.model.AssetPackStatus
import com.henrydashwood.magpie.data.PreviewStore
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine

/** The one download of the natural voice, for Settings to show and drive, through Play's on-demand asset pack.
 *  Process-wide, so leaving and reopening Settings shows the same transfer rather than starting another. */
class NaturalVoiceDownload private constructor(private val context: Context) {
    sealed interface State {
        data object Checking : State
        data class NotInstalled(val bytes: Long?) : State
        /** No pack to fetch: an install from Android Studio rather than Play, or an unsupported phone. */
        data class Unavailable(val message: String) : State
        data object Waiting : State
        data class Downloading(val fraction: Float) : State
        /** Play asks before a large download over mobile data. */
        data object NeedsConfirmation : State
        data object WaitingForWifi : State
        data class Installed(val voices: List<NaturalVoice>) : State
        data class Failed(val message: String) : State
    }

    private val manager = AssetPackManagerFactory.getInstance(context)
    private val mutableState = MutableStateFlow<State>(State.Checking)
    val state = mutableState.asStateFlow()
    private var active = false

    private val listener = AssetPackStateUpdateListener { update -> if (update.name() == NaturalVoiceStore.PACK) apply(update) }
    init { manager.registerListener(listener) }

    suspend fun refresh() {
        if (active) return  // Settings reopened mid-download: keep showing the transfer
        installed()?.let { mutableState.value = it; return }
        if (!NaturalVoiceStore.isSupported) {
            mutableState.value = State.Unavailable("The natural voice needs a 64-bit phone.")
            return
        }
        mutableState.value = try {
            val pack = manager.getPackStates(listOf(NaturalVoiceStore.PACK)).await().packStates()[NaturalVoiceStore.PACK]
            if (pack?.status() == AssetPackStatus.COMPLETED) usable() else State.NotInstalled(pack?.totalBytesToDownload()?.takeIf { it > 0 })
        } catch (error: Exception) { failure(error) }
    }

    suspend fun download() {
        if (active) return
        active = true
        mutableState.value = State.Waiting
        try {
            manager.fetch(listOf(NaturalVoiceStore.PACK)).await()
        } catch (error: Exception) {
            active = false
            mutableState.value = failure(error)
        }
    }

    fun cancel() { manager.cancel(listOf(NaturalVoiceStore.PACK)) }

    /** Play's own dialog for a download over mobile data. */
    fun confirm(launcher: ActivityResultLauncher<IntentSenderRequest>) { manager.showConfirmationDialog(launcher) }

    suspend fun remove() {
        if (active) return
        PreviewStore(context).naturalVoice = null
        NaturalVoiceEngines.release()
        mutableState.value = try {
            manager.removePack(NaturalVoiceStore.PACK).await()
            installed() ?: State.NotInstalled(null)
        } catch (error: Exception) {
            Log.w(TAG, "Couldn't remove the natural voice", error)
            State.Failed("Magpie couldn't remove the natural voice. Restart Magpie and try again.")
        }
    }

    private fun apply(update: AssetPackState) {
        when (update.status()) {
            AssetPackStatus.PENDING -> mutableState.value = State.Waiting
            AssetPackStatus.DOWNLOADING -> mutableState.value = State.Downloading(
                if (update.totalBytesToDownload() > 0) 0.9f * update.bytesDownloaded() / update.totalBytesToDownload() else 0f)
            // Play unpacks the files after downloading them: the last tenth
            AssetPackStatus.TRANSFERRING -> mutableState.value = State.Downloading(0.9f + update.transferProgressPercentage() / 1000f)
            AssetPackStatus.REQUIRES_USER_CONFIRMATION -> mutableState.value = State.NeedsConfirmation
            AssetPackStatus.WAITING_FOR_WIFI -> mutableState.value = State.WaitingForWifi
            AssetPackStatus.COMPLETED -> { active = false; mutableState.value = usable() }
            AssetPackStatus.CANCELED -> { active = false; mutableState.value = State.NotInstalled(update.totalBytesToDownload().takeIf { it > 0 }) }
            AssetPackStatus.FAILED -> { active = false; mutableState.value = State.Failed(message(update.errorCode())) }
            else -> Unit
        }
    }

    private fun installed() = NaturalVoiceStore.folder(context)?.let { State.Installed(NaturalVoiceStore.voices(it)) }

    private fun usable(): State = installed() ?: run {
        Log.e(TAG, "Downloaded voice unusable at ${manager.getPackLocation(NaturalVoiceStore.PACK)?.assetsPath()}")
        manager.removePack(NaturalVoiceStore.PACK)  // So Try Again fetches a fresh copy rather than these files
        State.Failed("Magpie couldn't open the natural voice download. Please download it again.")
    }

    private fun failure(error: Exception): State {
        Log.w(TAG, "Natural voice download", error)
        val code = (error as? AssetPackException)?.errorCode ?: AssetPackErrorCode.INTERNAL_ERROR
        return if (code in unavailable) State.Unavailable("The natural voice isn't available for this version of Magpie yet.")
        else State.Failed(message(code))
    }

    companion object {
        private const val TAG = "NaturalVoice"
        // It holds only the application context, which lives as long as the process.
        @android.annotation.SuppressLint("StaticFieldLeak")
        @Volatile private var shared: NaturalVoiceDownload? = null
        fun get(context: Context) = shared ?: synchronized(this) {
            shared ?: NaturalVoiceDownload(context.applicationContext).also { shared = it }
        }

        private val unavailable = setOf(AssetPackErrorCode.APP_UNAVAILABLE, AssetPackErrorCode.PACK_UNAVAILABLE,
            AssetPackErrorCode.INVALID_REQUEST, AssetPackErrorCode.API_NOT_AVAILABLE, AssetPackErrorCode.UNRECOGNIZED_INSTALLATION,
            AssetPackErrorCode.APP_NOT_OWNED)

        /** What to tell her: what went wrong, in terms of what she can do about it. */
        fun message(code: Int): String = when (code) {
            AssetPackErrorCode.INSUFFICIENT_STORAGE -> "There isn't enough free storage for the natural voice. Free some storage and try again."
            AssetPackErrorCode.NETWORK_ERROR -> "Magpie couldn't download the natural voice. Check your internet connection and try again."
            in unavailable -> "The natural voice isn't available for this version of Magpie yet."
            else -> "Magpie couldn't download the natural voice. Please try again."
        }
    }
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener { task ->
        val error = task.exception
        if (error != null) continuation.resumeWithException(error) else continuation.resume(task.result)
    }
}
