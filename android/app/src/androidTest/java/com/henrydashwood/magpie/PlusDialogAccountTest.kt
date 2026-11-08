package com.henrydashwood.magpie

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import com.henrydashwood.magpie.billing.PlusStatus
import com.henrydashwood.magpie.ui.MagpieTheme
import com.henrydashwood.magpie.ui.PlusDialog
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

class PlusDialogAccountTest {
    @get:Rule val compose = createComposeRule()

    @Test fun queuedRestoreCannotRunForTheReplacementAccount() {
        val account = mutableStateOf("first")
        val restores = mutableListOf<String>()
        val release = CompletableDeferred<Unit>()
        compose.setContent { MagpieTheme {
            PlusDialog(account.value, { account.value }, { token, _, restore, _ ->
                if (restore) { restores += token; release.await() }
                PlusStatus(true, true, false, token, "", "", 500, 0, if (token == "first") 20 else 40, null, null) to null
            }, {})
        } }
        compose.onNodeWithText("20 of 500 pages remaining").assertIsDisplayed()
        compose.onNodeWithText("Restore purchases").performSemanticsAction(SemanticsActions.OnClick) { click ->
            account.value = "second"
            click()
        }
        compose.onNodeWithText("40 of 500 pages remaining").assertIsDisplayed()
        compose.onNodeWithText("Purchases restored.").assertDoesNotExist()
        compose.runOnIdle { assertTrue(restores.isEmpty()) }
        try {
            compose.onNodeWithText("Restore purchases").performSemanticsAction(SemanticsActions.OnClick) { click ->
                click(); click()
            }
            compose.runOnIdle { assertEquals(listOf("second"), restores) }
        } finally { release.complete(Unit) }
        compose.onNodeWithText("Purchases restored.").assertIsDisplayed()
    }
}
