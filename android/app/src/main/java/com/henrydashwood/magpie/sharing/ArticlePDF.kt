package com.henrydashwood.magpie.sharing

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.henrydashwood.magpie.data.articlePdfFilename
import java.io.File
import java.util.UUID

/** Only this directory is exposed by FileProvider; account caches remain private. */
fun articlePdfDestination(context: Context, title: String): File {
    val root = File(context.cacheDir, "article-exports").apply { mkdirs() }
    val cutoff = System.currentTimeMillis() - 86_400_000
    root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
    val folder = File(root, UUID.randomUUID().toString())
    check(folder.mkdirs()) { "The PDF could not be saved on this device." }
    return File(folder, articlePdfFilename(title))
}

fun articlePdfUri(context: Context, file: File): Uri =
    FileProvider.getUriForFile(context, "${context.packageName}.article-exports", file)

fun articlePdfShareIntent(uri: Uri, title: String): Intent {
    require(uri.scheme == "content")
    return Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
        type = "application/pdf"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_TITLE, title)
        putExtra(Intent.EXTRA_SUBJECT, title)
        clipData = ClipData.newRawUri(title, uri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }, title).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}
