package com.henrydashwood.magpie.data

interface SubscriptionExportApi {
    suspend fun exportSubscriptions(token: String): String
}

/** Kept only in ViewModel memory while the system file picker is open. */
data class SubscriptionExportFile(val owner: Pair<String?, Int>, val xml: String)
