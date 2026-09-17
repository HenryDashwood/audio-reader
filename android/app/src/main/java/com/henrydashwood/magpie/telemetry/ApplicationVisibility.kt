package com.henrydashwood.magpie.telemetry

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.concurrent.atomic.AtomicInteger

/** Installed before activities start, even if the signed-in library is initialized later. */
class ApplicationVisibility : Application.ActivityLifecycleCallbacks {
    private val resumed = AtomicInteger()
    val visible: Boolean get() = resumed.get() > 0
    override fun onActivityResumed(activity: Activity) { resumed.incrementAndGet() }
    override fun onActivityPaused(activity: Activity) { resumed.updateAndGet { (it - 1).coerceAtLeast(0) } }
    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
