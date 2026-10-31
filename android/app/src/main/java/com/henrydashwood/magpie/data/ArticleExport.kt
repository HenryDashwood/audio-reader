package com.henrydashwood.magpie.data

import java.io.File

interface ArticleExportApi {
    suspend fun exportArticle(token: String, episodeId: Int, contentId: Int?, textVersion: String?, destination: File)
}

fun articlePdfFilename(title: String): String {
    val stem = title.replace(Regex("[^\\p{L}\\p{N}\\p{M} ._-]"), "").take(100).trim(' ', '.')
    return "${stem.ifBlank { "Article" }}.pdf"
}
