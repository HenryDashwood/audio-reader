package com.henrydashwood.magpie.ui

import android.animation.ValueAnimator
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.core.graphics.withTranslation
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityManager
import android.view.animation.DecelerateInterpolator
import android.content.Context
import com.henrydashwood.magpie.playback.ArticleReadingPosition
import org.json.JSONObject

/** Native, decorative gutter marker. No JS interface, DOM edits, or accessibility focus changes. */
class ArticleReadingMarker(private val view: ArticleWebView) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    /** The line being read. The drawn marker eases towards it, as on iOS. */
    var rect: RectF? = null
        private set
    private var drawn: RectF? = null
    private var markerAnimator: ValueAnimator? = null
    private var scrollAnimator: ValueAnimator? = null
    private var scrollTarget = 0
    var following = true
        private set
    var onFollowingChanged: (Boolean) -> Unit = {}
    private var position: ArticleReadingPosition? = null
    private var installed = false
    private var generation = 0
    private var pending = false
    private var downY = 0f
    private var touching = false
    private val slop = ViewConfiguration.get(view.context).scaledTouchSlop
    private val accessibility = view.context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
    private val refresh = object : Runnable {
        override fun run() {
            locate()
            if (installed && position != null) view.postDelayed(this, 150)
        }
    }

    fun configure(text: String, done: () -> Unit) {
        val token = generation
        val source = view.context.assets.open("article-marker.js").bufferedReader().use { it.readText() }
        view.evaluateJavascript(source + "\nmagpieReadingMarker.configure(${JSONObject.quote(text)});") {
            if (token == generation) { installed = true; done(); schedule() }
        }
    }

    fun update(value: ArticleReadingPosition?, color: Int, follow: Boolean) {
        paint.color = color
        following = follow
        if (position != value) {
            position = value
            if (value == null) clear()
            schedule()
        }
    }

    private fun schedule() {
        view.removeCallbacks(refresh)
        if (installed && position != null) view.post(refresh)
    }

    fun detachFollowing() {
        stopScrolling()
        if (position != null && following) { following = false; onFollowingChanged(false) }
    }

    fun resume() {
        following = true
        onFollowingChanged(true)
        locate(force = true)
    }

    fun touch(event: MotionEvent) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { downY = event.y; touching = true; stopScrolling() }
            MotionEvent.ACTION_MOVE -> if (kotlin.math.abs(event.y - downY) > slop) detachFollowing()
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> touching = false
        }
    }

    private fun locate(force: Boolean = false) {
        val value = position ?: return
        if (!installed || (pending && !force)) return
        val token = generation
        pending = true
        view.evaluateJavascript("magpieReadingMarker.rectForRange(${value.startUtf16}, ${value.endUtf16 - value.startUtf16})") { result ->
            if (token != generation) return@evaluateJavascript
            pending = false
            if (value != position) return@evaluateJavascript
            val geometry = runCatching { JSONObject(result) }.getOrNull()
            val width = geometry?.optDouble("width") ?: Double.NaN
            val top = geometry?.optDouble("top") ?: Double.NaN
            val height = geometry?.optDouble("height") ?: Double.NaN
            if (!width.isFinite() || width <= 0 || !top.isFinite() || !height.isFinite() || height <= 0) {
                clear(); return@evaluateJavascript
            }
            val scale = view.width / width.toFloat()
            val y = top.toFloat() * scale
            val lineHeight = maxOf(height.toFloat() * scale, 12 * scale)
            moveTo(RectF(6 * scale, y, 10 * scale, y + lineHeight))
            if (force || (following && !touching && !accessibility.isTouchExplorationEnabled)) {
                // Measure against where an in-flight scroll will settle, so each 150 ms
                // refresh does not restart it from a half-way position.
                val scrollY = if (scrollAnimator?.isRunning == true) scrollTarget else view.scrollY
                val visibleTop = y - scrollY
                if (force || visibleTop < view.height * .2f || visibleTop + lineHeight > view.height * .72f) {
                    scrollTo((y - view.height * .34f).toInt().coerceIn(0, view.maximumScrollY()))
                }
            }
        }
    }

    /** "Remove animations" sets the animator scale to zero; honour it like iOS Reduce Motion. */
    private fun moveTo(target: RectF) {
        rect = target
        val from = drawn
        markerAnimator?.cancel()
        if (from == null || from == target || !ValueAnimator.areAnimatorsEnabled()) {
            drawn = RectF(target); view.invalidate(); return
        }
        val start = RectF(from)
        markerAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 200
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                val t = it.animatedFraction
                from.set(start.left + (target.left - start.left) * t, start.top + (target.top - start.top) * t,
                    start.right + (target.right - start.right) * t, start.bottom + (target.bottom - start.bottom) * t)
                view.invalidate()
            }
            start()
        }
    }

    private fun scrollTo(target: Int) {
        if (scrollAnimator?.isRunning == true && scrollTarget == target) return
        stopScrolling()
        if (target == view.scrollY) return
        if (!ValueAnimator.areAnimatorsEnabled()) { view.scrollTo(0, target); return }
        scrollTarget = target
        scrollAnimator = ValueAnimator.ofInt(view.scrollY, target).apply {
            duration = 350
            interpolator = DecelerateInterpolator()
            addUpdateListener { view.scrollTo(0, it.animatedValue as Int) }
            start()
        }
    }

    private fun stopScrolling() {
        scrollAnimator?.cancel()
        scrollAnimator = null
    }

    private fun clear() {
        markerAnimator?.cancel()
        rect = null
        drawn = null
        view.invalidate()
    }

    fun draw(canvas: Canvas) {
        drawn?.let {
            canvas.withTranslation(view.scrollX.toFloat(), 0f) {
                drawRoundRect(it, 2 * view.resources.displayMetrics.density, 2 * view.resources.displayMetrics.density, paint)
            }
        }
    }

    fun reset() {
        generation++
        installed = false
        pending = false
        stopScrolling()
        clear()
        view.removeCallbacks(refresh)
    }
}
