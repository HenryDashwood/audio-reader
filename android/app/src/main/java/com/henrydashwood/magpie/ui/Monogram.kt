package com.henrydashwood.magpie.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

/**
 * A show's initials on a colour of its own, ported from iOS (`Monogram` in Artwork.swift), so a
 * show without artwork has a face of its own and a written show is not shown a waveform.
 */
object MonogramStyle {
    /** The first letters of the first two words; a leading "The", "A" or "An" is skipped. */
    fun initials(title: String): String {
        var words = title.split(Regex("[\\s\\-–—]+")).map { word -> word.filter { it.isLetterOrDigit() } }.filter { it.isNotEmpty() }
        if (words.size > 1 && words[0].lowercase() in setOf("the", "a", "an")) words = words.drop(1)
        return words.take(2).joinToString("") { it.first().uppercase() }
    }

    /** A stable hue in 0..<1: FNV-1a over the lowercased code points, as on iOS, so both apps agree. */
    fun hue(title: String): Float {
        var hash = 2_166_136_261u
        title.lowercase().codePoints().forEach { point -> hash = (hash xor point.toUInt()) * 16_777_619u }
        return (hash % 360u).toFloat() / 360f
    }

    fun color(title: String): Color = Color.hsv(hue(title) * 360f, 0.42f, 0.58f)
}

@Composable
fun Monogram(title: String, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier.background(MonogramStyle.color(title)), contentAlignment = Alignment.Center) {
        val size = with(LocalDensity.current) { (maxWidth * 0.38f).toSp() }
        Text(MonogramStyle.initials(title), color = Color.White, fontSize = size, fontWeight = FontWeight.SemiBold,
            maxLines = 1, overflow = TextOverflow.Clip)
    }
}
