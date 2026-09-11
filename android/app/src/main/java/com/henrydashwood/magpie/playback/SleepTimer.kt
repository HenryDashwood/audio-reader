package com.henrydashwood.magpie.playback

/** A monotonic deadline: playback speed, pauses and wall-clock changes don't extend it. */
data class SleepTimerState(val deadlineMs: Long? = null, val remainingMinutes: Int? = null) {
    val running: Boolean get() = deadlineMs != null
}

class SleepTimer(
    private val now: () -> Long,
    private val changed: (SleepTimerState) -> Unit = {},
    private val expired: () -> Unit,
) {
    var state = SleepTimerState()
        private set

    fun start(durationMs: Long): Boolean {
        if (durationMs !in 1..MAX_DURATION_MS) return false
        publish(SleepTimerState(now() + durationMs, minutes(durationMs)))
        return true
    }

    fun cancel() = publish(SleepTimerState())

    fun check() {
        val deadline = state.deadlineMs ?: return
        val remaining = deadline - now()
        if (remaining <= 0) {
            cancel() // Clear first: reentrant player callbacks cannot expire this timer twice.
            expired()
        } else publish(state.copy(remainingMinutes = minutes(remaining)))
    }

    private fun publish(next: SleepTimerState) {
        if (next != state) { state = next; changed(next) }
    }

    private fun minutes(milliseconds: Long) = ((milliseconds + 59_999) / 60_000).toInt()

    companion object {
        val options = listOf(5, 10, 15, 30, 45, 60)
        const val MAX_DURATION_MS = 24 * 60 * 60 * 1000L
    }
}
