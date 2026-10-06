package com.henrydashwood.magpie.ui

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.OpenInNew
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.ContentCopy
import androidx.compose.material.icons.rounded.Share
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties

internal data class ReaderLink(val uri: Uri, val point: IntOffset)

/** A focusable context menu at the held link; Android handles Back and outside taps. */
@Composable
internal fun ReaderLinkMenu(link: ReaderLink, onDismiss: () -> Unit, onSave: () -> Unit,
    onOpen: () -> Unit, onError: (String) -> Unit) {
    val context = LocalContext.current
    val density = LocalDensity.current
    val window = LocalWindowInfo.current.containerSize
    val margin = with(density) { 16.dp.roundToPx() }
    val gap = with(density) { 8.dp.roundToPx() }
    val position = remember(link.point, margin, gap) {
        object : PopupPositionProvider {
            override fun calculatePosition(anchorBounds: IntRect, windowSize: IntSize,
                layoutDirection: LayoutDirection, popupContentSize: IntSize): IntOffset {
                val x = if (layoutDirection == LayoutDirection.Ltr) link.point.x else link.point.x - popupContentSize.width
                val below = link.point.y + gap
                val y = if (below + popupContentSize.height <= windowSize.height - margin) below
                    else link.point.y - gap - popupContentSize.height
                // Keep every action reachable near the reader's edges and at large text sizes.
                return IntOffset(x.coerceIn(margin, (windowSize.width - margin - popupContentSize.width).coerceAtLeast(margin)),
                    y.coerceIn(margin, (windowSize.height - margin - popupContentSize.height).coerceAtLeast(margin)))
            }
        }
    }
    Popup(popupPositionProvider = position, onDismissRequest = onDismiss,
        properties = PopupProperties(focusable = true)) {
        // A popup has its own window; keep the reader's text scaling.
        CompositionLocalProvider(LocalDensity provides density) {
            Surface(shape = MaterialTheme.shapes.large, tonalElevation = 3.dp, shadowElevation = 8.dp) {
                Column(Modifier.widthIn(max = with(density) { (window.width - 2 * margin).coerceAtLeast(1).toDp() })
                    .width(272.dp).heightIn(max = with(density) { (window.height - 2 * margin).coerceAtLeast(1).toDp() })
                    .verticalScroll(rememberScrollState()).padding(vertical = 8.dp)
                    .testTag("reader-link-menu").semantics { paneTitle = "Link options" }) {
                    Text(link.uri.host.orEmpty(), modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                    HorizontalDivider(Modifier.padding(vertical = 4.dp))
                    DropdownMenuItem(text = { Text("Save to Magpie") }, onClick = onSave,
                        leadingIcon = { Icon(Icons.Rounded.BookmarkBorder, null, tint = MaterialTheme.colorScheme.primary) })
                    DropdownMenuItem(text = { Text("Open in browser") }, onClick = onOpen,
                        leadingIcon = { Icon(Icons.AutoMirrored.Rounded.OpenInNew, null) })
                    DropdownMenuItem(text = { Text("Copy link") }, onClick = {
                        onDismiss()
                        context.getSystemService(ClipboardManager::class.java)
                            .setPrimaryClip(ClipData.newPlainText("Link", link.uri.toString()))
                        // Newer Android versions provide their own clipboard confirmation.
                        if (Build.VERSION.SDK_INT < 33) Toast.makeText(context, "Link copied", Toast.LENGTH_SHORT).show()
                    }, leadingIcon = { Icon(Icons.Rounded.ContentCopy, null) })
                    DropdownMenuItem(text = { Text("Share link") }, onClick = {
                        onDismiss()
                        val share = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, link.uri.toString())
                        }
                        try { context.startActivity(Intent.createChooser(share, "Share link")) }
                        catch (_: ActivityNotFoundException) { onError("No app is available to share this link.") }
                    }, leadingIcon = { Icon(Icons.Rounded.Share, null) })
                }
            }
        }
    }
}
