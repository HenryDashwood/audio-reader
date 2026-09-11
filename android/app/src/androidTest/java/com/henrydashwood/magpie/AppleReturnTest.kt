package com.henrydashwood.magpie

import android.content.Intent
import android.content.Context
import androidx.core.net.toUri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.AndroidComposeTestRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.rules.ActivityScenarioRule
import org.junit.Rule
import org.junit.Test

class AppleReturnTest {
    private fun returnIntent() = Intent(Intent.ACTION_VIEW,
        (BuildConfig.APPLICATION_ID + ".auth://apple-sign-in?token=untrusted").toUri())
        .setClass(ApplicationProvider.getApplicationContext<Context>(), MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    // ActivityScenario matches lifecycle events against its launch intent. Start
    // with the browser intent so setIntent(onNewIntent) still matches on recreation.
    @get:Rule val compose = AndroidComposeTestRule<ActivityScenarioRule<MainActivity>, MainActivity>(
        activityRule = ActivityScenarioRule(returnIntent()),
        activityProvider = { rule ->
            lateinit var activity: MainActivity
            rule.scenario.onActivity { activity = it }
            activity
        })

    @Test fun browserReturnOpensAccountControlsWithoutAcceptingCredentialsFromTheUrl() {
        compose.onNodeWithText("Sign-in Methods").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.runOnUiThread {
            compose.activity.startActivity(returnIntent())
        }
        compose.onNodeWithText("Sign-in Methods").assertIsDisplayed()
        compose.onNodeWithText("Sign in with Apple").performScrollTo().assertExists()
        compose.onNodeWithText("Signed in").assertDoesNotExist()
        compose.activityRule.scenario.recreate()
        compose.onNodeWithText("Sign-in Methods").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Field notes").assertIsDisplayed()
    }
}
