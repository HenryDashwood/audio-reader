package com.henrydashwood.magpie.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper

private val LightColors = lightColorScheme(
    primary = Color(0xFF1558B0), onPrimary = Color.White,
    primaryContainer = Color(0xFFE3EDFF), onPrimaryContainer = Color(0xFF163C70),
    background = Color(0xFFFAFAFC), surface = Color(0xFFFAFAFC),
    surfaceContainer = Color(0xFFF0F1F5), surfaceContainerHigh = Color(0xFFE8EBF1),
    onSurface = Color(0xFF191C22), onSurfaceVariant = Color(0xFF505967),
)
private val DarkColors = darkColorScheme(
    primary = Color(0xFFA8C7FF), onPrimary = Color(0xFF003062),
    primaryContainer = Color(0xFF234577), onPrimaryContainer = Color(0xFFD7E3FF),
    background = Color(0xFF111318), surface = Color(0xFF111318),
    surfaceContainer = Color(0xFF1D2027), surfaceContainerHigh = Color(0xFF292D36),
)

@Composable
fun MagpieTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val view = LocalView.current
    if (!view.isInEditMode) {
        val activity = view.context.activity()
        SideEffect {
            activity?.window?.let { window ->
                WindowCompat.getInsetsController(window, view).apply {
                    isAppearanceLightStatusBars = !darkTheme
                    isAppearanceLightNavigationBars = !darkTheme
                }
            }
        }
    }
    MaterialTheme(colorScheme = if (darkTheme) DarkColors else LightColors, content = content)
}

private tailrec fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> if (baseContext !== this) baseContext.activity() else null
    else -> null
}
