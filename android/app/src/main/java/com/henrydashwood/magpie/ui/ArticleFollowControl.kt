package com.henrydashwood.magpie.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** Scoped to the app composition; a departing reader cannot clear a newer reader's action. */
class ArticleFollowControl {
    private data class Offer(val owner: Any, val itemId: String, val resume: () -> Unit)
    private var offer by mutableStateOf<Offer?>(null)

    fun offer(owner: Any, itemId: String, resume: () -> Unit) {
        offer = Offer(owner, itemId, resume)
    }

    fun clear(owner: Any) {
        if (offer?.owner === owner) offer = null
    }

    fun actionFor(itemId: String?): (() -> Unit)? = offer?.takeIf { it.itemId == itemId }?.resume
}
