package com.henrydashwood.magpie.auth

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class FeatureFlagWireTest {
    private val api = HttpAccountApi("https://test.invalid")

    @Test fun olderServersAndUnknownFlagsAreDisabled() {
        val user = api.user(JSONObject("""{"id":"one","display_name":null}"""))
        assertTrue(user.featureFlags.isEmpty())
        assertFalse(user.isFeatureEnabled("experiment"))
    }

    @Test fun explicitDenialsArePreserved() {
        val user = api.user(JSONObject("""{"id":"one","feature_flags":{"experiment":true,"pdf_unlimited":false}}"""))
        assertTrue(user.isFeatureEnabled("experiment"))
        assertFalse(user.isFeatureEnabled("pdf_unlimited"))
        assertFalse(user.isFeatureEnabled("unknown"))
    }
}
